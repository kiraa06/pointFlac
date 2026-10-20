import Foundation
import Testing

@testable import PFSoulseek

/// Review round 1: one test per hardening item.
@Suite("Hardening", .timeLimit(.minutes(1)))
struct HardeningTests {
    /// Starts a search and returns its token as the mock server saw it.
    static func startSearch(
        _ client: SoulseekClient, _ link: FramedLink, options: SoulseekSearchOptions
    ) async throws -> (AsyncThrowingStream<[SearchResultFile], any Error>, UInt32) {
        let stream = client.search("x", options: options)
        let search = try await link.expect(code: 26)
        var reader = WireReader(search.payload)
        return (stream, try reader.u32())
    }

    // MARK: 1. Memory budget

    @Test("1a. A search peer's frame above 1 MiB drops the connection before it is buffered")
    func searchFrameCap() async throws {
        #expect(FrameCaps.searchPeer == 1024 * 1024)
        let (client, link, _) = try await loggedInClient()
        let peer = try await MockListener.start()
        let (stream, _) = try await Self.startSearch(client, link, options: SoulseekSearchOptions(window: .seconds(2)))
        try await link.send(Mock.connectToPeer(username: "big", type: "P", port: peer.port, token: 1))
        let peerLink = try await peer.accept()
        _ = try await peerLink.nextFrame(codeWidth: .u8)
        var header = WireWriter()
        header.u32(UInt32(FrameCaps.searchPeer + 512 * 1024))
        header.u32(9)
        try await peerLink.send(header.bytes)
        do {
            _ = try await peerLink.link.receive(timeout: .seconds(3))
            Issue.record("the client kept the connection open")
        } catch {
            #expect(error as? LinkError != .timeout)  // closed by the client, not merely silent
        }
        let (files, _) = await collect(stream)
        #expect(files.isEmpty)
    }

    @Test("1b. At most 2,000 files are kept from one response")
    func filesPerResponseCap() async throws {
        let (client, link, _) = try await loggedInClient()
        let tokenBox = TokenBox()
        let many = (0..<5_000).map { Mock.File(path: "a\\\($0).flac", size: 10) }
        let (peer, peerTask) = try await SearchTests.respondingPeer(
            token: 1, searchToken: { await tokenBox.value }, files: many)
        var options = SoulseekSearchOptions(window: .seconds(1))
        options.maxFiles = 10_000
        let (stream, token) = try await Self.startSearch(client, link, options: options)
        await tokenBox.set(token)
        try await link.send(Mock.connectToPeer(username: "bob", type: "P", port: peer.port, token: 1))
        let (files, _) = await collect(stream)
        try await peerTask.value
        #expect(files.count == SearchResponse.maxFilesKept)
    }

    @Test("1c. A response for a search that is not running is dropped without inflating it")
    func inactiveTokenSkipped() async throws {
        let (client, link, _) = try await loggedInClient()
        let (peer, peerTask) = try await SearchTests.respondingPeer(
            token: 1, searchToken: { 0xDEAD }, files: SearchTests.files)
        let (stream, _) = try await Self.startSearch(client, link, options: SoulseekSearchOptions(window: .seconds(1)))
        try await link.send(Mock.connectToPeer(username: "bob", type: "P", port: peer.port, token: 1))
        let (files, _) = await collect(stream)
        try await peerTask.value
        #expect(files.isEmpty)
        let diagnostics = await client.diagnostics
        #expect(diagnostics.inactiveResponses == 1 && diagnostics.malformedMessages == 0)
    }

    @Test("1d. The parse gate never lets more than its permits run at once")
    func parseGate() async {
        let gate = AsyncSemaphore(2)
        let counter = ConcurrencyCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await gate.acquire()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    await counter.leave()
                    await gate.release()
                }
            }
        }
        #expect(await counter.peak == 2)
    }

    // MARK: 2. Filtering off the actor

    @Test("2. The per-peer filter applies the FLAC rule, excluded phrases, empty files and the room left")
    func resultFilter() throws {
        let payload = Mock.searchResponsePayload(
            username: "u", token: 1,
            files: [
                Mock.File(path: "A\\1.flac", size: 5), Mock.File(path: "A\\2.mp3", size: 5),
                Mock.File(path: "Banned Words\\3.flac", size: 5), Mock.File(path: "A\\4.flac", size: 0),
                Mock.File(path: "A\\5.FLAC", size: 5), Mock.File(path: "A\\6.flac", size: 5),
            ])
        let response = try SearchResponse.parse(payload)
        let filter = ResultFilter(flacOnly: true, excludedPhrases: ["banned words"], limit: 2)
        #expect(response.results(peer: "p", filter: filter).map(\.fileName) == ["1.flac", "5.flac"])
    }

    // MARK: 3. Slowloris

    @Test("3. A search peer trickling bytes loses its connection at the absolute deadline")
    func slowloris() async throws {
        let (client, link, _) = try await loggedInClient {
            $0.peerReadTimeout = .milliseconds(500)
            $0.searchConnectionLifetime = .milliseconds(700)
        }
        let peer = try await MockListener.start()
        let (stream, _) = try await Self.startSearch(client, link, options: SoulseekSearchOptions(window: .seconds(4)))
        try await link.send(Mock.connectToPeer(username: "slow", type: "P", port: peer.port, token: 1))
        let peerLink = try await peer.accept()
        _ = try await peerLink.nextFrame(codeWidth: .u8)
        let started = ContinuousClock.now
        var closedAfter: Duration?
        // A valid 256-byte frame header, then one body byte every 200 ms: inside the 500 ms read timeout every time.
        for byte in [0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0, count: 40) {
            do {
                try await peerLink.send([byte])
                try await Task.sleep(for: .milliseconds(200))
                if await client.activePeerConnections == 0 {
                    closedAfter = ContinuousClock.now - started
                    break
                }
            } catch {
                closedAfter = ContinuousClock.now - started
                break
            }
        }
        let after = try #require(closedAfter)
        #expect(after < .seconds(2))  // well before the 4 s window, despite a byte every 200 ms
        _ = stream
    }

    // MARK: 4. Download size trust

    @Test("4a. A smaller announced size is refused too: it would end as a truncated 'finished' file")
    func smallerSize() async throws {
        let (client, server, _) = try await loggedInClient()
        let uploader = try await MockUploader.start(path: DownloadTests.path, content: DownloadTests.content)
        let stream = client.download(DownloadTests.result(), into: try temporaryStaging())
        try await answerPeerAddress(server, port: uploader.pListener.port)
        let smaller = UInt64(DownloadTests.content.count - 1)
        async let peerSide = uploader.run(script: .announceSize(smaller), server: server)
        let all = await events(stream)
        #expect(try await peerSide == nil)
        #expect(
            all.last
                == .failed(.sizeMismatch(expected: Int64(DownloadTests.content.count), announced: Int64(smaller))))
    }

    @Test("4b. Files above 2 GiB are refused before any network traffic")
    func hardCap() async throws {
        let (client, _, _) = try await loggedInClient()
        let huge = DownloadTests.result(size: 3 * 1024 * 1024 * 1024)
        #expect(await events(client.download(huge, into: try temporaryStaging())) == [.failed(.fileTooLarge)])
    }

    @Test("4c. Not enough free space for the rest of the file fails before writing")
    func freeSpace() async throws {
        let (client, server, _) = try await loggedInClient { $0.availableCapacity = { _ in 1_000 } }
        let uploader = try await MockUploader.start(path: DownloadTests.path, content: DownloadTests.content)
        let staging = try temporaryStaging()
        let stream = client.download(DownloadTests.result(), into: staging)
        try await answerPeerAddress(server, port: uploader.pListener.port)
        async let peerSide = uploader.run(script: .serve, server: server)
        let all = await events(stream)
        _ = try? await peerSide
        #expect(all.last == .failed(.insufficientStorage))
    }

    // MARK: 5. Connection caps and lifetimes

    @Test("5a. At most 4 connections per peer")
    func perPeerCap() async throws {
        let (client, link, _) = try await loggedInClient()
        let silent = try await MockListener.start()
        let (stream, _) = try await Self.startSearch(client, link, options: SoulseekSearchOptions(window: .seconds(1)))
        for token in 1...6 {
            try await link.send(
                Mock.connectToPeer(username: "same", type: "P", port: silent.port, token: UInt32(token)))
        }
        _ = await collect(stream)
        let diagnostics = await client.diagnostics
        #expect(diagnostics.droppedPerPeer == 2)
        #expect(diagnostics.peakPeerConnections <= 4)
    }

    @Test("5b. Forwarded links to a download peer close when the download ends, not after the transfer timeout")
    func lingeringLinksClosed() async throws {
        let (client, server, _) = try await loggedInClient { $0.transferRequestTimeout = .seconds(20) }
        let uploader = try await MockUploader.start(path: DownloadTests.path, content: DownloadTests.content)
        let extra = try await MockListener.start()
        let stream = client.download(DownloadTests.result(), into: try temporaryStaging())
        try await answerPeerAddress(server, port: uploader.pListener.port)
        // The download is registered once the address was asked for; a forwarded P link for bob is now "wanted".
        try await server.send(Mock.connectToPeer(username: "bob", type: "P", port: extra.port, token: 4242))
        let extraLink = try await extra.accept()
        _ = try await extraLink.nextFrame(codeWidth: .u8)
        async let peerSide = uploader.run(script: .serve, server: server)
        let all = await events(stream)
        _ = try await peerSide
        guard case .finished = all.last else {
            Issue.record("expected finished, got \(String(describing: all.last))")
            return
        }
        do {
            _ = try await extraLink.link.receive(timeout: .seconds(5))
            Issue.record("the forwarded link stayed open")
        } catch {
            #expect(error as? LinkError != .timeout)
        }
        #expect(await eventually { await client.activePeerConnections == 0 })
    }

    // MARK: 6. Login reentrancy

    @Test("6a. Logout during login leaves the client disconnected, not failed")
    func logoutDuringLogin() async throws {
        let server = try await MockListener.start()
        var config = testConfiguration(serverPort: server.port)
        config.loginTimeout = .seconds(5)
        let client = SoulseekClient(configuration: config)
        let login = Task { try await client.login(username: "a", password: "b") }
        let session = try await server.accept()
        _ = try await session.expect(code: 1)
        await client.logout()
        await #expect(throws: SoulseekError.self) { try await login.value }
        #expect(await client.state == .disconnected)
    }

    @Test("6b. A stale login's failure does not clear a newer login")
    func staleLoginFailure() async throws {
        let server = try await MockListener.start()
        var config = testConfiguration(serverPort: server.port)
        config.loginTimeout = .seconds(5)
        let client = SoulseekClient(configuration: config)
        let first = Task { try await client.login(username: "old", password: "b") }
        let firstSession = try await server.accept()
        _ = try await firstSession.expect(code: 1)
        async let secondSide: Void = {
            let link = try await server.accept()
            _ = try await link.expect(code: 1)
            try await link.send(Mock.loginSuccess())
        }()
        try await client.login(username: "new", password: "c")
        try await secondSide
        await #expect(throws: SoulseekError.self) { try await first.value }
        #expect(await client.state == .loggedIn(username: "new"))
        #expect(await client.username == "new")
    }

    // MARK: 7. Local names are re-derived

    @Test("7. A hostile remote name still lands as a sanitised file inside its staging folder")
    func hostileName() async throws {
        let (client, server, _) = try await loggedInClient()
        let path = "Music\\..\\..\\\u{202E}.flac"
        let uploader = try await MockUploader.start(path: path, content: DownloadTests.content)
        let staging = try temporaryStaging()
        let stream = client.download(DownloadTests.result(path: path), into: staging)
        try await answerPeerAddress(server, port: uploader.pListener.port)
        async let peerSide = uploader.run(script: .serve, server: server)
        let all = await events(stream)
        _ = try await peerSide
        guard case .finished(let url) = all.last else {
            Issue.record("expected finished, got \(String(describing: all.last))")
            return
        }
        #expect(url.lastPathComponent == "track.flac")
        #expect(
            url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == staging.standardizedFileURL)
    }

    // MARK: 8. F-connection leak

    @Test("8. Cancelling mid-body closes the F connection")
    func cancelClosesFileLink() async throws {
        let (client, server, _) = try await loggedInClient()
        let uploader = try await MockUploader.start(path: DownloadTests.path, content: DownloadTests.content)
        let stream = client.download(DownloadTests.result(), into: try temporaryStaging())
        try await answerPeerAddress(server, port: uploader.pListener.port)
        async let peerSide = uploader.run(script: .stallAfter(50_000), server: server)
        for await event in stream {
            if case .progress = event { break }  // stop iterating: cancels the download
        }
        #expect(try await peerSide == 0)  // the peer saw its F connection closed (it throws otherwise)
    }

    // MARK: Minors

    @Test(
        "Sanitiser keeps .flac and drops format characters",
        arguments: [
            (".flac", "track.flac"), ("..flac", "track.flac"), ("a\\\u{202E}cod.flac", "cod.flac"),
            ("x\u{200B}y.FLAC", "xy.flac"),
        ])
    func sanitiserMinors(remote: String, local: String) {
        #expect(PathSanitizer.localFileName(forRemotePath: remote) == local)
    }

    @Test(
        "Address policy refuses loopback, private, link-local, CGNAT and multicast",
        arguments: [
            ("127.0.0.1", false), ("10.1.2.3", false), ("172.16.0.1", false), ("172.32.0.1", true),
            ("192.168.1.5", false), ("169.254.3.3", false), ("100.64.0.1", false), ("224.0.0.1", false),
            ("0.0.0.0", false), ("8.8.8.8", true), ("81.2.69.160", true), ("not-an-ip", false),
        ])
    func addressPolicy(ip: String, allowed: Bool) {
        #expect(AddressPolicy.isPublic(ip) == allowed)
    }

    @Test("A server pointing us at 127.0.0.1 is ignored unless tests allow it")
    func privateAddressRefused() async throws {
        let (client, link, _) = try await loggedInClient { $0.allowPrivatePeerAddresses = false }
        let peer = try await MockListener.start()
        let (stream, _) = try await Self.startSearch(client, link, options: SoulseekSearchOptions(window: .seconds(1)))
        try await link.send(Mock.connectToPeer(username: "lan", type: "P", port: peer.port, token: 1))
        _ = await collect(stream)
        #expect(await client.diagnostics.refusedAddresses == 1)
        #expect(peer.pendingCount == 0)
    }

    @Test("Result IDs are fixed-length hashes without NUL")
    func resultIDs() {
        let a = SearchResultFile(peer: "bob", path: "a\\b.flac", sizeBytes: 1)
        let b = SearchResultFile(peer: "bob", path: "a\\c.flac", sizeBytes: 1)
        #expect(!a.id.contains("\u{0}") && a.id.hasPrefix("slsk-") && a.id.count == 37)
        #expect(a.id != b.id && a.id == SearchResultFile(peer: "bob", path: "a\\b.flac", sizeBytes: 9).id)
    }
}

actor ConcurrencyCounter {
    private(set) var now = 0
    private(set) var peak = 0
    func enter() {
        now += 1
        peak = max(peak, now)
    }
    func leave() { now -= 1 }
}
