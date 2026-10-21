import Compression
import Foundation
import Network
import Synchronization

@testable import PFSoulseek

/// A TCP listener on 127.0.0.1 with an ephemeral port: the stand-in for the Soulseek server or for one peer.
final class MockListener: Sendable {
    private let listener: NWListener
    let port: UInt16
    private let box: Box

    private final class Box: Sendable {
        let accepted = Mutex<[NWConnection]>([])
        let resumed = Mutex(false)

        func firstResume() -> Bool {
            resumed.withLock { value in
                defer { value = true }
                return !value
            }
        }
    }

    private init(listener: NWListener, port: UInt16, box: Box) {
        self.listener = listener
        self.port = port
        self.box = box
    }

    static func start() async throws -> MockListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let box = Box()
        listener.newConnectionHandler = { connection in box.accepted.withLock { $0.append(connection) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if box.firstResume() { continuation.resume() }
                case .failed(let error): if box.firstResume() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "mock.listener"))
        }
        guard let port = listener.port?.rawValue else { throw LinkError.refused }
        return MockListener(listener: listener, port: port, box: box)
    }

    /// The next accepted connection, framed with a generous cap (the mock trusts the client under test).
    func accept(timeout: Duration = .seconds(5)) async throws -> FramedLink {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let next = box.accepted.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            if let next {
                return FramedLink(try await TCPLink.adopt(next), maxFrame: 64 * 1024 * 1024)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LinkError.timeout
    }

    var pendingCount: Int { box.accepted.withLock { $0.count } }

    func stop() { listener.cancel() }
}

/// Builders for what a real server or peer sends, written independently of the client's own `Outgoing` builders.
enum Mock {
    static func frame(code: UInt32, _ build: (inout WireWriter) -> Void = { _ in }) -> [UInt8] {
        WireWriter.message(code: code, build)
    }

    static func loginSuccess(greeting: String = "Welcome") -> [UInt8] {
        frame(code: 1) {
            $0.bool(true)
            $0.string(greeting)
            $0.raw([1, 0, 0, 127])
            $0.string("0123456789abcdef0123456789abcdef")
            $0.bool(false)
        }
    }

    static func loginFailure(_ reason: String) -> [UInt8] {
        frame(code: 1) {
            $0.bool(false)
            $0.string(reason)
        }
    }

    static func excludedPhrases(_ phrases: [String]) -> [UInt8] {
        frame(code: 160) {
            $0.u32(UInt32(phrases.count))
            for phrase in phrases { $0.string(phrase) }
        }
    }

    static func connectToPeer(username: String, type: String, port: UInt16, token: UInt32) -> [UInt8] {
        frame(code: 18) {
            $0.string(username)
            $0.string(type)
            $0.raw([1, 0, 0, 127])  // 127.0.0.1, little-endian on the wire
            $0.u32(UInt32(port))
            $0.u32(token)
            $0.bool(false)
        }
    }

    static func peerAddress(username: String, port: UInt16, ip: [UInt8] = [1, 0, 0, 127]) -> [UInt8] {
        frame(code: 3) {
            $0.string(username)
            $0.raw(ip)
            $0.u32(UInt32(port))
            $0.u32(0)
            $0.raw([0, 0])
        }
    }

    static let relogged = frame(code: 41)

    struct File {
        var path: String
        var size: UInt64
        var attributes: [(UInt32, UInt32)] = []
    }

    static func searchResponsePayload(
        username: String, token: UInt32, files: [File], freeSlot: Bool = true, speed: UInt32 = 1_000_000,
        queue: UInt32 = 0
    ) -> [UInt8] {
        var body = WireWriter()
        body.string(username)
        body.u32(token)
        body.u32(UInt32(files.count))
        for file in files {
            body.u8(1)
            body.string(file.path)
            body.u64(file.size)
            body.string("flac")
            body.u32(UInt32(file.attributes.count))
            for (key, value) in file.attributes {
                body.u32(key)
                body.u32(value)
            }
        }
        body.bool(freeSlot)
        body.u32(speed)
        body.u32(queue)
        body.u32(0)
        body.u32(0)
        return body.bytes
    }

    static func searchResponse(compressed payload: [UInt8]) -> [UInt8] {
        frame(code: 9) { $0.raw(payload) }
    }

    static func transferRequest(token: UInt32, path: String, size: UInt64) -> [UInt8] {
        frame(code: 40) {
            $0.u32(1)
            $0.u32(token)
            $0.string(path)
            $0.u64(size)
        }
    }

    static func placeInQueue(path: String, place: UInt32) -> [UInt8] {
        frame(code: 44) {
            $0.string(path)
            $0.u32(place)
        }
    }

    static func uploadDenied(path: String, reason: String) -> [UInt8] {
        frame(code: 50) {
            $0.string(path)
            $0.string(reason)
        }
    }

    /// zlib (RFC 1950) compression: header, raw DEFLATE from Compression, Adler-32 trailer.
    static func zlib(_ input: [UInt8]) -> [UInt8] {
        let capacity = input.count + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(
                    destination.baseAddress!, capacity, source.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        let adler = Inflate.adler32(input)
        return [0x78, 0x9C] + output.prefix(written)
            + [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
    }
}

extension FramedLink {
    /// Reads frames until one with `code` arrives, skipping the rest (post-login chatter, for example).
    func expect(code: UInt32, timeout: Duration = .seconds(5)) async throws -> Frame {
        while true {
            let frame = try await nextFrame(timeout: timeout)
            if frame.code == code { return frame }
        }
    }
}

/// A test configuration pointing at a mock server, with short timeouts so failures surface in milliseconds.
func testConfiguration(serverPort: UInt16) -> SoulseekConfiguration {
    var config = SoulseekConfiguration()
    config.serverHost = "127.0.0.1"
    config.serverPort = serverPort
    config.connectTimeout = .seconds(2)
    config.loginTimeout = .seconds(2)
    config.autoReconnect = false
    config.searchMinimumInterval = .zero
    config.peerConnectTimeout = .seconds(2)
    config.peerReadTimeout = .seconds(2)
    config.searchTailCutoff = .milliseconds(100)
    config.peerAddressTimeout = .seconds(2)
    config.transferRequestTimeout = .seconds(5)
    config.fileConnectionTimeout = .seconds(5)
    config.transferIdleTimeout = .seconds(2)
    config.excludedPhrasesWait = .zero
    config.allowPrivatePeerAddresses = true  // the mock peers live on 127.0.0.1
    return config
}

/// Starts a mock server and logs a client in against it. Returns the client and the server side of the session.
func loggedInClient(
    configure: (inout SoulseekConfiguration) -> Void = { _ in }, excluded: [String] = []
) async throws -> (SoulseekClient, FramedLink, MockListener) {
    let server = try await MockListener.start()
    var config = testConfiguration(serverPort: server.port)
    configure(&config)
    let client = SoulseekClient(configuration: config)
    async let session: FramedLink = {
        let link = try await server.accept()
        _ = try await link.expect(code: 1)
        try await link.send(Mock.loginSuccess())
        if !excluded.isEmpty { try await link.send(Mock.excludedPhrases(excluded)) }
        return link
    }()
    try await client.login(username: "alice", password: "secret")
    let link = try await session
    // HaveNoParent is the last post-login message; once it is here the client has finished logging in.
    _ = try await link.expect(code: 71)
    if !excluded.isEmpty {
        // Give the client's read loop a moment to apply the phrases.
        for _ in 0..<100 where await client.excludedPhrases.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }
    return (client, link, server)
}
