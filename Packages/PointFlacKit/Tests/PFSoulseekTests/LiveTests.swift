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
}
