import Foundation
import Testing

@testable import PFFind

/// Against the real MusicBrainz web service. Opt-in only (`PF_LIVE_TESTS=1`): it sends real requests, at one per
/// second, and the server's answers can change.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PF_LIVE_TESTS"] == "1"))
struct PFFindLiveTests {
    @Test(.timeLimit(.minutes(1)))
    func resolvesTheMountainGorillazLive() async throws {
        let folder = TemporaryDirectory()
        let client = MusicBrainzClient(disk: DiskCache(directory: folder.url))
        let registry = MusicBrainzRegistry(client: client)
        let engine = TypeaheadEngine(library: { _, _ in [] }, registry: registry)
        let clock = ContinuousClock()
        let start = clock.now
        var firstRegistryRow: Duration?
        var last: [Suggestion] = []
        for await snapshot in engine.suggestions("the mountain gorillaz") {
            if firstRegistryRow == nil, !snapshot.isEmpty { firstRegistryRow = clock.now - start }
            last = snapshot
        }
        let total = clock.now - start
        print("live: first registry row after \(firstRegistryRow.map { "\($0)" } ?? "never"), all after \(total)")
        let rows = last.prefix(5).map { "\($0.kind.rawValue): \($0.title) — \($0.subtitle)" }
        print("live: " + rows.joined(separator: " | "))
        let top = try #require(last.first)
        #expect(top.kind == .album)
        #expect(top.title == "The Mountain")
        #expect(top.entity.artist == "Gorillaz")
        let resolved = await engine.resolve(top)
        print("live: resolved track count \(resolved.trackCount.map(String.init) ?? "unknown")")
        #expect(resolved.trackCount != nil)
        let plan = SoulseekQueryPlanner.plan(for: resolved)
        print("live: Soulseek plan \(plan.variants.map(\.query))")
        #expect(plan.variants.first?.query == "the mountain")
        // Every request went through the bucket: at most one per second after the first.
        let requests = await client.networkRequests
        #expect(requests >= 1)
        #expect(total >= .seconds(Double(max(requests - 1, 0))) * 0.9)
    }
}
