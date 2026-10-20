import Foundation
import Synchronization
import os

/// What went wrong talking to the Archive, in words the Downloads list can show.
public enum ArchiveError: Error, Sendable, Equatable, LocalizedError {
    case offline
    case notFound
    case http(Int)
    case tooLarge
    case badResponse(String)
    case insecure
    case checksumMismatch
    case notAudio(String)
    /// The connection closed before the whole file arrived.
    case truncated

    public var errorDescription: String? {
        switch self {
        case .offline: "You're offline, or the Internet Archive can't be reached"
        case .notFound: "The Internet Archive no longer has this file"
        case .http(let code): "The Internet Archive answered with an error (HTTP \(code))"
        case .tooLarge: "The Internet Archive sent more data than expected"
        case .badResponse(let detail): "The Internet Archive sent an unexpected answer (\(detail))"
        case .insecure: "Refused an insecure or off-site redirect"
        case .checksumMismatch: "The file doesn't match the Internet Archive's checksum"
        case .notAudio(let type): "The Internet Archive sent \(type) instead of the file"
        case .truncated: "The download ended early"
        }
    }

    /// Errors worth retrying later with the same request.
    var isTransient: Bool {
        switch self {
        case .offline, .truncated: true
        case .http(let code): code == 429 || code >= 500
        case .notFound, .tooLarge, .badResponse, .insecure, .checksumMismatch, .notAudio: false
        }
    }

    static func from(_ error: URLError) -> ArchiveError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            .offline
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
            .appTransportSecurityRequiresSecureConnection:
            .insecure
        default:
            .badResponse("network error \(error.code.rawValue)")
        }
    }
}

/// Spaces out requests so pointFlac stays a polite Archive client, and pauses everyone when the Archive asks.
actor RequestPacer {
    private let interval: Duration
    private var nextSlot = ContinuousClock.now

    init(interval: Duration) { self.interval = interval }

    /// Waits for this request's turn.
    func waitTurn() async throws {
        let now = ContinuousClock.now
        let slot = max(now, nextSlot)
        nextSlot = slot + interval
        if slot > now { try await Task.sleep(until: slot, clock: .continuous) }
    }

    /// Holds every later request back by `delay` (a `Retry-After` from the server).
    func backOff(_ delay: Duration) {
        nextSlot = max(nextSlot, ContinuousClock.now + delay)
    }
}

/// HTTPS access to the Archive with the limits spec §5.8 asks for.
final class ArchiveClient: Sendable {
    struct Limits: Sendable {
        var minRequestInterval: Duration = .milliseconds(250)
        var maxRetryAfter: Duration = .seconds(30)
        var maxSearchJSONBytes = 4 << 20
        var maxMetadataJSONBytes = 8 << 20
    }

    static let userAgent = "pointFlac/0.2 (+https://github.com/kiraa06/pointFlac)"

    let base: URL
    let limits: Limits
    let session: URLSession
    private let pacer: RequestPacer
    private static let log = Logger(subsystem: "io.github.kiraa06.pointflac", category: "archive")

    init(base: URL, session: URLSession, limits: Limits) {
        self.base = base
        self.session = session
        self.limits = limits
        self.pacer = RequestPacer(interval: limits.minRequestInterval)
    }

    /// An ephemeral session: no cookies, no cache on disk, nothing that outlives the request.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 4
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    func request(_ url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Opens a streaming response after pacing, retrying once if the Archive says it is busy. The body arrives
    /// as `Data` chunks, so a large download is written as it comes rather than handled byte by byte.
    func open(_ request: URLRequest) async throws -> (ResponseBody, HTTPURLResponse) {
        guard request.url?.scheme?.lowercased() == "https" else { throw ArchiveError.insecure }
        var busyRetries = 0
        while true {
            try await pacer.waitTurn()
            // One delegate per request, so a refused redirect is attributed to this request alone.
            let transfer = StreamingTransfer(allowedHost: base.host() ?? "archive.org")
            let response: URLResponse
            do {
                response = try await transfer.start(request, in: session)
            } catch let error as URLError {
                if transfer.refusedRedirect { throw ArchiveError.insecure }
                if error.code == .cancelled { throw CancellationError() }
                throw ArchiveError.from(error)
            }
            guard let http = response as? HTTPURLResponse else { throw ArchiveError.badResponse("not HTTP") }
            // A redirect only reaches here when the transfer refused to follow it.
            if transfer.refusedRedirect || (300..<400).contains(http.statusCode) {
                transfer.cancel()
                throw ArchiveError.insecure
            }
            if http.statusCode == 429 || http.statusCode == 503, busyRetries < 1 {
                transfer.cancel()
                busyRetries += 1
                let delay = retryAfter(http)
                Self.log.info("archive busy (\(http.statusCode, privacy: .public)); waiting")
                await pacer.backOff(delay)
                continue
            }
            return (transfer.body, http)
        }
    }

    /// Fetches and decodes a JSON document no larger than `limit` bytes.
    func json<T: Decodable>(_ type: T.Type, from url: URL, limit: Int) async throws -> T {
        let (body, response) = try await open(request(url, headers: ["Accept": "application/json"]))
        switch response.statusCode {
        case 200: break
        case 404, 410: throw ArchiveError.notFound
        default: throw ArchiveError.http(response.statusCode)
        }
        if response.expectedContentLength > Int64(limit) { throw ArchiveError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        do {
            for try await chunk in body {
                data.append(chunk)
                if data.count > limit { throw ArchiveError.tooLarge }
            }
        } catch let error as URLError {
            throw ArchiveError.from(error)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ArchiveError.badResponse("unreadable JSON")
        }
    }

    private func retryAfter(_ response: HTTPURLResponse) -> Duration {
        let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 5
        let requested = Duration.milliseconds(Int64(max(0, seconds) * 1000))
        return min(requested, limits.maxRetryAfter)
    }
}

typealias ResponseBody = AsyncThrowingStream<Data, Error>

/// One request as a response plus a stream of body chunks, with a redirect policy: redirects that leave HTTPS or the
/// Archive's own hosts are refused, so a download can never be steered elsewhere (spec §5.8).
final class StreamingTransfer: NSObject, URLSessionDataDelegate, Sendable {
    let allowedHost: String
    let body: ResponseBody
    private let bodyContinuation: ResponseBody.Continuation
    private let state = Mutex(State())

    private struct State {
        var refused = false
        var waiting: CheckedContinuation<URLResponse, Error>?
        var task: URLSessionDataTask?
    }

    init(allowedHost: String) {
        self.allowedHost = allowedHost.lowercased()
        // Chunks are written to disk as they come, which keeps up with any network the phone has, so an unbounded
        // buffer stays small in practice.
        (body, bodyContinuation) = ResponseBody.makeStream(bufferingPolicy: .unbounded)
    }

    /// Whether this request tried to redirect somewhere it may not go.
    var refusedRedirect: Bool { state.withLock { $0.refused } }

    /// Starts the request and returns once the response headers arrive; the body follows on `body`.
    func start(_ request: URLRequest, in session: URLSession) async throws -> URLResponse {
        let task = session.dataTask(with: request)
        task.delegate = self
        state.withLock { $0.task = task }
        bodyContinuation.onTermination = { _ in task.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.waiting = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        state.withLock { $0.task }?.cancel()
        bodyContinuation.finish()
    }

    func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return host == allowedHost || host.hasSuffix("." + allowedHost)
    }

    private func takeWaiting() -> CheckedContinuation<URLResponse, Error>? {
        state.withLock { state in
            defer { state.waiting = nil }
            return state.waiting
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        takeWaiting()?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodyContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let waiting = takeWaiting() {
            waiting.resume(throwing: error ?? URLError(.badServerResponse))
        }
        if let error {
            bodyContinuation.finish(throwing: error)
        } else {
            bodyContinuation.finish()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Refusing hands the 3xx itself back to `open`, which rejects it.
        guard isAllowed(request.url) else {
            state.withLock { $0.refused = true }
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue(ArchiveClient.userAgent, forHTTPHeaderField: "User-Agent")
        // A resumed download must stay a range request on the storage server the Archive redirects to.
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            next.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(next)
    }
}
