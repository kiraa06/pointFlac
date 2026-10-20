import Foundation
import PFCore
import PFTestSupport
import Testing

@testable import PFSearch

/// A deterministic synthetic library: `albums` albums of `tracksPerAlbum` tracks, names built from syllables so the
/// vocabulary is large and realistic (shared prefixes, accents, punctuation), not "Track 1…10000".
enum SyntheticLibrary {
    private static let syllables = [
        "ka", "lo", "mi", "ra", "ne", "so", "tu", "vi", "ze", "dor", "fen", "gal", "hur", "jin", "mar", "nol", "pre",
        "qui", "ros", "sta", "tri", "ven", "wil", "xan", "yor", "zul", "é", "ço", "bel", "cra",
    ]

    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
        mutating func word() -> String {
            let count = 2 + Int(next() % 3)
            var w = ""
            for _ in 0..<count { w += pick(SyntheticLibrary.syllables) }
            return w.prefix(1).uppercased() + w.dropFirst()
        }
        mutating func phrase(_ words: ClosedRange<Int>) -> String {
            let n = words.lowerBound + Int(next() % UInt64(words.count))
            return (0..<n).map { _ in word() }.joined(separator: next() % 9 == 0 ? "-" : " ")
        }
    }

    static func catalog(albums: Int = 1_000, tracksPerAlbum: Int = 10, seed: UInt64 = 42) -> LibraryCatalog {
        var random = Generator(state: seed)
        let artists = (0..<albums / 2).map { _ in random.phrase(1...2) }
        var tracks: [LibraryTrack] = []
        tracks.reserveCapacity(albums * tracksPerAlbum)
        let formats = [(16, 44_100), (24, 96_000), (24, 192_000), (32, 48_000), (24, 44_100)]
        for a in 0..<albums {
            let artist = random.pick(artists)
            let album = random.phrase(1...4)
            let (bits, rate) = random.pick(formats)
            for t in 0..<tracksPerAlbum {
                let title = random.phrase(1...5)
                let albumID = AlbumGrouping.albumID(
                    albumArtist: "", artist: artist, album: album, compilation: false, folder: "\(a)")
                tracks.append(
                    LibraryTrack(
                        id: "t\(a)-\(t)", url: URL(fileURLWithPath: "/m/\(a)/\(t).flac"), title: title, artist: artist,
                        albumArtist: "", album: album, albumID: albumID, discNumber: 1, trackNumber: t + 1,
                        year: 1960 + a % 60, format: AudioFormat(sampleRate: rate, bitsPerSample: bits, channels: 2),
                        totalFrames: Int64(rate * 180), artworkID: nil))
            }
        }
        return LibraryCatalog(tracks: tracks)
    }

    /// What a person types: every prefix of real titles and artists (one keystroke at a time), some multi-word, some
    /// with a typo.
    static func keystrokes(from catalog: LibraryCatalog, count: Int, seed: UInt64 = 7) -> [String] {
        var random = Generator(state: seed)
        let tracks = catalog.tracks.values.sorted { $0.id < $1.id }
        var queries: [String] = []
        while queries.count < count {
            let track = random.pick(tracks)
            let source: String =
                switch random.next() % 4 {
                case 0: track.artist
                case 1: track.album
                case 2: "\(track.artist) \(track.title)"
                default: track.title
                }
            var text = Array(source)
            if random.next() % 5 == 0, text.count > 5 {  // a typo: swap two letters
                let i = 1 + Int(random.next() % UInt64(text.count - 3))
                text.swapAt(i, i + 1)
            }
            for end in 1...min(text.count, 14) where queries.count < count {
                queries.append(String(text[..<end]))
            }
        }
        return queries
    }
}

/// Spec §8: keystroke → local results in < 8 ms of work (one 120 Hz frame). Asserted at 10k tracks on the host, with
/// the CI tolerance (`LatencyBudget`); 100k is measured and printed, not gated, until spike S5 runs on the device.
@Test func searchMeetsTheFrameBudgetAt10kTracks() {
    let catalog = SyntheticLibrary.catalog()
    #expect(catalog.tracks.count == 10_000)
    let buildStart = ContinuousClock.now
    let index = SearchIndex(catalog)
    let buildTime = ContinuousClock.now - buildStart
    let queries = SyntheticLibrary.keystrokes(from: catalog, count: 400)

    for query in queries.prefix(20) { _ = index.search(query) }  // warm-up
    var times: [Duration] = []
    var nonEmpty = 0
    for query in queries {
        let start = ContinuousClock.now
        let results = index.search(query, filter: .all, limit: 50)
        times.append(ContinuousClock.now - start)
        if !results.isEmpty { nonEmpty += 1 }
    }
    var suggestTimes: [Duration] = []
    for query in queries {
        let start = ContinuousClock.now
        _ = index.suggest(query, limit: 8)
        suggestTimes.append(ContinuousClock.now - start)
    }
    times.sort()
    suggestTimes.sort()
    let p95 = times[times.count * 95 / 100]
    let p50 = times[times.count / 2]
    let suggestP95 = suggestTimes[suggestTimes.count * 95 / 100]
    print(
        "Search 10k: build \(buildTime), p50 \(p50), p95 \(p95), max \(times.last!), suggest p95 \(suggestP95), "
            + "\(index.vocabularySize) words, \(nonEmpty)/\(queries.count) non-empty")
    let budget = Duration.milliseconds(8)
    #expect(nonEmpty > queries.count * 9 / 10, "the synthetic keystrokes should mostly find something")
    #expect(p95 < LatencyBudget.scaled(budget), "search p95 \(p95), \(LatencyBudget.describe(budget))")
    #expect(suggestP95 < LatencyBudget.scaled(budget), "suggest p95 \(suggestP95), \(LatencyBudget.describe(budget))")
}
