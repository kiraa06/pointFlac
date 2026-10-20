import Foundation
import Synchronization
import Testing

@testable import PFFind

/// Serves canned HTTP responses to a `URLSession`, so no test touches the real network.
///
/// Handlers are keyed by host, and every test uses its own random `.test` host, so tests running in parallel never
/// see each other's stubs.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (status: Int, headers: [String: String], body: Data)

    private static let handlers = Mutex<[String: Handler]>([:])
    private var loading: Task<Void, Never>?

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        handlers.withLock { $0[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let client = UncheckedBox(self.client)
        let protocolInstance = UncheckedBox(self)
        guard let host = request.url?.host, let handler = Self.handlers.withLock({ $0[host] }) else {
            client.value?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        loading = Task {
            do {
                let (status, headers, body) = try await handler(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client.value?.urlProtocol(protocolInstance.value, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.value?.urlProtocol(protocolInstance.value, didLoad: body)
                client.value?.urlProtocolDidFinishLoading(protocolInstance.value)
            } catch {
                client.value?.urlProtocol(protocolInstance.value, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        loading?.cancel()
    }
}

/// A `Mutex` that closures can capture (a `Mutex` itself cannot be copied into one).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A recorded MusicBrainz response from `Fixtures/`.
func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/\(name).json"))
    return try Data(contentsOf: url)
}

/// One stubbed MusicBrainz server for one test: a unique host, a request log and a routing closure.
final class StubMusicBrainz: Sendable {
    let host = "mb-\(UUID().uuidString.lowercased()).test"
    let requests = Locked<[(url: URL, userAgent: String?, at: ContinuousClock.Instant)]>([])
    let session: URLSession

    init(route: @escaping @Sendable (URL) async throws -> (Int, [String: String], Data)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        let requests = self.requests
        StubURLProtocol.register(host: host) { request in
            requests.withLock {
                $0.append((request.url!, request.value(forHTTPHeaderField: "User-Agent"), ContinuousClock.now))
            }
            let (status, headers, body) = try await route(request.url!)
            return (status, headers, body)
        }
    }

    deinit {
        StubURLProtocol.unregister(host: host)
    }

    var baseURL: URL { URL(string: "https://\(host)/ws/2/")! }

    var requestCount: Int { requests.withLock { $0.count } }

    /// A client against this stub with a fast bucket and its own throwaway disk cache.
    func client(
        interval: Duration = .milliseconds(20), disk: DiskCache? = nil, busyRetries: Int = 2
    ) -> MusicBrainzClient {
        MusicBrainzClient(
            configuration: .init(baseURL: baseURL, busyRetries: busyRetries, defaultBusyDelay: .milliseconds(30)),
            session: session, bucket: TokenBucket(interval: interval), memory: LRUCache(capacity: 64), disk: disk)
    }
}

/// The query string MusicBrainz was asked, decoded.
func luceneQuery(_ url: URL) -> String {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
}

/// A fresh temporary directory, removed when the value is released.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(
            path: "PFFindTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Collects every emission of a stream.
func collect<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
    var values: [T] = []
    for await value in stream { values.append(value) }
    return values
}
