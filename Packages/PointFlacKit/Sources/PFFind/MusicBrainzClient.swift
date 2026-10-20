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
        bucket: TokenBucket = TokenBucket(interval: .seconds(1), burst: 1),
        memory: LRUCache<String, Data> = LRUCache(capacity: 256),
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
        let data = try await fetch(searchURL(entity, query: query, limit: limit))
        do {
            return try JSONDecoder().decode(MB.SearchResponse.self, from: data)
        } catch {
            throw MusicBrainzError.undecodable
        }
    }

    /// The search response for `entity`/`query` if it is cached (memory, or fresh on disk); never touches the network.
    public func cachedSearch(_ entity: MB.Entity, query: String, limit: Int = 8) -> MB.SearchResponse? {
        let key = searchURL(entity, query: query, limit: limit).absoluteString
        guard let data = cachedData(for: key) else { return nil }
        return try? JSONDecoder().decode(MB.SearchResponse.self, from: data)
    }

    private func cachedData(for key: String) -> Data? {
        if let data = memory.value(for: key) { return data }
        if let entry = disk?.read(key), entry.isFresh {
            memory.insert(entry.data, for: key)
            return entry.data
        }
        return nil
    }

    /// Cache, then bucket, then network, then stale cache.
    func fetch(_ url: URL) async throws -> Data {
        let key = url.absoluteString
        if let data = cachedData(for: key) { return data }
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
                logger.info("MusicBrainz unreachable: \(error.localizedDescription, privacy: .public)")
                if let stale = disk?.read(key, allowStale: true) { return stale.data }
                throw MusicBrainzError.offline
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                memory.insert(data, for: key)
                disk?.write(data, for: key)
                return data
            case 429, 503:
                let delay = retryAfter(response) ?? configuration.defaultBusyDelay
                await bucket.penalize(for: delay)
                logger.info("MusicBrainz busy (\(status, privacy: .public)), backing off")
                if attempt < configuration.busyRetries {
                    attempt += 1
                    continue
                }
                if let stale = disk?.read(key, allowStale: true) { return stale.data }
                throw MusicBrainzError.busy
            default:
                // 403 from a network filter, 5xx during an outage: an old answer still beats no answer.
                if let stale = disk?.read(key, allowStale: true) { return stale.data }
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
