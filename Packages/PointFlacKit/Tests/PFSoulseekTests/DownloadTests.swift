import Foundation
import Testing

@testable import PFSoulseek

/// A scripted uploading peer: a P listener for our direct connection and an F listener for the file connection the
/// server forwards (ConnectToPeer type F), as a NAT-ed downloader sees it.
struct MockUploader {
    enum Script {
        case serve
        case deny(String)
        case announceSize(UInt64)
        case dropAfter(Int)
    }

    let pListener: MockListener
    let fListener: MockListener
    let path: String
    let content: [UInt8]

    static func start(path: String, content: [UInt8]) async throws -> MockUploader {
        MockUploader(
            pListener: try await MockListener.start(), fListener: try await MockListener.start(), path: path,
            content: content)
    }

    /// Plays the peer side. `server` is the mock server session, used to forward the F connection request.
    /// Returns the offset the client asked for, or nil when the script ended before the file connection.
    func run(script: Script, server: FramedLink, place: UInt32 = 3) async throws -> UInt64? {
        let control = try await pListener.accept()
        let initFrame = try await control.nextFrame(codeWidth: .u8)
        #expect(initFrame.code == 1)
        var initReader = WireReader(initFrame.payload)
        #expect(try initReader.string() == "alice")
        #expect(try initReader.string() == "P")
        let queue = try await control.expect(code: 43)
        var queueReader = WireReader(queue.payload)
        #expect(try queueReader.string() == path)
        try await control.send(Mock.placeInQueue(path: path, place: place))

        if case .deny(let reason) = script {
            try await control.send(Mock.uploadDenied(path: path, reason: reason))
            return nil
        }
        var size = UInt64(content.count)
        if case .announceSize(let announced) = script { size = announced }
        let transferToken: UInt32 = 777
        try await control.send(Mock.transferRequest(token: transferToken, path: path, size: size))
        let reply = try await control.expect(code: 41)
        var replyReader = WireReader(reply.payload)
        #expect(try replyReader.u32() == transferToken)
        guard try replyReader.bool() else { return nil }

        try await server.send(Mock.connectToPeer(username: "bob", type: "F", port: fListener.port, token: 999))
        let file = try await fListener.accept()
        let pierce = try await file.nextFrame(codeWidth: .u8)
        #expect(pierce.code == 0)
        var pierceReader = WireReader(pierce.payload)
        #expect(try pierceReader.u32() == 999)
        var tokenWriter = WireWriter()
        tokenWriter.u32(transferToken)
        try await file.send(tokenWriter.bytes)
        var offsetReader = WireReader(try await file.readRaw(8))
        let offset = try offsetReader.u64()
        var body = Array(content[Int(offset)...])
        if case .dropAfter(let count) = script { body = Array(body.prefix(count)) }
        for chunk in stride(from: 0, to: body.count, by: 32 * 1024) {
            try await file.send(Array(body[chunk..<min(chunk + 32 * 1024, body.count)]))
        }
        if case .dropAfter = script { file.close() }
        // Hold the connection until the client has read everything and closed its side.
        _ = try? await file.link.receive(timeout: .seconds(3))
        control.close()
        return offset
    }
}

func temporaryStaging() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "PFSoulseekTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Serves GetPeerAddress for "bob" from the mock server session.
func answerPeerAddress(_ server: FramedLink, port: UInt16) async throws {
    let request = try await server.expect(code: 3)
    var reader = WireReader(request.payload)
    #expect(try reader.string() == "bob")
    try await server.send(Mock.peerAddress(username: "bob", port: port))
}

func events(_ stream: AsyncStream<SoulseekTransferEvent>) async -> [SoulseekTransferEvent] {
    var all: [SoulseekTransferEvent] = []
    for await event in stream { all.append(event) }
    return all
}

@Suite("Download", .timeLimit(.minutes(1)))
struct DownloadTests {
    static let path = "Music\\Goats\\Tallahassee\\01 First Few Desperate Hours.flac"
    static let content: [UInt8] = Array("fLaC".utf8) + (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }

    static func result(size: Int64 = Int64(content.count), path: String = path) -> SearchResultFile {
        SearchResultFile(peer: "bob", path: path, sizeBytes: size, bitsPerSample: 16, sampleRate: 44_100)
    }

    @Test("QueueUpload → place in queue → TransferRequest → indirect F connection → file in staging")
    func indirectDownload() async throws {
        let (client, server, _) = try await loggedInClient()
        let uploader = try await MockUploader.start(path: Self.path, content: Self.content)
        let staging = try temporaryStaging()
        let stream = client.download(Self.result(), into: staging)
        try await answerPeerAddress(server, port: uploader.pListener.port)
        async let peerSide = uploader.run(script: .serve, server: server)
        let all = await events(stream)
        #expect(try await peerSide == 0)

        #expect(all.first == .requested)
        #expect(all.contains(.remotelyQueued(place: 3)))
        #expect(all.contains(.started(offset: 0, size: Int64(Self.content.count))))
        guard case .finished(let url) = all.last else {
            Issue.record("expected finished, got \(String(describing: all.last))")
            return
        }
        #expect(url.lastPathComponent == "01 First Few Desperate Hours.flac")
        #expect(
            url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == staging.standardizedFileURL)
        #expect(try Array(Data(contentsOf: url)) == Self.content)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".part"))
    }

    @Test("An interrupted transfer keeps its .part file and the next attempt resumes from its length")
    func resume() async throws {
        let (client, server, _) = try await loggedInClient()
        let staging = try temporaryStaging()

        let first = try await MockUploader.start(path: Self.path, content: Self.content)
        let firstStream = client.download(Self.result(), into: staging)
        try await answerPeerAddress(server, port: first.pListener.port)
        async let firstPeer = first.run(script: .dropAfter(100_000), server: server)
        let firstEvents = await events(firstStream)
        _ = try await firstPeer
        #expect(firstEvents.last == .failed(.incomplete(received: 100_000, expected: Int64(Self.content.count))))

        let second = try await MockUploader.start(path: Self.path, content: Self.content)
        let secondStream = client.download(Self.result(), into: staging)
        try await answerPeerAddress(server, port: second.pListener.port)
        async let secondPeer = second.run(script: .serve, server: server)
        let secondEvents = await events(secondStream)
        #expect(try await secondPeer == 100_000)
        #expect(secondEvents.contains(.started(offset: 100_000, size: Int64(Self.content.count))))
        guard case .finished(let url) = secondEvents.last else {
            Issue.record("expected finished, got \(String(describing: secondEvents.last))")
            return
        }
        #expect(try Array(Data(contentsOf: url)) == Self.content)
    }

    @Test("The peer's denial ends the download with its reason")
    func denied() async throws {
        let (client, server, _) = try await loggedInClient()
        let uploader = try await MockUploader.start(path: Self.path, content: Self.content)
        let stream = client.download(Self.result(), into: try temporaryStaging())
        try await answerPeerAddress(server, port: uploader.pListener.port)
        async let peerSide = uploader.run(script: .deny("Banned"), server: server)
        let all = await events(stream)
        _ = try await peerSide
        #expect(all.last == .failed(.denied("Banned")))
    }

    @Test("A peer announcing more bytes than the search result is refused (§5.6)")
    func sizeLargerThanRequested() async throws {
        let (client, server, _) = try await loggedInClient()
        let uploader = try await MockUploader.start(path: Self.path, content: Self.content)
        let stream = client.download(Self.result(), into: try temporaryStaging())
        try await answerPeerAddress(server, port: uploader.pListener.port)
        async let peerSide = uploader.run(script: .announceSize(UInt64(Self.content.count) * 1000), server: server)
        let all = await events(stream)
        #expect(try await peerSide == nil)  // TransferResponse said no
        #expect(
            all.last
                == .failed(
                    .sizeMismatch(expected: Int64(Self.content.count), announced: Int64(Self.content.count) * 1000)))
    }

    @Test("An offline peer (address 0.0.0.0:0) fails without connecting anywhere")
    func offlinePeer() async throws {
        let (client, server, _) = try await loggedInClient()
        let stream = client.download(Self.result(), into: try temporaryStaging())
        _ = try await server.expect(code: 3)
        try await server.send(Mock.peerAddress(username: "bob", port: 0, ip: [0, 0, 0, 0]))
        #expect(await events(stream).last == .failed(.peerOffline))
    }

    @Test("A peer that never sends its TransferRequest times out")
    func queueTimeout() async throws {
        let (client, server, _) = try await loggedInClient { $0.transferRequestTimeout = .milliseconds(400) }
        let peer = try await MockListener.start()
        let stream = client.download(Self.result(), into: try temporaryStaging())
        try await answerPeerAddress(server, port: peer.port)
        let control = try await peer.accept()
        _ = try await control.nextFrame(codeWidth: .u8)
        #expect(await events(stream).last == .failed(.timeout))
    }

    @Test("Non-FLAC names are refused before any network traffic")
    func flacOnly() async throws {
        let (client, _, _) = try await loggedInClient()
        let stream = client.download(Self.result(path: "a\\b.mp3"), into: try temporaryStaging())
        #expect(await events(stream) == [.failed(.notFLAC)])
    }

    @Test("Upload requests from peers are always refused: pointFlac shares nothing")
    func neverUploads() async throws {
        let client = SoulseekClient(configuration: testConfiguration(serverPort: 1))
        let reply = await client.handleTransferRequest(peer: "eve", direction: 0, token: 5, path: "x", size: nil)
        var buffer = FrameBuffer(maxFrame: 1024)
        buffer.append(reply.bytes)
        let frame = try #require(try buffer.next())
        var reader = WireReader(frame.payload)
        #expect(frame.code == 41)
        #expect(try reader.u32() == 5)
        #expect(try reader.bool() == false)
        // An unsolicited upload to us for a file we never queued is refused too.
        let unsolicited = await client.handleTransferRequest(
            peer: "eve", direction: 1, token: 6, path: "x.flac", size: 9)
        var buffer2 = FrameBuffer(maxFrame: 1024)
        buffer2.append(unsolicited.bytes)
        var reader2 = WireReader(try #require(try buffer2.next()).payload)
        _ = try reader2.u32()
        #expect(try reader2.bool() == false)
    }
}
