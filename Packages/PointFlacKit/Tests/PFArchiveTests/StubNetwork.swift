import Foundation
import Synchronization
import Testing

@testable import PFArchive

/// A canned HTTP answer.
struct StubReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    /// Delivered after the body instead of a clean finish, to simulate a dropped connection.
    var failure: URLError?
    /// Keeps the connection open after the body, like a server still sending; only a cancel ends it.
    var hang = false

    static func json(_ data: Data) -> StubReply {
        StubReply(headers: ["Content-Type": "application/json"], body: data)
    }
}

/// Routes requests to per-test handlers by host, so suites running in parallel never see each other's stubs.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> Result<StubReply, URLError>

    static let handlers = Mutex<[String: Handler]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let handler = Self.handlers.withLock { table in
            table.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch handler(request) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let reply):
            var headers = reply.headers
            if headers["Content-Length"] == nil, reply.failure == nil {
                headers["Content-Length"] = "\(reply.body.count)"
            }
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            if (300..<400).contains(reply.status), let location = reply.headers["Location"],
                let target = URL(string: location, relativeTo: url)
            {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
            if reply.hang { return }
            if let failure = reply.failure {
                // A real connection drops after the bytes before it were read; failing at once would let the session
                // discard them unread.
                let client = client
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    client?.urlProtocol(self, didFailWithError: failure)
                }
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}

/// One test's fake Archive: a unique host, its routes, and a log of every request it saw.
final class StubNetwork: Sendable {
    let host: String
    let requests = Mutex<[URLRequest]>([])
    private let routes = Mutex<[(prefix: String, reply: @Sendable (URLRequest) -> Result<StubReply, URLError>)]>([])

    init() {
        host = "t\(UUID().uuidString.prefix(8).lowercased()).archive.test"
        StubURLProtocol.handlers.withLock { table in
            table[host] = { [weak self] request in
                guard let self else { return .failure(URLError(.cannotFindHost)) }
                return self.handle(request)
            }
        }
    }

    deinit {
        let host = host
        StubURLProtocol.handlers.withLock { $0[host] = nil }
    }

    var base: URL { URL(string: "https://\(host)")! }

    /// Answers requests whose path starts with `prefix`; later routes win.
    func route(_ prefix: String, _ reply: @escaping @Sendable (URLRequest) -> Result<StubReply, URLError>) {
        routes.withLock { $0.insert((prefix, reply), at: 0) }
    }

    func route(_ prefix: String, fixture name: String) {
        let data = loadFixture(name)
        route(prefix) { _ in .success(.json(data)) }
    }

    func provider(interval: Duration = .zero, maxItems: Int = 20) -> ArchiveProvider {
        ArchiveProvider(
            configuration: .init(baseURL: base, maxItemsPerSearch: maxItems, minRequestInterval: interval),
            session: ArchiveClient.makeSession(protocolClasses: [StubURLProtocol.self]))
    }

    func paths() -> [String] { requests.withLock { $0.compactMap { $0.url?.path() } } }

    private func handle(_ request: URLRequest) -> Result<StubReply, URLError> {
        requests.withLock { $0.append(request) }
        let path = request.url?.path() ?? ""
        let reply = routes.withLock { routes in routes.first { path.hasPrefix($0.prefix) }?.reply }
        return reply?(request) ?? .success(StubReply(status: 404))
    }
}

func loadFixture(_ name: String) -> Data {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
        let data = try? Data(contentsOf: url)
    else { fatalError("missing fixture \(name)") }
    return data
}

/// A temporary folder removed when the test ends.
final class Scratch: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "PFArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A value shared between a test and the closures it hands out.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    var value: Value { mutex.withLock { $0 } }

    func update(_ change: (inout Value) -> Void) { mutex.withLock { change(&$0) } }
}
