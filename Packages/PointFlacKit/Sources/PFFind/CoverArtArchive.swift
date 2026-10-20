import Foundation

/// Lazy, cached album thumbnails from the Cover Art Archive for typeahead rows.
///
/// The UI asks only for rows it is about to show, so a fast typist never downloads art for suggestions that were
/// gone before they were seen. Every answer is cached in memory and on disk for a month, including "this album has
/// no front cover" (an empty entry), so a miss is not asked again on every keystroke. Images are refused above a
/// size cap (spec §5.8). Spec §5.8 also makes artwork lookups opt-in: the caller decides whether to call this at all.
public actor CoverArtArchive {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var userAgent: String
        /// 250, 500 or 1200: the thumbnail sizes the archive serves. 250 covers a typeahead row at 3×.
        public var size: Int
        public var maxImageBytes: Int
        public var requestTimeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "https://coverartarchive.org/")!,
            userAgent: String = "pointFlac/0.2 ( https://github.com/kiraa06/pointFlac )", size: Int = 250,
            maxImageBytes: Int = 1_000_000, requestTimeout: TimeInterval = 8
        ) {
            self.baseURL = baseURL
            self.userAgent = userAgent
            self.size = size
            self.maxImageBytes = maxImageBytes
            self.requestTimeout = requestTimeout
        }
    }

    public nonisolated let configuration: Configuration
    private let session: URLSession
    private let bucket: TokenBucket
    private let memory = LRUCache<String, Data>(capacity: 200)
    private let disk: DiskCache?
    /// Network requests actually sent. For tests and diagnostics.
    public private(set) var networkRequests = 0

    public init(
        configuration: Configuration = Configuration(), session: URLSession = MusicBrainzClient.makeSession(),
        bucket: TokenBucket = TokenBucket(interval: .milliseconds(250), burst: 4),
        disk: DiskCache? = DiskCache(
            directory: DiskCache.defaultDirectory().deletingLastPathComponent().appending(path: "CoverArt"),
            timeToLive: 30 * 24 * 3600, maxEntries: 1_000)
    ) {
        self.configuration = configuration
        self.session = session
        self.bucket = bucket
        self.disk = disk
    }

    /// The front-cover thumbnail of a release group, or nil when it has none or it cannot be fetched now.
    /// Cancellable: a row scrolled away cancels its request.
    public func thumbnail(releaseGroupID: String) async -> Data? {
        let url = configuration.baseURL.appending(path: "release-group/\(releaseGroupID)/front-\(configuration.size)")
        let key = url.absoluteString
        if let data = memory.value(for: key) { return data.isEmpty ? nil : data }
        if let entry = disk?.read(key), entry.isFresh {
            memory.insert(entry.data, for: key)
            return entry.data.isEmpty ? nil : entry.data
        }
        do {
            try await bucket.acquire()
            var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
            request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
            networkRequests += 1
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                remember(Data(), for: key)
                return nil
            }
            guard status == 200 else { return disk?.read(key, allowStale: true).flatMap(nonEmpty) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > configuration.maxImageBytes { return nil }
            }
            remember(data, for: key)
            return data
        } catch {
            return disk?.read(key, allowStale: true).flatMap(nonEmpty)
        }
    }

    private func remember(_ data: Data, for key: String) {
        memory.insert(data, for: key)
        disk?.write(data, for: key)
    }

    private func nonEmpty(_ entry: (data: Data, isFresh: Bool)) -> Data? {
        entry.data.isEmpty ? nil : entry.data
    }
}
