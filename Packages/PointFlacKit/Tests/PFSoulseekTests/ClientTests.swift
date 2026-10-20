import Foundation
import Testing

@testable import PFSoulseek

/// Collects every batch from a search stream, or the error it ended with.
func collect(_ stream: AsyncThrowingStream<[SearchResultFile], any Error>) async -> ([SearchResultFile], (any Error)?) {
    var files: [SearchResultFile] = []
    do {
        for try await batch in stream { files += batch }
        return (files, nil)
    } catch {
        return (files, error)
    }
}

/// Waits (briefly) for an actor-side condition that the network side sets asynchronously.
func eventually(within limit: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("Login", .timeLimit(.minutes(1)))
struct LoginTests {
    @Test("Success sends the login, then SetWaitPort, SetStatus, SharedFoldersFiles 0/0 and HaveNoParent")
    func success() async throws {
        let server = try await MockListener.start()
        let client = SoulseekClient(configuration: testConfiguration(serverPort: server.port))
        async let serverSide: [UInt32] = {
            let link = try await server.accept()
            let login = try await link.expect(code: 1)
            var reader = WireReader(login.payload)
            #expect(try reader.string() == "alice")
            #expect(try reader.string() == "secret")
            #expect(try reader.u32() == 177)
            #expect(try reader.string() == "c4e31313222cf05fcdd1fc068af5570e")
            #expect(try reader.u32() == 1)
            try await link.send(Mock.loginSuccess())
            var codes: [UInt32] = []
            for _ in 0..<4 { codes.append(try await link.nextFrame().code) }
            return codes
        }()
        try await client.login(username: "alice", password: "secret")
        #expect(try await serverSide == [2, 28, 35, 71])
        #expect(await client.state == .loggedIn(username: "alice"))
    }

    @Test(
        "Login refusals map to typed errors",
        arguments: [
            ("INVALIDPASS", SoulseekError.invalidPassword), ("INVALIDUSERNAME", .invalidUsername),
            ("INVALIDVERSION", .invalidVersion), ("SVRFULL", .rejected("SVRFULL")),
        ])
    func refusal(reason: String, expected: SoulseekError) async throws {
        let server = try await MockListener.start()
        let client = SoulseekClient(configuration: testConfiguration(serverPort: server.port))
        async let serverSide: Void = {
            let link = try await server.accept()
            _ = try await link.expect(code: 1)
            try await link.send(Mock.loginFailure(reason))
        }()
        await #expect(throws: expected) { try await client.login(username: "alice", password: "wrong") }
        try await serverSide
        #expect(await client.state == .failed(expected))
    }

    @Test("A server that is down fails fast with serverUnavailable")
    func serverDown() async throws {
        let server = try await MockListener.start()
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let client = SoulseekClient(configuration: testConfiguration(serverPort: port))
        await #expect(throws: SoulseekError.serverUnavailable) { try await client.login(username: "a", password: "b") }
    }

    @Test("A server that accepts but never answers times out")
    func silentServer() async throws {
        let server = try await MockListener.start()
        var config = testConfiguration(serverPort: server.port)
        config.loginTimeout = .milliseconds(300)
        let client = SoulseekClient(configuration: config)
        await #expect(throws: SoulseekError.timeout) { try await client.login(username: "a", password: "b") }
        _ = server
    }

    @Test("Relogged means another client took the account: state kicked, searches end, no reconnect")
    func kicked() async throws {
        let (client, link, server) = try await loggedInClient { $0.autoReconnect = true }
        let stream = client.search("anything", options: SoulseekSearchOptions(window: .seconds(10)))
        _ = try await link.expect(code: 26)
        try await link.send(Mock.relogged)
        let (_, error) = await collect(stream)
        #expect(error as? SoulseekError == .kicked)
        #expect(await client.state == .kicked)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.pendingCount == 0)  // it did not come back
    }

    @Test("An unexpected drop reconnects and logs in again")
    func reconnects() async throws {
        let (client, link, server) = try await loggedInClient {
            $0.autoReconnect = true
            $0.reconnectDelays = [.milliseconds(50)]
        }
        link.close()
        let second = try await server.accept()
        let login = try await second.expect(code: 1)
        var reader = WireReader(login.payload)
        #expect(try reader.string() == "alice")
        try await second.send(Mock.loginSuccess())
        #expect(await eventually { await client.state == .loggedIn(username: "alice") })
    }

    @Test("An oversized server frame drops the connection without buffering it")
    func oversizedServerFrame() async throws {
        let (client, link, _) = try await loggedInClient()
        try await link.send([0xF0, 0xFF, 0xFF, 0xFF, 1, 0, 0, 0] + [UInt8](repeating: 0, count: 1000))
        #expect(await eventually { await client.state == .failed(.connectionLost) })
    }

    @Test("Searching before login fails")
    func searchWithoutLogin() async {
        let client = SoulseekClient(configuration: testConfiguration(serverPort: 1))
        let (_, error) = await collect(client.search("x"))
        #expect(error as? SoulseekError == .notLoggedIn)
    }
}

@Suite("Search", .timeLimit(.minutes(1)))
struct SearchTests {
    static let files = [
        Mock.File(
            path: "Music\\Goats\\Tallahassee\\01 First Few Desperate Hours.flac", size: 25_000_000,
            attributes: [(4, 44_100), (5, 16)]),
        Mock.File(
            path: "Music\\Goats\\Tallahassee\\02 Southwood Plantation Road.flac", size: 26_000_000,
            attributes: [(4, 96_000), (5, 24)]),
        Mock.File(path: "Music\\Goats\\Tallahassee\\03 Game Shows.mp3", size: 5_000_000, attributes: [(0, 320)]),
    ]

    /// A mock peer that accepts one pierced connection, checks the PierceFireWall token and answers with `files`.
    static func respondingPeer(token: UInt32, searchToken: @escaping @Sendable () async -> UInt32, files: [Mock.File])
        async throws -> (MockListener, Task<Void, any Error>)
    {
        let peer = try await MockListener.start()
        let task = Task {
            let link = try await peer.accept()
            let pierce = try await link.nextFrame(codeWidth: .u8)
            #expect(pierce.code == 0)
            var reader = WireReader(pierce.payload)
            #expect(try reader.u32() == token)
            let payload = Mock.searchResponsePayload(
                username: "claims-to-be-someone-else", token: await searchToken(), files: files)
            try await link.send(Mock.searchResponse(compressed: Mock.zlib(payload)))
        }
        return (peer, task)
    }

    @Test("Results arrive through server ConnectToPeer + PierceFireWall, FLAC only, with peer attribution")
    func indirectSearch() async throws {
        let (client, link, _) = try await loggedInClient()
        let tokenBox = TokenBox()
        let (peer, peerTask) = try await Self.respondingPeer(
            token: 0xABCD, searchToken: { await tokenBox.value }, files: Self.files)
        let stream = client.search("tallahassee", options: SoulseekSearchOptions(window: .seconds(1)))
        let search = try await link.expect(code: 26)
        var reader = WireReader(search.payload)
        await tokenBox.set(try reader.u32())
        #expect(try reader.string() == "tallahassee")
        try await link.send(Mock.connectToPeer(username: "bob", type: "P", port: peer.port, token: 0xABCD))
        let (files, error) = await collect(stream)
        try await peerTask.value
        #expect(error == nil)
        #expect(files.count == 2)
        #expect(Set(files.map(\.peer)) == ["bob"])
        #expect(files.contains { $0.sampleRate == 96_000 && $0.bitsPerSample == 24 })
        #expect(await client.activePeerConnections == 0)
    }

    @Test("Excluded phrases: a matching query is never sent, matching results are never shown")
    func excludedPhrases() async throws {
        let (client, link, _) = try await loggedInClient(excluded: ["Forbidden Band"])
        let (_, refused) = await collect(client.search("the forbidden band live"))
        #expect(refused as? SoulseekError == .excludedPhrase)

        let tokenBox = TokenBox()
        let files = Self.files + [Mock.File(path: "Music\\Forbidden Band\\01.flac", size: 1000)]
        let (peer, peerTask) = try await Self.respondingPeer(
            token: 1, searchToken: { await tokenBox.value }, files: files)
        let stream = client.search("tallahassee", options: SoulseekSearchOptions(window: .seconds(1)))
        let search = try await link.expect(code: 26)  // the refused query never reached the server
        var reader = WireReader(search.payload)
        await tokenBox.set(try reader.u32())
        #expect(try reader.string() == "tallahassee")
        try await link.send(Mock.connectToPeer(username: "bob", type: "P", port: peer.port, token: 1))
        let (results, _) = await collect(stream)
        try await peerTask.value
        #expect(results.count == 2)
        #expect(!results.contains { $0.path.contains("Forbidden") })
    }

    @Test("A search right after login waits for the excluded phrases before sending anything")
    func waitsForPhrases() async throws {
        let (client, link, _) = try await loggedInClient { $0.excludedPhrasesWait = .seconds(3) }
        let stream = client.search("forbidden band", options: SoulseekSearchOptions(window: .milliseconds(200)))
        try await Task.sleep(for: .milliseconds(200))
        try await link.send(Mock.excludedPhrases(["forbidden band"]))
        let (_, error) = await collect(stream)
        #expect(error as? SoulseekError == .excludedPhrase)
    }

    @Test("Searches are spaced by the minimum interval")
    func rateLimit() async throws {
        let (client, link, _) = try await loggedInClient { $0.searchMinimumInterval = .milliseconds(400) }
        let options = SoulseekSearchOptions(window: .milliseconds(200))
        // Measured from before either search starts, so a slow first delivery cannot shrink the gap.
        let start = ContinuousClock.now
        async let first = collect(client.search("one", options: options))
        async let second = collect(client.search("two", options: options))
        _ = try await link.expect(code: 26)
        _ = try await link.expect(code: 26)
        #expect(ContinuousClock.now - start >= .milliseconds(400))
        _ = await (first, second)
    }

    @Test("Silent peers time out, the cap drops the excess, and no connection leaks")
    func capAndTimeouts() async throws {
        let (client, link, _) = try await loggedInClient {
            $0.maxConcurrentPeerConnections = 2
            $0.peerReadTimeout = .milliseconds(300)
        }
        let silent = try await MockListener.start()  // accepts, never answers
        let stream = client.search("x", options: SoulseekSearchOptions(window: .seconds(1)))
        _ = try await link.expect(code: 26)
        for token in 1...5 {
            try await link.send(
                Mock.connectToPeer(username: "p\(token)", type: "P", port: silent.port, token: UInt32(token)))
        }
        let (files, _) = await collect(stream)
        #expect(files.isEmpty)
        let diagnostics = await client.diagnostics
        #expect(diagnostics.peakPeerConnections <= 2)
        #expect(diagnostics.droppedAtCap == 3)
        #expect(await eventually(within: .seconds(10)) { await client.activePeerConnections == 0 })
    }

    @Test("Hostile peers: a zlib bomb and garbage are dropped while honest peers still get through")
    func hostilePeers() async throws {
        let (client, link, _) = try await loggedInClient()
        let tokenBox = TokenBox()
        let bomb = try await MockListener.start()
        let garbage = try await MockListener.start()
        let bombTask = Task {
            let l = try await bomb.accept()
            _ = try await l.nextFrame(codeWidth: .u8)
            // A valid header for the running search, then 20 MiB of zeros: it passes the token check and must stop at
            // the 16 MiB inflate cap.
            var head = WireWriter()
            head.string("bomb")
            head.u32(await tokenBox.value)
            let bombBody = head.bytes + [UInt8](repeating: 0, count: 20 * 1024 * 1024)
            try await l.send(Mock.searchResponse(compressed: Mock.zlib(bombBody)))
        }
        let garbageTask = Task {
            let l = try await garbage.accept()
            _ = try await l.nextFrame(codeWidth: .u8)
            try await l.send(Mock.searchResponse(compressed: [0x78, 0x9C, 1, 2, 3, 4, 5, 6, 7, 8]))
            try await l.send([0xFF, 0xFF, 0xFF, 0x7F, 9, 0, 0, 0])  // a 2 GiB frame header
        }
        let (honest, honestTask) = try await Self.respondingPeer(
            token: 3, searchToken: { await tokenBox.value }, files: Self.files)
        let stream = client.search("x", options: SoulseekSearchOptions(window: .seconds(1)))
        let search = try await link.expect(code: 26)
        var reader = WireReader(search.payload)
        await tokenBox.set(try reader.u32())
        try await link.send(Mock.connectToPeer(username: "bomb", type: "P", port: bomb.port, token: 1))
        try await link.send(Mock.connectToPeer(username: "junk", type: "P", port: garbage.port, token: 2))
        try await link.send(Mock.connectToPeer(username: "bob", type: "P", port: honest.port, token: 3))
        let (files, _) = await collect(stream)
        try await bombTask.value
        try await garbageTask.value
        try await honestTask.value
        #expect(files.count == 2 && files.allSatisfy { $0.peer == "bob" })
        #expect(await client.diagnostics.malformedMessages >= 2)
    }

    @Test("Early stop at maxFiles")
    func earlyStop() async throws {
        let (client, link, _) = try await loggedInClient()
        let tokenBox = TokenBox()
        let many = (0..<50).map { Mock.File(path: "a\\\($0).flac", size: 100) }
        let (peer, peerTask) = try await Self.respondingPeer(
            token: 1, searchToken: { await tokenBox.value }, files: many)
        var options = SoulseekSearchOptions(window: .seconds(10))
        options.maxFiles = 10
        let t0 = ContinuousClock.now
        let stream = client.search("a", options: options)
        let search = try await link.expect(code: 26)
        var reader = WireReader(search.payload)
        await tokenBox.set(try reader.u32())
        try await link.send(Mock.connectToPeer(username: "bob", type: "P", port: peer.port, token: 1))
        let (files, _) = await collect(stream)
        try await peerTask.value
        #expect(files.count == 10)
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }
}

actor TokenBox {
    private(set) var value: UInt32 = 0
    func set(_ newValue: UInt32) { value = newValue }
}

@Suite("State updates", .timeLimit(.minutes(1)))
struct StateUpdateTests {
    @Test("Observers see connecting, logged in, then disconnected")
    func sequence() async throws {
        let server = try await MockListener.start()
        let client = SoulseekClient(configuration: testConfiguration(serverPort: server.port))
        let updates = await client.stateUpdates()
        let recorder = Task {
            var seen: [SoulseekConnectionState] = []
            for await state in updates {
                seen.append(state)
                if state == .disconnected && seen.count > 1 { break }
            }
            return seen
        }
        async let serverSide: Void = {
            let link = try await server.accept()
            _ = try await link.expect(code: 1)
            try await link.send(Mock.loginSuccess())
        }()
        try await client.login(username: "alice", password: "secret")
        try await serverSide
        await client.logout()
        #expect(await recorder.value == [.disconnected, .connecting, .loggedIn(username: "alice"), .disconnected])
    }
}
