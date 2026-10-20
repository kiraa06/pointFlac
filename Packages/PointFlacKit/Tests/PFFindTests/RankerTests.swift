import Testing

@testable import PFFind

@Suite struct ResultRankerTests {
    let mountain = ResolvedEntity(
        kind: .album, artist: "Gorillaz", artistAliases: ["Gorilaz"], album: "The Mountain", year: 2026,
        trackCount: 15)

    /// A folder of `count` FLAC files plus the usual cover and log, as a Soulseek peer shares it.
    func folder(
        _ path: String, peer: String, count: Int, bits: Int = 16, rate: Int = 44_100, freeSlot: Bool = true,
        speed: Int = 2_000_000, queue: Int = 0, ext: String = "flac"
    ) -> [CandidateFile] {
        var files = (1...count).map { index in
            CandidateFile(
                path: "\(path)\\\(String(format: "%02d", index)) - Track \(index).\(ext)", sizeBytes: 30_000_000,
                bitsPerSample: bits, sampleRate: rate, peer: peer, freeSlot: freeSlot, speed: speed,
                queueLength: queue)
        }
        files.append(CandidateFile(path: "\(path)\\cover.jpg", peer: peer))
        files.append(CandidateFile(path: "\(path)\\rip.log", peer: peer))
        return files
    }

    @Test func groupsByPeerAndFolderAndDetectsTheCompleteAlbum() throws {
        let files =
            folder(
                #"@@music\Gorillaz\Gorillaz - The Mountain (2026) [FLAC 24-96]"#, peer: "alice", count: 15, bits: 24,
                rate: 96_000)
            + folder(#"@@share\Albums\The Mountain"#, peer: "bob", count: 9)
        let ranked = ResultRanker.rankAlbums(files, for: mountain)
        // Bob's folder never names the artist, so a title-only query's result is filtered out.
        #expect(ranked.count == 1)
        let best = try #require(ranked.first)
        #expect(best.peer == "alice")
        #expect(best.files.count == 15)
        #expect(best.isComplete)
        #expect(best.why == "Complete album · 24/96 · free slot")
    }

    @Test func artistInTheFileNamesIsEnough() throws {
        var files: [CandidateFile] = []
        for index in 1...15 {
            files.append(
                CandidateFile(
                    path: "Music\\The Mountain (2026)\\\(index) Gorillaz - Song \(index).flac", bitsPerSample: 16,
                    sampleRate: 44_100, peer: "carol"))
        }
        let ranked = ResultRanker.rankAlbums(files, for: mountain)
        #expect(ranked.first?.isComplete == true)
    }

    @Test func filtersOutOtherAlbumsThatShareTheTitleWords() {
        let files =
            folder(#"music\The Mountain Goats\Tallahassee"#, peer: "dave", count: 14)
            + folder(#"music\Heaven 17\The Mountain"#, peer: "erin", count: 10)
            + folder(#"music\Gorillaz\Demon Days"#, peer: "fay", count: 15)
        #expect(ResultRanker.rankAlbums(files, for: mountain).isEmpty)
    }

    @Test func flacOnly() {
        let files = folder(#"music\Gorillaz - The Mountain"#, peer: "gus", count: 15, ext: "mp3")
        #expect(ResultRanker.rankAlbums(files, for: mountain).isEmpty)
    }

    @Test func foldsDiscSubfoldersIntoOneAlbum() throws {
        let files =
            folder(#"music\Gorillaz - The Mountain\CD1"#, peer: "hal", count: 8)
            + folder(#"music\Gorillaz - The Mountain\CD2"#, peer: "hal", count: 7)
        let ranked = ResultRanker.rankAlbums(files, for: mountain)
        #expect(ranked.count == 1)
        #expect(ranked.first?.files.count == 15)
        #expect(ranked.first?.isComplete == true)
        #expect(ranked.first?.folder == #"music\Gorillaz - The Mountain"#)
    }

    @Test func completeBeatsIncompleteAndFreeSlotBeatsQueue() throws {
        let files =
            folder(#"a\Gorillaz - The Mountain"#, peer: "partial", count: 11)
            + folder(#"b\Gorillaz - The Mountain"#, peer: "queued", count: 15, freeSlot: false, queue: 40)
            + folder(#"c\Gorillaz - The Mountain"#, peer: "free", count: 15)
        let ranked = ResultRanker.rankAlbums(files, for: mountain)
        #expect(ranked.map { $0.peer ?? "" } == ["free", "queued", "partial"])
        #expect(ranked[1].why == "Complete album · 16/44.1 · queue 40")
        #expect(ranked[2].why == "11 of 15 tracks · 16/44.1 · free slot")
    }

    @Test func respectsTheFormatPreference() throws {
        let files =
            folder(#"a\Gorillaz - The Mountain [16-44]"#, peer: "cd", count: 15)
            + folder(#"b\Gorillaz - The Mountain [24-96]"#, peer: "hires", count: 15, bits: 24, rate: 96_000)
        #expect(ResultRanker.rankAlbums(files, for: mountain).first?.peer == "hires")
        #expect(ResultRanker.rankAlbums(files, for: mountain, preference: .cdQuality).first?.peer == "cd")
        let capped = ResultRanker.rankAlbums(
            files, for: mountain, preference: .atMost(bitsPerSample: 16, sampleRate: 48_000))
        #expect(capped.first?.peer == "cd")
    }

    @Test func dropsPathsWithExcludedPhrases() {
        let files = folder(#"music\Gorillaz - The Mountain"#, peer: "ivy", count: 15)
        #expect(ResultRanker.rankAlbums(files, for: mountain, excludedPhrases: ["gorillaz"]).isEmpty)
    }

    @Test func toleratesTyposDiacriticsAndInvertedArticles() {
        let bjork = ResolvedEntity(kind: .album, artist: "Björk", album: "Homogenic", trackCount: 10)
        let files = folder(#"share\Bjork\1997 - Homogenic"#, peer: "jo", count: 10)
        #expect(ResultRanker.rankAlbums(files, for: bjork).first?.isComplete == true)
        let beatles = ResolvedEntity(kind: .album, artist: "The Beatles", album: "Abbey Road", trackCount: 17)
        let inverted = folder(#"share\Beatles, The\Abbey Road (2019 Mix)"#, peer: "kim", count: 17)
        #expect(ResultRanker.rankAlbums(inverted, for: beatles).count == 1)
    }

    @Test func ranksTracks() throws {
        let entity = ResolvedEntity(kind: .track, artist: "Gorillaz", album: "Demon Days", track: "Feel Good Inc.")
        let files = [
            CandidateFile(
                path: #"music\Gorillaz\Demon Days\06 - Feel Good Inc.flac"#, bitsPerSample: 16, sampleRate: 44_100,
                peer: "a", freeSlot: true),
            CandidateFile(path: #"music\Gorillaz\Demon Days\07 - El Mañana.flac"#, peer: "a"),
            CandidateFile(path: #"music\Other\Feel Good Inc.flac"#, peer: "b"),
            CandidateFile(path: #"music\Gorillaz\Demon Days\06 - Feel Good Inc.mp3"#, peer: "c"),
        ]
        let ranked = ResultRanker.rankTracks(files, for: entity)
        #expect(ranked.count == 1)
        #expect(ranked.first?.why == "16/44.1 · free slot")
    }
}
