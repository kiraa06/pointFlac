import Foundation
import Testing

@testable import PFFind

@Suite struct SearchPlanRunnerTests {
    let mountain = ResolvedEntity(kind: .album, artist: "Gorillaz", album: "The Mountain", trackCount: 3)

    func album(peer: String, tracks: Int = 3) -> [CandidateFile] {
        (1...tracks).map { index in
            CandidateFile(
                path: #"music\Gorillaz - The Mountain\"# + "0\(index).flac", bitsPerSample: 16, sampleRate: 44_100,
                peer: peer, freeSlot: true)
        }
    }

    @Test func stopsOnceThereAreEnoughCompleteAlbums() async {
        let asked = Locked<[String]>([])
        let files = album(peer: "a") + album(peer: "b") + album(peer: "c")
        let runner = SearchPlanRunner(bucket: TokenBucket(interval: .milliseconds(10)), enoughComplete: 3)
        let plan = SoulseekQueryPlanner.plan(for: mountain)
        let emissions = await collect(
            runner.albums(plan, for: mountain) { query in
                asked.withLock { $0.append(query) }
                return AsyncThrowingStream { continuation in
                    continuation.yield(files)
                    continuation.finish()
                }
            })
        #expect(asked.withLock { $0 } == ["the mountain"])
        #expect(emissions.last?.count == 3)
        #expect(emissions.last?.allSatisfy(\.isComplete) == true)
    }

    @Test func runsTheNextVariantWhenTheFirstIsNotEnoughSpacedByTheBucket() async {
        let asked = Locked<[String]>([])
        let runner = SearchPlanRunner(bucket: TokenBucket(interval: .milliseconds(200)), enoughComplete: 1)
        let plan = SoulseekQueryPlanner.plan(for: mountain)
        let files = album(peer: "late")
        let start = ContinuousClock.now
        let emissions = await collect(
            runner.albums(plan, for: mountain) { query in
                asked.withLock { $0.append(query) }
                return AsyncThrowingStream { continuation in
                    if query == "the mountain" {
                        continuation.finish(throwing: URLError(.timedOut))
                    } else {
                        continuation.yield(files)
                        continuation.finish()
                    }
                }
            })
        #expect(asked.withLock { $0 } == ["the mountain", "gorillaz mountain"])
        #expect(ContinuousClock.now - start >= .milliseconds(195))
        #expect(emissions.last?.first?.peer == "late")
    }

    @Test func anEmptyPlanSearchesNothing() async {
        let asked = Locked<[String]>([])
        let plan = SoulseekQueryPlanner.plan(for: mountain, excludedPhrases: ["gorillaz"])
        let emissions = await collect(
            SearchPlanRunner(bucket: TokenBucket(interval: .milliseconds(1))).albums(plan, for: mountain) { query in
                asked.withLock { $0.append(query) }
                return AsyncThrowingStream { $0.finish() }
            })
        #expect(emissions.isEmpty)
        #expect(asked.withLock { $0 }.isEmpty)
    }
}

@Suite struct CoverArtArchiveTests {
    @Test func fetchesOnceAndRemembersMissingCovers() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let stub = StubMusicBrainz { url in
            url.path.contains("has-art") ? (200, [:], png) : (404, [:], Data())
        }
        let folder = TemporaryDirectory()
        let art = CoverArtArchive(
            configuration: .init(baseURL: URL(string: "https://\(stub.host)/")!), session: stub.session,
            bucket: TokenBucket(interval: .milliseconds(1)), disk: DiskCache(directory: folder.url))
        #expect(await art.thumbnail(releaseGroupID: "has-art") == png)
        #expect(await art.thumbnail(releaseGroupID: "has-art") == png)
        #expect(await art.thumbnail(releaseGroupID: "no-art") == nil)
        #expect(await art.thumbnail(releaseGroupID: "no-art") == nil)
        #expect(stub.requestCount == 2)
        let path = try #require(stub.requests.withLock { $0.first?.url.path })
        #expect(path == "/release-group/has-art/front-250")
    }

    @Test func refusesOversizedImages() async {
        let stub = StubMusicBrainz { _ in (200, [:], Data(repeating: 1, count: 2048)) }
        let art = CoverArtArchive(
            configuration: .init(baseURL: URL(string: "https://\(stub.host)/")!, maxImageBytes: 1024),
            session: stub.session, bucket: TokenBucket(interval: .milliseconds(1)), disk: nil)
        #expect(await art.thumbnail(releaseGroupID: "huge") == nil)
    }
}

@Suite struct RecordedTypoTests {
    static let empty = Data(#"{"count": 0}"#.utf8)

    @Test func typoInArtistAndTitleStillFindsOKComputer() async throws {
        let stub = StubMusicBrainz { url in
            url.lastPathComponent == "release-group"
                ? (200, [:], try fixture("mb-release-group-radiohed-ok-computer")) : (200, [:], Self.empty)
        }
        let engine = TypeaheadEngine(
            library: { _, _ in [] }, registry: MusicBrainzRegistry(client: stub.client()),
            configuration: .init(debounce: .milliseconds(10)))
        let last = try #require(await collect(engine.suggestions("radiohed ok computer")).last)
        #expect(last.first?.title == "OK Computer")
        #expect(last.first?.entity.artist == "Radiohead")
        let query = luceneQuery(try #require(stub.requests.withLock { $0.first?.url }))
        #expect(query.contains("radiohed~1"))
    }

    @Test func misspelledArtistResolvesThroughAliases() async throws {
        let stub = StubMusicBrainz { url in
            url.lastPathComponent == "artist"
                ? (200, [:], try fixture("mb-artist-gorilaz-typo")) : (200, [:], Self.empty)
        }
        let engine = TypeaheadEngine(
            library: { _, _ in [] }, registry: MusicBrainzRegistry(client: stub.client()),
            configuration: .init(debounce: .milliseconds(10)))
        let last = try #require(await collect(engine.suggestions("gorilaz ")).last)
        #expect(last.first?.kind == .artist)
        #expect(last.first?.title == "Gorillaz")
    }
}
