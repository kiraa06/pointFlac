import Foundation
import Testing

@testable import PFFind

@Suite struct PoisonedCacheTests {
    @Test func aBlockPageServedWith200IsNeverCached() async throws {
        let calls = Counter()
        let stub = StubMusicBrainz { _ in
            if calls.increment() == 1 {
                return (200, ["Content-Type": "text/html"], Data("<html>Access Restricted</html>".utf8))
            }
            return (200, [:], try fixture("mb-artist-gorill-prefix"))
        }
        let folder = TemporaryDirectory()
        let client = stub.client(disk: DiskCache(directory: folder.url))
        await #expect(throws: MusicBrainzError.undecodable) { _ = try await client.search(.artist, query: "q") }
        #expect(await client.cachedSearch(.artist, query: "q") == nil)
        let second = try await client.search(.artist, query: "q")
        #expect(second.artists?.first?.name == "Gorillaz")
        #expect(stub.requestCount == 2)
    }

    @Test func undecodableCachedBytesAreDeletedAndRefetched() async throws {
        let stub = StubMusicBrainz { _ in (200, [:], try fixture("mb-artist-gorill-prefix")) }
        let folder = TemporaryDirectory()
        let disk = DiskCache(directory: folder.url)
        let url = stub.client().searchURL(.artist, query: "q", limit: 8)
        disk.write(Data("<html>blocked</html>".utf8), for: url.absoluteString)
        let response = try await stub.client(disk: disk).search(.artist, query: "q")
        #expect(response.artists?.first?.name == "Gorillaz")
        #expect(stub.requestCount == 1)
        #expect(
            try JSONDecoder().decode(MB.SearchResponse.self, from: #require(disk.read(url.absoluteString)?.data))
                .artists?.isEmpty == false)
    }

    @Test func memoryCacheHasAByteCap() {
        let cache = LRUCache<String, Data>(capacity: 100, maxCost: 1_000, cost: { $0.count })
        for index in 0..<5 { cache.insert(Data(count: 400), for: "k\(index)") }
        #expect(cache.totalCost <= 1_000)
        #expect(cache.value(for: "k4") != nil)
        #expect(cache.value(for: "k0") == nil)
    }
}

@Suite struct RegistrySwitchTests {
    @Test func switchingOffCancelsInFlightWorkAndClearsTheDiskCache() async throws {
        let started = Locked(0)
        let stub = StubMusicBrainz { url in
            started.withLock { $0 += 1 }
            if url.query?.contains("slow") == true { try await Task.sleep(for: .seconds(5)) }
            return (200, [:], try fixture("mb-artist-gorill-prefix"))
        }
        let folder = TemporaryDirectory()
        let client = stub.client(disk: DiskCache(directory: folder.url))
        _ = try await client.search(.artist, query: "cached")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).count == 1)
        let search = SmartSearch(
            library: { _, _ in [] }, registry: MusicBrainzRegistry(client: client, order: [.artist]))
        let stream = search.suggestions("slow gorillaz")
        let deadline = ContinuousClock.now + .seconds(10)
        while started.withLock({ $0 }) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let clock = ContinuousClock()
        let start = clock.now
        await search.setRegistryEnabled(false)
        _ = await collect(stream)
        #expect(clock.now - start < .seconds(2))
        #expect(!search.isRegistryEnabled)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
        let before = stub.requestCount
        _ = await collect(search.suggestions("gorillaz again"))
        #expect(stub.requestCount == before)
        await search.setRegistryEnabled(true)
        #expect(search.isRegistryEnabled)
    }
}

@Suite struct PlannerFixTests {
    @Test(arguments: [
        ("R.E.M.", "r e m"), ("T.I.", "t i"), ("N.W.A", "n w a"), ("B'z", "b z"), ("嵐", "嵐"), ("!!!", "!!!"),
        ("P!nk", "p nk"), ("a-ha", "a ha"), ("Jay-Z", "jay z"), ("X Japan", "x japan"), ("The The", "the the"),
    ])
    func artistNamesSurvive(artist: String, expected: String) {
        let plan = SoulseekQueryPlanner.plan(for: ResolvedEntity(kind: .artist, artist: artist))
        #expect(plan.variants.first?.query == expected)
    }

    @Test func emptyPlansAlwaysSayWhy() {
        let blank = SoulseekQueryPlanner.plan(for: ResolvedEntity(kind: .artist, artist: "   "))
        #expect(blank.variants.isEmpty)
        #expect(blank.emptyReason == .noSearchableWords)
        let excluded = SoulseekQueryPlanner.plan(
            for: ResolvedEntity(kind: .album, artist: "Some Band", album: "Night Songs"),
            excludedPhrases: ["night", "band"])
        #expect(excluded.emptyReason == .excludedPhrase("band"))
        let every = SoulseekQueryPlanner.plan(
            for: ResolvedEntity(kind: .album, artist: "Moon", album: "Blue Sky"), excludedPhrases: ["sky"])
        #expect(every.emptyReason == .excludedPhrase("sky"))
    }

    @Test func tinyExcludedPhrasesAreIgnoredAndQueriesAreCapped() {
        let entity = ResolvedEntity(
            kind: .album, artist: "Godspeed You Black Emperor", album: "Lift Your Skinny Fists Like Antennas to Heaven")
        let plan = SoulseekQueryPlanner.plan(for: entity, excludedPhrases: ["", "a", " "])
        #expect(!plan.variants.isEmpty)
        #expect(plan.variants.allSatisfy { $0.query.split(separator: " ").count <= 6 })
    }
}

@Suite struct RankerFixTests {
    @Test func theTheDoesNotMatchEveryFolderWithThe() {
        let entity = ResolvedEntity(kind: .album, artist: "The The", album: "Soul Mining", trackCount: 8)
        let wrong = (1...8).map { CandidateFile(path: #"music\The Smiths\Soul Mining\"# + "\($0).flac", peer: "a") }
        let right = (1...8).map { CandidateFile(path: #"music\The The\Soul Mining\"# + "\($0).flac", peer: "b") }
        #expect(ResultRanker.rankAlbums(wrong + right, for: entity).map { $0.peer ?? "" } == ["b"])
    }

    @Test func oversizedFoldersAreNotCompleteAndSaySo() throws {
        let entity = ResolvedEntity(kind: .album, artist: "Gorillaz", album: "The Mountain", trackCount: 15)
        let files = (1...40).map {
            CandidateFile(path: #"music\Gorillaz - The Mountain (everything)\"# + "\($0).flac", peer: "a")
        }
        let ranked = try #require(ResultRanker.rankAlbums(files, for: entity).first)
        #expect(!ranked.isComplete)
        #expect(ranked.why.hasPrefix("40 tracks (more than expected)"))
    }

    @Test func discFoldersFoldByPrefixAndFormatTiesAreDeterministic() throws {
        let entity = ResolvedEntity(kind: .album, artist: "Gorillaz", album: "The Mountain", trackCount: 4)
        let files = [
            CandidateFile(
                path: #"m\Gorillaz - The Mountain\CD1 - Disc One\1.flac"#, bitsPerSample: 16, sampleRate: 44_100),
            CandidateFile(
                path: #"m\Gorillaz - The Mountain\CD1 - Disc One\2.flac"#, bitsPerSample: 24, sampleRate: 96_000),
            CandidateFile(
                path: #"m\Gorillaz - The Mountain\Disc 2 of 2\3.flac"#, bitsPerSample: 16, sampleRate: 44_100),
            CandidateFile(
                path: #"m\Gorillaz - The Mountain\Disc 2 of 2\4.flac"#, bitsPerSample: 24, sampleRate: 96_000),
        ]
        let ranked = try #require(ResultRanker.rankAlbums(files, for: entity).first)
        #expect(ranked.files.count == 4)
        #expect(ranked.bitsPerSample == 24)
        #expect(ranked.sampleRate == 96_000)
    }

    @Test func ranksABroadQueryQuickly() {
        let entity = ResolvedEntity(
            kind: .album, artist: "Gorillaz",
            artistAliases: [
                "Gorilaz", "Gorrilaz", "Gorillas", "Gorrillaz", "Gorilazz", "Gorillaz.", "Gorrilas",
                "Gorillaz Band",
            ],
            album: "The Mountain", trackCount: 15)
        var files: [CandidateFile] = []
        for folder in 0..<300 {
            let name =
                folder.isMultiple(of: 25) ? "Gorillaz - The Mountain" : "Artist \(folder) - The Mountain \(folder)"
            for track in 0..<12 where files.count < 3_556 {
                files.append(
                    CandidateFile(path: "@@peer\(folder)\\Music\\\(name)\\\(track) - Song.flac", peer: "p\(folder)"))
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let ranked = ResultRanker.rankAlbums(files, for: entity)
        let elapsed = clock.now - start
        print("rank 3,556 files with 9 artist names: \(elapsed)")
        #expect(ranked.count == 12)
        #if DEBUG
            #expect(elapsed < .seconds(2))
        #else
            // Measured 131 ms in a release build (it was 6.6 s before the review fixes). The goal is < 50 ms; the
            // runner already throttles re-ranking to one per 250 ms, so this guards against regressions without
            // claiming the goal is met. Next step: cache the folded folder name per folder.
            #expect(elapsed < .milliseconds(250))
        #endif
    }

    @Test func runnerFindsTracksWithNoAlbum() async {
        let entity = ResolvedEntity(kind: .track, artist: "Gorillaz", track: "Feel Good Inc.")
        let runner = SearchPlanRunner(bucket: TokenBucket(interval: .milliseconds(1)))
        let file = CandidateFile(path: #"m\Gorillaz\06 - Feel Good Inc.flac"#, peer: "a", freeSlot: true)
        let ranked = await collect(
            runner.tracks(SoulseekQueryPlanner.plan(for: entity), for: entity) { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield([file])
                    continuation.finish()
                }
            })
        #expect(ranked.last?.first?.file == file)
    }
}

@Suite struct BoundedInputTests {
    @Test func aHugePasteIsBoundedAndFast() async {
        let paste = String(repeating: "gorillaz the mountain ", count: 3_000)
        #expect(FindText.bounded(paste).count <= 100)
        #expect(
            FindText.bounded("one two three four five six seven eight nine ten eleven twelve thirteen")
                == "one two three four five six seven eight nine ten eleven twelve ")
        let registry = MusicBrainzRegistry(client: StubMusicBrainz { _ in (200, [:], Data()) }.client())
        let clock = ContinuousClock()
        let start = clock.now
        _ = registry.cachedSuggestions(for: paste)
        let engine = TypeaheadEngine(library: { _, _ in [] }, registry: nil)
        _ = await collect(engine.suggestions(paste))
        #expect(clock.now - start < .milliseconds(500))
    }
}
