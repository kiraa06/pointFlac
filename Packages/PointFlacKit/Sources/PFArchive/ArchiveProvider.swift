import CryptoKit
import Foundation
import PFDownloads
import os

/// The Internet Archive as a `DownloadProvider` (spec §4.7): open-licence FLAC only, checked file by file.
public struct ArchiveProvider: DownloadProvider {
    public static let providerID = "archive"

    public struct Configuration: Sendable {
        /// `https://archive.org`; tests point it at a stubbed host.
        public var baseURL: URL
        /// Items whose file lists are fetched per search. Each costs one metadata request.
        public var maxItemsPerSearch: Int
        /// Metadata requests in flight at once during a search.
        public var metadataConcurrency: Int
        /// Minimum gap between any two requests to the Archive.
        public var minRequestInterval: Duration

        public init(
            baseURL: URL = URL(string: "https://archive.org")!, maxItemsPerSearch: Int = 20,
            metadataConcurrency: Int = 3, minRequestInterval: Duration = .milliseconds(250)
        ) {
            self.baseURL = baseURL
            self.maxItemsPerSearch = maxItemsPerSearch
            self.metadataConcurrency = max(1, metadataConcurrency)
            self.minRequestInterval = minRequestInterval
        }
    }

    public let id = ArchiveProvider.providerID
    public let displayName = "Internet Archive"

    let configuration: Configuration
    let client: ArchiveClient
    private static let log = Logger(subsystem: "io.github.kiraa06.pointflac", category: "archive")

    public init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration, session: ArchiveClient.makeSession())
    }

    /// For tests: a session whose protocol classes stub the network.
    init(configuration: Configuration, session: URLSession) {
        self.configuration = configuration
        var limits = ArchiveClient.Limits()
        limits.minRequestInterval = configuration.minRequestInterval
        self.client = ArchiveClient(base: configuration.baseURL, session: session, limits: limits)
    }

    // MARK: Search

    public func search(_ query: String) -> AsyncThrowingStream<[RemoteTrack], Error> {
        let configuration = configuration
        let client = client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.search(query, configuration: configuration, client: client) { batch in
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? nil : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func search(
        _ text: String, configuration: Configuration, client: ArchiveClient, yield: @Sendable ([RemoteTrack]) -> Void
    ) async throws {
        guard let query = ArchiveQuery.build(text),
            let url = ArchiveQuery.searchURL(base: configuration.baseURL, query: query, rows: 50)
        else { return }
        let page = try await client.json(SearchResponse.self, from: url, limit: client.limits.maxSearchJSONBytes)

        // The query asked for open licences, but the answer is re-checked here before any item is used.
        var seen = Set<String>()
        let candidates = page.response.docs.filter { item in
            ArchiveQuery.isValidIdentifier(item.identifier) && seen.insert(item.identifier).inserted
                && ArchiveLicence.classify(
                    licenseURL: item.licenseurl?.first, collections: item.collection?.values ?? []) != nil
        }.prefix(configuration.maxItemsPerSearch)

        try await withThrowingTaskGroup(of: [RemoteTrack].self) { group in
            var pending = candidates.makeIterator()
            func startNext() {
                guard let item = pending.next() else { return }
                group.addTask { try await tracks(for: item.identifier, client: client, base: configuration.baseURL) }
            }
            for _ in 0..<configuration.metadataConcurrency { startNext() }
            while let tracks = try await group.next() {
                if !tracks.isEmpty { yield(tracks) }
                startNext()
            }
        }
    }

    /// The FLAC tracks of one item, or none when the item is missing, dark, unlicensed or has no usable FLAC.
    /// Only being offline fails the whole search; a single bad item is skipped.
    static func tracks(for identifier: String, client: ArchiveClient, base: URL) async throws -> [RemoteTrack] {
        guard let url = ArchiveQuery.metadataURL(base: base, identifier: identifier) else { return [] }
        let response: MetadataResponse
        do {
            response = try await client.json(
                MetadataResponse.self, from: url, limit: client.limits.maxMetadataJSONBytes)
        } catch let error as ArchiveError where error != .offline {
            log.info("skipping item: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard response.isDark != true, let metadata = response.metadata, let files = response.files,
            let licence = ArchiveLicence.classify(
                licenseURL: metadata.licenseurl?.first, collections: metadata.collection?.values ?? [])
        else { return [] }
        return ArchiveFileSelector.tracks(identifier: identifier, metadata: metadata, files: files, licence: licence)
    }

    // MARK: Download

    public func download(_ track: RemoteTrack, into staging: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        let client = client
        let base = configuration.baseURL
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let file = try await ArchiveDownload(track: track, staging: staging, client: client, base: base)
                        .run { continuation.yield(.progress($0)) }
                    continuation.yield(.finished(file))
                    continuation.finish()
                } catch let error as ArchiveError where !error.isTransient {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                } catch {
                    // Transient: the manager retries with backoff, and the part file lets the next attempt resume.
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One file transfer: HTTPS, Range resume from the staged part file, size cap, MD5 check, then the final name.
struct ArchiveDownload {
    let track: RemoteTrack
    let staging: URL
    let client: ArchiveClient
    let base: URL

    func run(progress: @Sendable (Double) -> Void) async throws -> URL {
        guard track.provider == ArchiveProvider.providerID, let identifier = track.detail["identifier"],
            let path = track.detail["path"], let expectedSize = track.sizeBytes, expectedSize > 0,
            let md5 = track.detail["md5"], let name = SafeFileName.sanitize(track.fileName),
            let url = ArchiveQuery.downloadURL(base: base, identifier: identifier, path: path)
        else { throw ArchiveError.badResponse("incomplete track description") }

        let fileManager = FileManager.default
        let part = staging.appending(path: name + ".part")
        let final = staging.appending(path: name)
        var have = (try? fileManager.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if have > expectedSize {
            try? fileManager.removeItem(at: part)
            have = 0
        }

        if have < expectedSize {
            let headers = have > 0 ? ["Range": "bytes=\(have)-"] : [:]
            let (transfer, response) = try await client.open(client.request(url, headers: headers))
            // Every early exit below stops the transfer instead of letting the body keep arriving.
            defer { transfer.cancel() }
            var offset: Int64
            switch response.statusCode {
            case 200:
                offset = 0
            case 206
            where Self.contentRange(response).map({ $0.start == have && ($0.total ?? expectedSize) == expectedSize })
                == true:
                offset = have
            case 206:
                // A range we did not ask for, or of a file whose total size is not the listed one: start again
                // rather than splice mismatched bytes.
                try? fileManager.removeItem(at: part)
                throw ArchiveError.truncated  // transient: the next attempt starts from zero
            case 416:
                try? fileManager.removeItem(at: part)
                throw ArchiveError.truncated  // transient: the next attempt starts from zero
            case 404, 410:
                throw ArchiveError.notFound
            default:
                throw ArchiveError.http(response.statusCode)
            }
            if let type = response.mimeType?.lowercased(), type.hasPrefix("text/html") || type == "application/json" {
                throw ArchiveError.notAudio(type == "application/json" ? "a JSON document" : "a web page")
            }
            if response.expectedContentLength > 0, offset + response.expectedContentLength > expectedSize {
                throw ArchiveError.tooLarge
            }
            try await write(transfer, to: part, from: offset, expectedSize: expectedSize, progress: progress)
            have = (try? fileManager.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        }

        // A short body is a dropped connection: keep the part so the next attempt resumes with a Range request.
        guard have == expectedSize else { throw ArchiveError.truncated }
        guard try Self.md5(of: part) == md5.lowercased() else {
            try? fileManager.removeItem(at: part)
            throw ArchiveError.checksumMismatch
        }
        if fileManager.fileExists(atPath: final.path) { try fileManager.removeItem(at: final) }
        try fileManager.moveItem(at: part, to: final)
        progress(1)
        return final
    }

    private func write(
        _ transfer: StreamingTransfer, to part: URL, from offset: Int64, expectedSize: Int64,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        if offset == 0 || !fileManager.fileExists(atPath: part.path) {
            guard fileManager.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw ArchiveError.badResponse("cannot create the staging file") }
        }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()

        var written = offset
        var lastReported = -1
        do {
            for try await chunk in transfer.body {
                transfer.consumed(chunk.count)
                // Never accept more than the listing promised (spec §5.8: every untrusted input is bounded).
                guard written + Int64(chunk.count) <= expectedSize else {
                    try? handle.close()
                    try? fileManager.removeItem(at: part)
                    throw ArchiveError.tooLarge
                }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                let percent = Int(written * 100 / expectedSize)
                if percent != lastReported {
                    lastReported = percent
                    progress(Double(written) / Double(expectedSize))
                }
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ArchiveError.from(error)
        }
    }

    /// Parses "bytes 1000-1999/2000" (the total may be "*", meaning unknown).
    static func contentRange(_ response: HTTPURLResponse) -> (start: Int64, total: Int64?)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range")?.lowercased(),
            header.hasPrefix("bytes ")
        else { return nil }
        let spec = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let halves = spec.split(separator: "/", maxSplits: 1).map(String.init)
        guard let range = halves.first, let dash = range.firstIndex(of: "-"),
            let start = Int64(range[..<dash].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let total = halves.count == 2 ? Int64(halves[1].trimmingCharacters(in: .whitespaces)) : nil
        if halves.count == 2, halves[1] != "*", total == nil { return nil }
        return (start, total)
    }

    static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
