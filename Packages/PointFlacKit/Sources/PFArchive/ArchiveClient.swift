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

    /// Opens a streaming response after pacing, retrying once if the Archive says it is busy.
    func open(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        guard request.url?.scheme?.lowercased() == "https" else { throw ArchiveError.insecure }
        var busyRetries = 0
        while true {
            try await pacer.waitTurn()
            // One guard per request, so a refusal is attributed to this request alone.
            let redirectGuard = RedirectGuard(allowedHost: base.host() ?? "archive.org")
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
            } catch let error as URLError {
                if redirectGuard.refused { throw ArchiveError.insecure }
                if error.code == .cancelled { throw CancellationError() }
                throw ArchiveError.from(error)
            }
            guard let http = response as? HTTPURLResponse else { throw ArchiveError.badResponse("not HTTP") }
            // A redirect only reaches here when the guard refused to follow it.
            if redirectGuard.refused || (300..<400).contains(http.statusCode) { throw ArchiveError.insecure }
            if http.statusCode == 429 || http.statusCode == 503, busyRetries < 1 {
                busyRetries += 1
                let delay = retryAfter(http)
                Self.log.info("archive busy (\(http.statusCode, privacy: .public)); waiting")
                await pacer.backOff(delay)
                continue
            }
            return (bytes, http)
        }
    }

    /// Fetches and decodes a JSON document no larger than `limit` bytes.
    func json<T: Decodable>(_ type: T.Type, from url: URL, limit: Int) async throws -> T {
        let (bytes, response) = try await open(request(url, headers: ["Accept": "application/json"]))
        switch response.statusCode {
        case 200: break
        case 404, 410: throw ArchiveError.notFound
        default: throw ArchiveError.http(response.statusCode)
        }
        if response.expectedContentLength > Int64(limit) { throw ArchiveError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        do {
            for try await byte in bytes {
                data.append(byte)
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

/// Refuses redirects that leave HTTPS or the Archive's own hosts, so a download can never be steered elsewhere.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let allowedHost: String
    private let refusal = Mutex(false)

    /// Whether this request tried to redirect somewhere it may not go.
    var refused: Bool { refusal.withLock { $0 } }

    init(allowedHost: String) { self.allowedHost = allowedHost.lowercased() }

    func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return host == allowedHost || host.hasSuffix("." + allowedHost)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        // Returning nil hands the 3xx itself back to `open`, which refuses it.
        guard isAllowed(request.url) else {
            refusal.withLock { $0 = true }
            return nil
        }
        var next = request
        next.setValue(ArchiveClient.userAgent, forHTTPHeaderField: "User-Agent")
        // A resumed download must stay a range request on the storage server the Archive redirects to.
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            next.setValue(range, forHTTPHeaderField: "Range")
        }
        return next
    }
}
