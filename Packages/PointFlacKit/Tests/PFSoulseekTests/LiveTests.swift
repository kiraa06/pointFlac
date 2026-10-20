import Foundation
import Testing

@testable import PFSoulseek

/// Opt-in check against the real Soulseek network: `PF_LIVE_TESTS=1`, with the account in `KM_USERNAME` /
/// `KM_PASSWORD` (Keymaster injects them; nothing is ever printed). It logs in and runs one search. It never downloads.
@Suite("Live network", .enabled(if: ProcessInfo.processInfo.environment["PF_LIVE_TESTS"] == "1"))
struct LiveTests {
    @Test("Login and one search on server.slsknet.org", .timeLimit(.minutes(2)))
    func loginAndSearch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let username = try #require(environment["KM_USERNAME"])
        let password = try #require(environment["KM_PASSWORD"])
        var config = SoulseekConfiguration()
        if let major = environment["PF_SLSK_MAJOR"].flatMap(UInt32.init) { config.majorVersion = major }
        let client = SoulseekClient(configuration: config)
        try await client.login(username: username, password: password)
        #expect(await client.state == .loggedIn(username: username))
        try await Task.sleep(for: .seconds(2))  // let ExcludedSearchPhrases arrive

        let query = environment["PF_LIVE_QUERY"] ?? "The Mountain"
        var options = SoulseekSearchOptions(window: .seconds(20))
        options.maxFiles = 5_000
        var files: [SearchResultFile] = []
        var batches = 0
        for try await batch in client.search(query, options: options) {
            files += batch
            batches += 1
        }
        let diagnostics = await client.diagnostics
        let peers = Set(files.map(\.peer)).count
        let hiRes = files.filter { ($0.bitsPerSample ?? 0) >= 24 }.count
        print(
            "LIVE: major \(config.majorVersion); \(diagnostics.connectRequests) connect requests,",
            "\(diagnostics.droppedAtCap) dropped at cap, peak \(diagnostics.peakPeerConnections) in flight,",
            "\(diagnostics.searchResponses) responses, \(diagnostics.malformedMessages) malformed;",
            "\(files.count) FLAC files from \(peers) peers in \(batches) batches, \(hiRes) at 24-bit or more;",
            "\(await client.excludedPhrases.count) excluded phrases")
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { $0.isFLAC })
        await client.logout()
    }

    /// Downloads one public-domain recording (Musopen releases its recordings into the public domain) to prove the
    /// QueueUpload → TransferRequest → indirect F connection flow against real peers. Needs `PF_LIVE_DOWNLOAD=1` too.
    @Test(
        "Download one public-domain Musopen FLAC",
        .enabled(if: ProcessInfo.processInfo.environment["PF_LIVE_DOWNLOAD"] == "1"), .timeLimit(.minutes(5)))
    func downloadPublicDomain() async throws {
        let environment = ProcessInfo.processInfo.environment
        let username = try #require(environment["KM_USERNAME"])
        let password = try #require(environment["KM_PASSWORD"])
        var config = SoulseekConfiguration()
        config.transferRequestTimeout = .seconds(45)
        config.fileConnectionTimeout = .seconds(30)
        config.transferIdleTimeout = .seconds(30)
        let client = SoulseekClient(configuration: config)
        try await client.login(username: username, password: password)
        try await Task.sleep(for: .seconds(2))

        var candidates: [SearchResultFile] = []
        for try await batch in client.search("musopen", options: SoulseekSearchOptions(window: .seconds(20))) {
            candidates += batch.filter {
                $0.path.lowercased().contains("musopen") && $0.freeSlot && $0.sizeBytes < 60_000_000
            }
        }
        candidates.sort { ($0.queueLength, -$0.uploadSpeed) < ($1.queueLength, -$1.uploadSpeed) }
        print("LIVE DOWNLOAD: \(candidates.count) Musopen FLAC candidates with a free slot")
        let staging = FileManager.default.temporaryDirectory.appending(
            path: "PFSoulseekLive-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        var seenPeers: Set<String> = []
        for candidate in candidates where seenPeers.insert(candidate.peer).inserted {
            if seenPeers.count > 4 { break }
            let started = ContinuousClock.now
            var trail: [String] = []
            var outcome: SoulseekTransferEvent?
            for await event in client.download(candidate, into: staging) {
                switch event {
                case .progress: break
                default: trail.append("\(event)")
                }
                outcome = event
            }
            print(
                "LIVE DOWNLOAD: \(candidate.fileName) (\(candidate.sizeBytes) bytes):", trail.joined(separator: " → "))
            if case .finished(let url) = outcome {
                let data = try Data(contentsOf: url)
                let seconds = Double((ContinuousClock.now - started).components.seconds)
                print("LIVE DOWNLOAD: finished, \(data.count) bytes in about \(Int(seconds)) s")
                #expect(Int64(data.count) == candidate.sizeBytes)
                #expect(data.prefix(4) == Data("fLaC".utf8))
                await client.logout()
                return
            }
        }
        await client.logout()
        Issue.record("no candidate finished")
    }
}
