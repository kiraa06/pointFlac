import Foundation
import Testing

@testable import PFFind

@Suite struct SmartSearchTests {
    @Test func wiresTheFlowEndToEnd() async throws {
        let stub = StubMusicBrainz { url in
            switch url.lastPathComponent {
            case "release-group": (200, [:], try fixture("mb-release-group-the-mountain-gorillaz"))
            case "release": (200, [:], try fixture("mb-release-the-mountain"))
            default: (200, [:], Data(#"{"count": 0}"#.utf8))
            }
        }
        let search = SmartSearch(
            library: { _, _ in [] }, registry: MusicBrainzRegistry(client: stub.client(), order: [.releaseGroup]))
        let last = try #require(await collect(search.suggestions("the mountain gorillaz")).last)
        let album = try #require(last.first { $0.kind == .album })
        let entity = await search.resolve(album)
        #expect(entity.trackCount == 15)
        #expect(search.soulseekPlan(for: entity, excludedPhrases: []).variants.first?.query == "the mountain")
        #expect(search.archiveQueries(for: entity).first?.contains(#"title:("The Mountain")"#) == true)
        // Artwork is opt-in: off by default, so no request is made.
        #expect(await search.thumbnail(for: album) == nil)
        let files = (1...15).map { index in
            CandidateFile(
                path: #"music\Gorillaz - The Mountain (2026)\"# + "\(index).flac", bitsPerSample: 24,
                sampleRate: 48_000, peer: "p", freeSlot: true)
        }
        let runner = SearchPlanRunner(bucket: TokenBucket(interval: .milliseconds(1)))
        let ranked = await collect(
            runner.albums(search.soulseekPlan(for: entity, excludedPhrases: []), for: entity) { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(files)
                    continuation.finish()
                }
            })
        #expect(ranked.last?.first?.why == "Complete album · 24/48 · free slot")
    }

    @Test func registryOffMeansLibraryOnly() async {
        let search = SmartSearch(
            library: { _, _ in [LibraryHit(id: "1", kind: .artist, title: "Gorillaz", artist: "Gorillaz")] },
            registryEnabled: false)
        let emissions = await collect(search.suggestions("gorillaz"))
        #expect(emissions.count == 1)
        #expect(emissions[0].first?.source == Suggestion.Source.library)
    }
}

@Suite struct DerivedRowsTests {
    @Test func albumResultsAlsoSuggestTheirArtists() throws {
        let response = try JSONDecoder().decode(
            MB.SearchResponse.self, from: fixture("mb-release-group-the-mountain-gorillaz"))
        let rows = MusicBrainzRegistry.suggestions(from: response, entity: .releaseGroup)
        #expect(rows.map(\.kind) == [.album, .artist])
        #expect(rows[1].title == "Gorillaz")
        #expect(rows[1].id == "mb:artist:e21857d5-3256-4547-afb3-4b6ded592596")
    }

    @Test func artistEntitiesRankAnyOfTheirAlbumFolders() {
        let artist = ResolvedEntity(kind: .artist, artist: "Gorillaz")
        let files = [
            CandidateFile(path: #"music\Gorillaz\Demon Days\01.flac"#, peer: "a"),
            CandidateFile(path: #"music\Blur\Parklife\01.flac"#, peer: "a"),
        ]
        let ranked = ResultRanker.rankAlbums(files, for: artist)
        #expect(ranked.map(\.folder) == [#"music\Gorillaz\Demon Days"#])
    }
}

@Suite struct TypeaheadTimingTests {
    @Test func liveRowsWaitForTheDebounce() async throws {
        let registry = FakeRegistry(live: [[registryRow(.artist, "", artist: "Gorillaz")]])
        let engine = TypeaheadEngine(
            library: { _, _ in [] }, registry: registry, configuration: .init(debounce: .milliseconds(120)))
        let clock = ContinuousClock()
        let start = clock.now
        var liveAt: Duration?
        for await snapshot in engine.suggestions("gorillaz") where !snapshot.isEmpty {
            liveAt = clock.now - start
        }
        let arrived = try #require(liveAt)
        #expect(arrived >= .milliseconds(115))
    }

    @Test func aNewerKeystrokeCancelsTheMusicBrainzRequestInFlight() async throws {
        let started = Locked(0)
        let stub = StubMusicBrainz { _ in
            started.withLock { $0 += 1 }
            try await Task.sleep(for: .seconds(5))
            return (200, [:], try fixture("mb-artist-gorill-prefix"))
        }
        let engine = TypeaheadEngine(
            library: { _, _ in [] }, registry: MusicBrainzRegistry(client: stub.client()),
            configuration: .init(debounce: .milliseconds(10)))
        let clock = ContinuousClock()
        let older = engine.suggestions("gorillaz")
        try await Task.sleep(for: .milliseconds(200))
        #expect(started.withLock { $0 } == 1)  // The older request reached the server and is hanging.
        let start = clock.now
        _ = engine.suggestions("gorillaz the")
        _ = await collect(older)
        #expect(clock.now - start < .seconds(2))
    }

    @Test func aLongerPhraseReusesTheShorterPhrasesCachedRows() async throws {
        let stub = StubMusicBrainz { url in
            url.lastPathComponent == "artist"
                ? (200, [:], try fixture("mb-artist-gorill-prefix")) : (200, [:], Data(#"{"count": 0}"#.utf8))
        }
        let registry = MusicBrainzRegistry(client: stub.client())
        for try await _ in registry.suggestions(for: "goril") {}
        let cached = try #require(registry.cachedSuggestions(for: "gorill"))
        #expect(cached.contains { $0.title == "Gorillaz" })
        #expect(registry.cachedSuggestions(for: "blur") == nil)
    }

    @Test func featuredArtistsInTheQueryMatchTheFullCredit() {
        var row = registryRow(.track, "Feel Good Inc.", artist: "Gorillaz")
        row.entity.artistCredit = "Gorillaz featuring De La Soul"
        let ranker = SuggestionRanker(query: "feel good inc feat de la soul")
        #expect(ranker.score(row) > 0.85)
    }
}

@Suite struct PlannerNumberTests {
    @Test func bareNumberTitlesLeadWithTheArtist() {
        let entity = ResolvedEntity(kind: .album, artist: "Adele", album: "21")
        #expect(SoulseekQueryPlanner.plan(for: entity).variants.map(\.query) == ["adele 21"])
    }
}
