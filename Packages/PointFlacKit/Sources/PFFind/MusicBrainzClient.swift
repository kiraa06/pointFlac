import Foundation
import os

/// Errors from the MusicBrainz web service.
public enum MusicBrainzError: Error, Sendable, Equatable {
    /// The server kept answering 503 or 429 and no cached copy existed.
    case busy
    case http(status: Int)
    /// The body was larger than the configured cap (spec §5.8: untrusted input has explicit limits).
    case responseTooLarge(bytes: Int)
    case undecodable
    case offline
}

/// A polite MusicBrainz web-service client.
///
/// MusicBrainz asks every client for a meaningful User-Agent and at most one request per second, and answers 503
/// to anything faster (it did so to this stream's own fixture recording at 1.5 s spacing, so the back-off is
/// real, not theoretical). The client therefore:
/// - sends `pointFlac/0.2 ( https://github.com/kiraa06/pointFlac )` on every request;
/// - takes a ``TokenBucket`` slot before each network request, and backs the bucket off on 503/429 (`Retry-After`);
/// - answers from an in-memory LRU, then a fresh on-disk copy, before touching the network;
/// - falls back to a stale on-disk copy when offline or still busy after its retries;
/// - is cancellable end to end: a cancelled task gives up its bucket slot and its `URLSession` request.
public actor MusicBrainzClient {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var userAgent: String
        public var maxResponseBytes: Int
        public var requestTimeout: TimeInterval
        /// Retries after a 503/429 before giving up (each waits for the bucket and the server's `Retry-After`).
        public var busyRetries: Int
        /// The back-off when a 503 carries no `Retry-After`.
        public var defaultBusyDelay: Duration

        public init(
            baseURL: URL = URL(string: "https://musicbrainz.org/ws/2/")!,
            userAgent: String = "pointFlac/0.2 ( https://github.com/kiraa06/pointFlac )",
            maxResponseBytes: Int = 2_000_000,
            requestTimeout: TimeInterval = 8,
            busyRetries: Int = 2,
            defaultBusyDelay: Duration = .seconds(2)
        ) {
            self.baseURL = baseURL
            self.userAgent = userAgent
            self.maxResponseBytes = maxResponseBytes
            self.requestTimeout = requestTimeout
            self.busyRetries = busyRetries
            self.defaultBusyDelay = defaultBusyDelay
        }
    }

    public nonisolated let configuration: Configuration
    private let session: URLSession
    private let bucket: TokenBucket
    private let memory: LRUCache<String, Data>
    private let disk: DiskCache?
    private let logger = Logger(subsystem: "io.github.kiraa06.pointflac", category: "MusicBrainz")
    /// Network requests actually sent (not cache hits). For tests and diagnostics.
    public private(set) var networkRequests = 0

    public init(
        configuration: Configuration = Configuration(),
        session: URLSession = MusicBrainzClient.makeSession(),
        bucket: TokenBucket = .musicBrainz,
        memory: LRUCache<String, Data> = LRUCache(capacity: 256, maxCost: 8_000_000, cost: { $0.count }),
        disk: DiskCache? = DiskCache(directory: DiskCache.defaultDirectory())
    ) {
        self.configuration = configuration
        self.session = session
        self.bucket = bucket
        self.memory = memory
        self.disk = disk
    }

    /// An ephemeral session: the client keeps its own cache, so URLCache would only duplicate it on disk.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }

    /// The URL for a search of `entity` with a Lucene `query`.
    public nonisolated func searchURL(_ entity: MB.Entity, query: String, limit: Int) -> URL {
        var components = URLComponents(
            url: configuration.baseURL.appending(path: entity.rawValue), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        // URLComponents leaves "+" alone, which servers read as a space; Lucene needs it literal.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Searches `entity` with a Lucene `query`.
    public func search(_ entity: MB.Entity, query: String, limit: Int = 8) async throws -> MB.SearchResponse {
        try await fetch(searchURL(entity, query: query, limit: limit))
    }

    /// The search response for `entity`/`query` if it is cached (memory, or fresh on disk); never touches the network.
    public func cachedSearch(_ entity: MB.Entity, query: String, limit: Int = 8) -> MB.SearchResponse? {
        cachedResponse(for: searchURL(entity, query: query, limit: limit).absoluteString)
    }

    /// Forgets every cached response, in memory and on disk (the person turned online suggestions off).
    public func clearCaches() {
        memory.removeAll()
        disk?.removeAll()
    }

    /// A cached response that still decodes. One that does not (a block page cached by an older build, a truncated
    /// file) is deleted, so the caller fetches afresh instead of being stuck with it for a week.
    private func cachedResponse(for key: String, allowStale: Bool = false) -> MB.SearchResponse? {
        if let data = memory.value(for: key) {
            if let decoded = decode(data) { return decoded }
            memory.remove(key)
        }
        guard let entry = disk?.read(key, allowStale: allowStale), entry.isFresh || allowStale else { return nil }
        guard let decoded = decode(entry.data) else {
            disk?.remove(key)
            return nil
        }
        if entry.isFresh { memory.insert(entry.data, for: key) }
        return decoded
    }

    private func decode(_ data: Data) -> MB.SearchResponse? {
        try? JSONDecoder().decode(MB.SearchResponse.self, from: data)
    }

    /// Cache, then bucket, then network, then stale cache. Only bodies that are JSON and decode are ever cached: a
    /// network filter's HTML "blocked" page served with status 200 must not stand in for the answer for a week.
    func fetch(_ url: URL) async throws -> MB.SearchResponse {
        let key = url.absoluteString
        if let cached = cachedResponse(for: key) { return cached }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            try await bucket.acquire()
            var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
            request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            networkRequests += 1
            var data = Data()
            let response: URLResponse
            do {
                // Stream the body so an oversized answer is refused before it is all in memory.
                let (bytes, urlResponse) = try await session.bytes(for: request)
                response = urlResponse
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > configuration.maxResponseBytes {
                        throw MusicBrainzError.responseTooLarge(bytes: data.count)
                    }
                }
            } catch let error as MusicBrainzError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Private: an error description can quote the request URL, which holds what the person typed.
                logger.info("MusicBrainz unreachable: \(error.localizedDescription, privacy: .private)")
                if let stale = cachedResponse(for: key, allowStale: true) { return stale }
                throw MusicBrainzError.offline
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            switch status {
            case 200:
                let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                guard contentType.contains("json"), let decoded = decode(data) else {
                    logger.info("MusicBrainz answered 200 with a body that is not its JSON; not cached")
                    if let stale = cachedResponse(for: key, allowStale: true) { return stale }
                    throw MusicBrainzError.undecodable
                }
                memory.insert(data, for: key)
                disk?.write(data, for: key)
                return decoded
            case 429, 503:
                let delay = retryAfter(response) ?? configuration.defaultBusyDelay
                await bucket.penalize(for: delay)
                logger.info("MusicBrainz busy (\(status, privacy: .public)), backing off")
                if attempt < configuration.busyRetries {
                    attempt += 1
                    continue
                }
                if let stale = cachedResponse(for: key, allowStale: true) { return stale }
                throw MusicBrainzError.busy
            default:
                // 403 from a network filter, 5xx during an outage: an old answer still beats no answer.
                if let stale = cachedResponse(for: key, allowStale: true) { return stale }
                throw MusicBrainzError.http(status: status)
            }
        }
    }

    private func retryAfter(_ response: URLResponse) -> Duration? {
        guard
            let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
            let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
        else { return nil }
        // Never wait longer than a minute on the server's say-so; the user will have typed something else.
        return .milliseconds(Int(min(seconds, 60) * 1000))
    }
}
