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
