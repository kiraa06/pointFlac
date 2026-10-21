import Foundation
import Network
import Synchronization

enum LinkError: Error, Sendable, Equatable {
    case timeout
    case refused
    case closed
    case failed(String)
}

/// Resumes a continuation at most once, whichever of the network callback, the timer or cancellation comes first.
private final class OnceContinuation<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = Mutex(continuation) }

    var isResumed: Bool { continuation.withLock { $0 == nil } }

    @discardableResult
    func resume(with result: Result<T, any Error>) -> Bool {
        guard
            let continuation = continuation.withLock({ value -> CheckedContinuation<T, any Error>? in
                defer { value = nil }
                return value
            })
        else { return false }
        continuation.resume(with: result)
        return true
    }
}

/// A one-shot timer on a dispatch queue that can be cancelled, so a completed receive or send does not leave a pending
/// block behind. `DispatchWorkItem.cancel()` is thread-safe; the class only adds the Sendable wrapper.
private final class CancellableTimer: @unchecked Sendable {
    private let item: DispatchWorkItem

    init(_ action: @escaping @Sendable () -> Void) { item = DispatchWorkItem(block: action) }

    func schedule(on queue: DispatchQueue, after duration: Duration) {
        queue.asyncAfter(deadline: .now() + duration.dispatchInterval, execute: item)
    }

    func cancel() { item.cancel() }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}

/// An async TCP connection over Network.framework with connect and read timeouts.
///
/// Every peer connection is started non-blocking and raced against its own timer, so hundreds can be in flight at once
/// and a silent or unroutable peer costs at most its timeout (the live probe needed 4 s connects and a cap of ~300).
final class TCPLink: Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    private init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "pointflac.soulseek.link")
    }

    static func connect(host: String, port: UInt16, timeout: Duration) async throws -> TCPLink {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else { throw LinkError.refused }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // IPv4 literals go through the resolver so IPv6-only (NAT64) networks get a reachable address.
        let endpointHost = await AddressSynthesis.host(for: host)
        let link = TCPLink(connection: NWConnection(host: endpointHost, port: nwPort, using: parameters))
        try await link.start(timeout: timeout)
        return link
    }

    /// Wraps a connection accepted by a listener (used by the tests' mock server and peers).
    static func adopt(_ connection: NWConnection, timeout: Duration = .seconds(5)) async throws -> TCPLink {
        let link = TCPLink(connection: connection)
        try await link.start(timeout: timeout)
        return link
    }

    private func start(timeout: Duration) async throws {
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let once = OnceContinuation(continuation)
                let timer = CancellableTimer {
                    if once.resume(with: .failure(LinkError.timeout)) { connection.cancel() }
                }
                connection.stateUpdateHandler = { state in
                    defer { if once.isResumed { timer.cancel() } }
                    switch state {
                    case .ready:
                        once.resume(with: .success(()))
                    case .waiting(let error):
                        // Refused or unreachable: Network.framework would retry forever, we give up at once.
                        if once.resume(with: .failure(LinkError.failed("waiting: \(error)"))) { connection.cancel() }
                    case .failed(let error):
                        once.resume(with: .failure(LinkError.failed("\(error)")))
                    case .cancelled:
                        once.resume(with: .failure(LinkError.closed))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                timer.schedule(on: queue, after: timeout)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Sends `bytes`. A peer that stops reading cannot hold the connection forever: after `timeout` the connection
    /// is closed and `LinkError.timeout` thrown.
    func send(_ bytes: [UInt8], timeout: Duration = .seconds(30)) async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OnceContinuation(continuation)
            let timer = CancellableTimer {
                if once.resume(with: .failure(LinkError.timeout)) { connection.cancel() }
            }
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    timer.cancel()
                    if let error {
                        once.resume(with: .failure(LinkError.failed("\(error)")))
                    } else {
                        once.resume(with: .success(()))
                    }
                })
            timer.schedule(on: queue, after: timeout)
        }
    }

    /// At least one byte, at most `maximum`. Throws `LinkError.closed` at end of stream. When `timeout` passes with
    /// nothing received the connection is closed and `LinkError.timeout` thrown: a silent peer is a dead peer here.
    func receive(maximum: Int = 64 * 1024, timeout: Duration? = nil) async throws -> [UInt8] {
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
                let once = OnceContinuation(continuation)
                // A cancellable timer: thousands of receives per transfer must not leave thousands of pending blocks.
                let timer = CancellableTimer {
                    if once.resume(with: .failure(LinkError.timeout)) { connection.cancel() }
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                    timer.cancel()
                    if let data, !data.isEmpty {
                        once.resume(with: .success([UInt8](data)))
                    } else if let error {
                        once.resume(with: .failure(LinkError.failed("\(error)")))
                    } else {
                        _ = isComplete
                        once.resume(with: .failure(LinkError.closed))
                    }
                }
                if let timeout {
                    timer.schedule(on: queue, after: timeout)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func close() { connection.cancel() }
}

/// A `TCPLink` plus a capped `FrameBuffer`.
///
/// Only one task reads from a `FramedLink` at a time (its owner's read loop), which is why the unsynchronised buffer is
/// safe; sends may come from anywhere because `NWConnection.send` is thread-safe and keeps call order.
final class FramedLink: @unchecked Sendable {
    let link: TCPLink
    private var buffer: FrameBuffer

    init(_ link: TCPLink, maxFrame: Int) {
        self.link = link
        self.buffer = FrameBuffer(maxFrame: maxFrame)
    }

    /// The next frame. `timeout` bounds each receive (a silent peer); `deadline` bounds the whole call, so a peer
    /// trickling one byte just inside every timeout (slowloris) still loses its connection when the deadline passes.
    func nextFrame(
        codeWidth: FrameBuffer.CodeWidth = .u32, timeout: Duration? = nil, deadline: ContinuousClock.Instant? = nil
    ) async throws -> Frame {
        while true {
            if let frame = try buffer.next(codeWidth: codeWidth) { return frame }
            var wait = timeout
            if let deadline {
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else {
                    close()
                    throw LinkError.timeout
                }
                wait = min(wait ?? remaining, remaining)
            }
            buffer.append(try await link.receive(timeout: wait))
        }
    }

    func readRaw(_ count: Int, timeout: Duration? = nil) async throws -> [UInt8] {
        while true {
            if let bytes = buffer.takeRaw(count) { return bytes }
            buffer.append(try await link.receive(timeout: timeout))
        }
    }

    /// Bytes buffered beyond the last frame read (the start of file data on an F connection).
    func drain() -> [UInt8] { buffer.drain() }

    func send(_ bytes: [UInt8]) async throws {
        do {
            try await link.send(bytes)
        } catch {
            link.close()
            throw error
        }
    }

    func close() { link.close() }
}
