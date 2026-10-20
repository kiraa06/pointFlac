import Foundation
import Synchronization
import Testing

@testable import PFFind

/// A scripted registry: fixed cached rows, live rows after a delay, and a log of what it was asked.
final class FakeRegistry: SuggestionRegistry {
    let cached: [Suggestion]?
    let live: [[Suggestion]]
    let delay: Duration
    let asked = Mutex<[String]>([])

    init(cached: [Suggestion]? = nil, live: [[Suggestion]] = [], delay: Duration = .zero) {
        self.cached = cached
        self.live = live
        self.delay = delay
    }

    func cachedSuggestions(for partial: String) -> [Suggestion]? { cached }

    func suggestions(for partial: String) -> AsyncThrowingStream<[Suggestion], Error> {
        asked.withLock { $0.append(partial) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Suggestion].self)
        let task = Task { [live, delay] in
            var collected: [Suggestion] = []
            for batch in live {
                do { try await Task.sleep(for: delay) } catch {
                    continuation.finish(throwing: error)
                    return
                }
                collected += batch
                continuation.yield(collected)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func resolve(_ suggestion: Suggestion) async throws -> ResolvedEntity { suggestion.entity }
}

func registryRow(_ kind: Suggestion.Kind, _ title: String, artist: String, score: Double = 1) -> Suggestion {
    let entity = ResolvedEntity(
        kind: kind, artist: artist, album: kind == .album ? title : nil, track: kind == .track ? title : nil,
        musicBrainzID: "mbid-\(title)")
    return Suggestion(
        id: "mb:\(kind.rawValue):\(title)", kind: kind, title: kind == .artist ? artist : title, subtitle: artist,
        source: Suggestion.Source.musicBrainz, entity: entity, relevance: score)
}

@Suite struct TypeaheadEngineTests {
    let fast = TypeaheadEngine.Configuration(debounce: .milliseconds(20))

    @Test func emitsLibraryThenCachedThenLive() async {
        let library: TypeaheadEngine.LibrarySearch = { _, _ in
            [LibraryHit(id: "1", kind: .album, title: "Demon Days", artist: "Gorillaz", year: 2005)]
        }
        let registry = FakeRegistry(
            cached: [registryRow(.artist, "", artist: "Gorillaz")],
            live: [[registryRow(.album, "The Mountain", artist: "Gorillaz")]])
        let engine = TypeaheadEngine(library: library, registry: registry, configuration: fast)
        let emissions = await collect(engine.suggestions("gorillaz"))
        #expect(emissions.count == 3)
        #expect(emissions[0].map(\.source) == [Suggestion.Source.library])
        #expect(emissions[1].contains { $0.kind == .artist && $0.source == Suggestion.Source.musicBrainz })
        #expect(emissions[2].contains { $0.title == "The Mountain" })
        #expect(emissions[2].contains { $0.title == "Demon Days" })
    }

    @Test func firstEmissionIsAvailableBeforeTheCallReturns() async {
        let library: TypeaheadEngine.LibrarySearch = { _, _ in
            [LibraryHit(id: "1", kind: .artist, title: "Gorillaz", artist: "Gorillaz")]
        }
        let engine = TypeaheadEngine(
            library: library, registry: FakeRegistry(delay: .seconds(10)), configuration: fast)
        let stream = engine.suggestions("gor")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.first?.title == "Gorillaz")
    }

    @Test func aNewerKeystrokeCancelsTheOlderRegistryRequest() async {
        let registry = FakeRegistry(live: [[registryRow(.artist, "", artist: "Gorillaz")]])
        let engine = TypeaheadEngine(
            library: { _, _ in [] }, registry: registry,
            configuration: .init(debounce: .milliseconds(150)))
        let older = engine.suggestions("gori")
        let newer = engine.suggestions("goril")
        let olderEmissions = await collect(older)
        let newerEmissions = await collect(newer)
        #expect(registry.asked.withLock { $0 } == ["goril"])
        #expect(olderEmissions.allSatisfy { $0.isEmpty })
        #expect(newerEmissions.last?.first?.title == "Gorillaz")
    }

    @Test func shortInputNeverReachesTheRegistry() async {
        let registry = FakeRegistry(live: [[registryRow(.artist, "", artist: "Gorillaz")]])
        let engine = TypeaheadEngine(library: { _, _ in [] }, registry: registry, configuration: fast)
        _ = await collect(engine.suggestions("go"))
        #expect(registry.asked.withLock { $0 }.isEmpty)
    }

    @Test func registryOffSendsNothing() async {
        let registry = FakeRegistry(live: [[registryRow(.artist, "", artist: "Gorillaz")]])
        var configuration = fast
        configuration.registryEnabled = false
        let engine = TypeaheadEngine(library: { _, _ in [] }, registry: registry, configuration: configuration)
        let emissions = await collect(engine.suggestions("gorillaz"))
        #expect(emissions.count == 1)
        #expect(registry.asked.withLock { $0 }.isEmpty)
    }

    @Test func libraryWinsDuplicatesButKeepsRegistryIDs() {
        let library = Suggestion(
            libraryHit: LibraryHit(id: "7", kind: .album, title: "The Mountain", artist: "Gorillaz", year: 2026))
        var remote = registryRow(.album, "The Mountain", artist: "Gorillaz")
        remote.entity.trackCount = 15
        remote.entity.releaseGroupID = "rg-1"
        let merged = SuggestionRanker(query: "the mountain").merge(library: [library], registry: [remote])
        #expect(merged.count == 1)
        #expect(merged[0].source == Suggestion.Source.library)
        #expect(merged[0].entity.trackCount == 15)
        #expect(merged[0].entity.releaseGroupID == "rg-1")
    }

    @Test func dedupeIgnoresCaseDiacriticsAndEditionNoise() {
        let rows = [
            registryRow(.album, "Homogenic", artist: "Björk"),
            registryRow(.album, "Homogenic (Remastered)", artist: "Bjork"),
        ]
        #expect(SuggestionRanker(query: "homogenic").merge(library: [], registry: rows).count == 1)
    }

    @Test func ranksTheIntendedAlbumFirstForMixedTitleAndArtistWords() {
        let rows = [
            registryRow(.album, "Gorillaz", artist: "Gorillaz"),
            registryRow(.album, "The Mountain", artist: "Gorillaz"),
            registryRow(.artist, "", artist: "Gorillaz"),
            registryRow(.album, "Mountain", artist: "Mountain"),
        ]
        let ranked = SuggestionRanker(query: "the mountain gorillaz").merge(library: [], registry: rows)
        #expect(ranked.first?.title == "The Mountain")
        #expect(ranked.first?.entity.artist == "Gorillaz")
    }

    @Test func dropsRegistryNoise() {
        let rows = [registryRow(.artist, "", artist: "Lupe Fiasco")]
        #expect(SuggestionRanker(query: "gorillaz").merge(library: [], registry: rows).isEmpty)
    }

    @Test func endToEndWithRecordedMusicBrainz() async throws {
        let stub = StubMusicBrainz { url in
            switch url.lastPathComponent {
            case "release-group": (200, [:], try fixture("mb-release-group-the-mountain-gorillaz"))
            case "artist": (200, [:], try fixture("mb-artist-gorill-prefix"))
            case "release": (200, [:], try fixture("mb-release-the-mountain"))
            default: (200, [:], try fixture("mb-recording-feel-good-inc"))
            }
        }
        let registry = MusicBrainzRegistry(client: stub.client())
        let engine = TypeaheadEngine(library: { _, _ in [] }, registry: registry, configuration: fast)
        let emissions = await collect(engine.suggestions("the mountain gorillaz"))
        let last = try #require(emissions.last)
        let top = try #require(last.first)
        #expect(top.kind == .album)
        #expect(top.title == "The Mountain")
        #expect(top.subtitle == "Gorillaz · 2026 · Album")
        #expect(last.contains { $0.kind == .artist && $0.title == "Gorillaz" })
        // The album rows land before the artist rows: one emission per request.
        #expect(emissions.count >= 3)
        let resolved = await engine.resolve(top)
        #expect(resolved.trackCount == 15)
        // Typing the same phrase again is answered from the cache at once.
        let again = engine.suggestions("the mountain gorillaz")
        var iterator = again.makeAsyncIterator()
        _ = await iterator.next()
        let cached = await iterator.next()
        #expect(cached?.first?.title == "The Mountain")
    }
}

@Suite struct TypeaheadBenchmarkTests {
    /// A 10,000-album library, standing in for stream A's index (a linear prefix scan, slower than a real index).
    static let library: [(hit: LibraryHit, folded: String)] = (0..<10_000).map { index in
        let hit = LibraryHit(
            id: "\(index)", kind: .album, title: "Album \(index) Mountain Session", artist: "Artist \(index % 300)",
            year: 1960 + index % 60, trackCount: 10)
        return (hit, FindText.fold(hit.title + " " + hit.artist))
    }

    @Test func firstEmissionStaysWithinOneFrame() async {
        let index = Self.library
        let search: TypeaheadEngine.LibrarySearch = { query, limit in
            let needle = FindText.fold(query)
            var hits: [LibraryHit] = []
            for entry in index where entry.folded.hasPrefix(needle) {
                hits.append(entry.hit)
                if hits.count == limit { break }
            }
            return hits
        }
        let engine = TypeaheadEngine(
            library: search, registry: FakeRegistry(delay: .seconds(10)),
            configuration: .init(debounce: .seconds(10)))
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for round in 0..<50 {
            let start = clock.now
            let stream = engine.suggestions("album \(round * 197 % 10_000) mount")
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            samples.append(clock.now - start)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count) * 0.95)]
        print("typeahead first emission over 10k albums: median \(median), p95 \(p95)")
        #expect(median < .milliseconds(16))
        #expect(p95 < .milliseconds(33))
    }
}
