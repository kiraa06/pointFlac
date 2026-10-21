import Foundation
import PFCore
import Testing

@testable import PFSearch

/// A library track for search tests; the album key comes from the same rule the library uses.
func makeTrack(
    _ title: String, artist: String, album: String, albumArtist: String = "", number: Int? = nil, bits: Int = 16,
    rate: Int = 44_100, id: String? = nil
) -> LibraryTrack {
    let albumID = AlbumGrouping.albumID(
        albumArtist: albumArtist, artist: artist, album: album, compilation: false, folder: "f")
    return LibraryTrack(
        id: id ?? "\(artist)|\(album)|\(title)", url: URL(fileURLWithPath: "/music/\(title).flac"), title: title,
        artist: artist, albumArtist: albumArtist, album: album, albumID: albumID, discNumber: 1, trackNumber: number,
        year: 1990, format: AudioFormat(sampleRate: rate, bitsPerSample: bits, channels: 2), totalFrames: 44_100 * 200,
        artworkID: nil, isInLibraryFolder: true)
}

/// A small library with the cases the ranking rules care about.
let sampleCatalog = LibraryCatalog(tracks: [
    makeTrack("Paranoid Android", artist: "Radiohead", album: "OK Computer", number: 2, bits: 24, rate: 96_000),
    makeTrack("Karma Police", artist: "Radiohead", album: "OK Computer", number: 6, bits: 24, rate: 96_000),
    makeTrack("Airbag", artist: "Radiohead", album: "OK Computer", number: 1, bits: 24, rate: 96_000),
    makeTrack("Help!", artist: "The Beatles", album: "Help!", number: 1),
    makeTrack("Yesterday", artist: "The Beatles", album: "Help!", number: 13),
    makeTrack("Something", artist: "The Beatles", album: "Abbey Road", number: 2, bits: 24, rate: 192_000),
    makeTrack("Help Me", artist: "Joni Mitchell", album: "Court and Spark", number: 3),
    makeTrack("Hélène", artist: "Françoise Hardy", album: "Comment te dire adieu", number: 4),
    makeTrack("Back in Black", artist: "AC/DC", album: "Back in Black", number: 6, bits: 32, rate: 48_000),
    makeTrack("Don't Stop Me Now", artist: "Queen", album: "Jazz", number: 12),
    makeTrack("Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera", number: 11),
    makeTrack("Computer Love", artist: "Kraftwerk", album: "Computer World", number: 4),
])

let sampleIndex = SearchIndex(sampleCatalog)

@Test func foldsCaseAccentsWidthAndPunctuation() {
    #expect(
        TextFolding.queryTokens("Françoise HARDY") == [
            Array("francoise".unicodeScalars.map(\.value)), Array("hardy".unicodeScalars.map(\.value)),
        ])
    #expect(TextFolding.queryTokens("ＡＢＣ") == TextFolding.queryTokens("abc"))
    #expect(TextFolding.queryTokens("AC/DC") == TextFolding.queryTokens("acdc"))
    #expect(TextFolding.queryTokens("  don't   stop ") == TextFolding.queryTokens("dont stop"))
    let words = TextFolding.words("AC/DC")
    #expect(words.count == 1 && words[0].pieces.count == 2)
}

@Test func exactTitleOutranksPrefixAndOtherFields() {
    let results = sampleIndex.search("help")
    // Album "Help!" (exact title, album kind) first, then the track "Help!".
    #expect(results.albums.first?.title == "Help!")
    #expect(results.tracks.map(\.title).prefix(2) == ["Help!", "Help Me"])
    // "Yesterday" is on the album Help!: an album-field match, ranked below title matches.
    #expect(results.tracks.map(\.title).contains("Yesterday"))
    #expect(
        results.tracks.firstIndex { $0.title == "Yesterday" }! > results.tracks.firstIndex { $0.title == "Help Me" }!)
    #expect(results.tracks.first?.match == .exact)
}

@Test func prefixMatchesWhileTyping() {
    #expect(sampleIndex.search("par").tracks.first?.title == "Paranoid Android")
    #expect(sampleIndex.search("radio").artists.first?.title == "Radiohead")
    #expect(sampleIndex.search("radio").albums.first?.title == "OK Computer")
    #expect(sampleIndex.search("ok comp").albums.map(\.title) == ["OK Computer"])
    #expect(sampleIndex.search("p").tracks.contains { $0.title == "Karma Police" })
    #expect(sampleIndex.search("par").tracks.first?.match == .prefix)
}

@Test func accentsAndCaseNeverMatter() {
    #expect(sampleIndex.search("helene").tracks.first?.title == "Hélène")
    #expect(sampleIndex.search("FRANCOISE").artists.first?.title == "Françoise Hardy")
    #expect(sampleIndex.search("Françoise").tracks.first?.title == "Hélène")
}

@Test func punctuationIsIgnored() {
    #expect(sampleIndex.search("acdc").artists.first?.title == "AC/DC")
    #expect(sampleIndex.search("ac/dc").artists.first?.title == "AC/DC")
    #expect(sampleIndex.search("dc").artists.first?.title == "AC/DC")
    #expect(sampleIndex.search("dont stop").tracks.first?.title == "Don't Stop Me Now")
    #expect(sampleIndex.search("don't").tracks.first?.title == "Don't Stop Me Now")
}

@Test func oneTypoIsForgivenAndRanksLast() {
    // Transposition, substitution, deletion, insertion.
    #expect(sampleIndex.search("beatels").artists.first?.title == "The Beatles")
    #expect(sampleIndex.search("radiohaed").artists.first?.title == "Radiohead")
    #expect(sampleIndex.search("bohemain").tracks.first?.title == "Bohemian Rhapsody")
    #expect(sampleIndex.search("rapsody").tracks.first?.title == "Bohemian Rhapsody")
    #expect(sampleIndex.search("kraftwwerk").artists.first?.title == "Kraftwerk")
    #expect(sampleIndex.search("beatels").artists.first?.match == .fuzzy)
    // A typo while still typing: "compu" is a prefix; "cmoputer" is one swap from "computer".
    #expect(sampleIndex.search("cmoputer").albums.map(\.title).contains("OK Computer"))
    // Tokens under five letters get no typo tolerance: "hlep" and "hep" find nothing.
    #expect(sampleIndex.search("hep").isEmpty)
    #expect(sampleIndex.search("hlep").isEmpty)
    #expect(!sampleIndex.search("yesterdya").tracks.isEmpty)
    // Two edits are too many.
    #expect(sampleIndex.search("baetels").artists.isEmpty)
}

@Test func exactBeatsPrefixBeatsFuzzy() {
    // "comput" is a prefix of "computer"; with a typo it would rank below. Albums: "Computer World" (title start)
    // above "OK Computer" (title word, not at the start).
    let albums = sampleIndex.search("computer").albums.map(\.title)
    #expect(albums == ["Computer World", "OK Computer"])
    // Exact word "love" (track title) outranks a typo neighbour.
    let tracks = sampleIndex.search("love").tracks
    #expect(tracks.first?.title == "Computer Love")
}

@Test func everyTokenMustMatch() {
    #expect(sampleIndex.search("radiohead karma").tracks.map(\.title) == ["Karma Police"])
    #expect(sampleIndex.search("queen opera").tracks.map(\.title) == ["Bohemian Rhapsody"])
    #expect(sampleIndex.search("queen zzzz").isEmpty)
}

@Test func albumsAboveSongsWhenTheAlbumMatches() {
    let hits = sampleIndex.suggest("back in black", limit: 5)
    #expect(hits.first?.kind == .album)
    #expect(hits.first?.title == "Back in Black")
    #expect(hits.dropFirst().first?.kind == .track)
    let abbey = sampleIndex.suggest("abbey", limit: 5)
    #expect(abbey.first?.kind == .album && abbey.first?.title == "Abbey Road")
}

@Test func filters() {
    #expect(sampleIndex.search("radiohead", filter: .albums).tracks.isEmpty)
    #expect(sampleIndex.search("radiohead", filter: .albums).artists.isEmpty)
    #expect(sampleIndex.search("radiohead", filter: .songs).albums.isEmpty)
    #expect(sampleIndex.search("radiohead", filter: .songs).tracks.count == 3)
    #expect(sampleIndex.search("beatles", filter: .hiRes24).tracks.map(\.title) == ["Something"])
    #expect(sampleIndex.search("beatles", filter: .hiRes24).albums.map(\.title) == ["Abbey Road"])
    #expect(sampleIndex.search("back", filter: .bit32).tracks.map(\.title) == ["Back in Black"])
    #expect(sampleIndex.search("beatles", filter: .rate96).tracks.map(\.title) == ["Something"])
    #expect(sampleIndex.search("queen", filter: .rate96).isEmpty)
    // An empty query lists the library under a chip, and finds nothing under All.
    #expect(sampleIndex.search("", filter: .all).isEmpty)
    #expect(Set(sampleIndex.search("", filter: .rate96).albums.map(\.title)) == ["OK Computer", "Abbey Road"])
    #expect(sampleIndex.search("", filter: .bit32).tracks.map(\.title) == ["Back in Black"])
}

/// The highlighted letters of `hit.title`.
private func highlighted(_ text: String, _ ranges: [Range<String.Index>]) -> [String] {
    ranges.map { String(text[$0]) }
}

@Test func highlightsMatchedLetters() {
    let hit = try! #require(sampleIndex.search("para").tracks.first)
    #expect(highlighted(hit.title, hit.titleHighlights) == ["Para"])
    let accent = try! #require(sampleIndex.search("hel").tracks.first { $0.title == "Hélène" })
    #expect(highlighted(accent.title, accent.titleHighlights) == ["Hél"])
    let two = try! #require(sampleIndex.search("radio karma").tracks.first)
    #expect(highlighted(two.title, two.titleHighlights) == ["Karma"])
    #expect(highlighted(two.subtitle, two.subtitleHighlights) == ["Radio"])
    let piece = try! #require(sampleIndex.search("dc").artists.first)
    #expect(highlighted(piece.title, piece.titleHighlights) == ["DC"])
    let joined = try! #require(sampleIndex.search("acd").artists.first)
    #expect(highlighted(joined.title, joined.titleHighlights) == ["AC/D"])
    let typo = try! #require(sampleIndex.search("beatels").artists.first)
    #expect(highlighted(typo.title, typo.titleHighlights) == ["Beatles"])
    let punctuated = TextFolding.highlights(in: "(Live) Help!", query: TextFolding.queryTokens("live help"))
    #expect(highlighted("(Live) Help!", punctuated) == ["Live", "Help"])
}

@Test func suggestIsSyncAndBounded() {
    let hits = sampleIndex.suggest("radio", limit: 3)
    #expect(hits.count == 3)
    #expect(hits.first?.kind == .artist && hits.first?.title == "Radiohead")
    #expect(sampleIndex.suggest("", limit: 5).isEmpty)
    #expect(sampleIndex.suggest("radio", limit: 0).isEmpty)
    #expect(sampleIndex.suggest("radio", limit: .max).count == 5)
    #expect(sampleIndex.search("radio", limit: .max).tracks.count == 3)
    #expect(hits.allSatisfy { !$0.id.isEmpty && !$0.subtitle.isEmpty })
}

/// Spec §6.2 "incremental update correctness": a new catalog gives a new index that sees exactly the new library.
@Test func rebuiltIndexFollowsTheCatalog() {
    var tracks = Array(sampleCatalog.tracks.values)
    tracks.removeAll { $0.artist == "Queen" }
    tracks.append(makeTrack("Queenie Eye", artist: "Paul McCartney", album: "New"))
    let index = SearchIndex(LibraryCatalog(tracks: tracks))
    #expect(index.search("queen").tracks.map(\.title) == ["Queenie Eye"])
    #expect(index.search("bohemian").isEmpty)
    #expect(sampleIndex.search("bohemian").tracks.count == 1)
}

@Test func snapshotMapsHitsBackToTheCatalog() {
    let snapshot = LibrarySnapshot(sampleCatalog)
    let album = try! #require(snapshot.search("ok computer").albums.first)
    let tracks = snapshot.tracks(of: album.id)
    #expect(tracks.map(\.title) == ["Airbag", "Paranoid Android", "Karma Police"])
    #expect(snapshot.album(album.id)?.formatLabel == "FLAC 24/96")
    let ids = snapshot.search("karma").tracks.map(\.id) + ["missing"]
    #expect(snapshot.tracks(ids: ids).map(\.title) == ["Karma Police"])
}

@Test func emptyLibrarySearchesSafely() {
    let index = SearchIndex(.empty)
    #expect(index.search("anything").isEmpty)
    #expect(index.suggest("a", limit: 10).isEmpty)
    #expect(index.search("", filter: .albums).isEmpty)
}

@Test func hostileQueriesStayBounded() {
    let long = String(repeating: "a ", count: 5_000)
    #expect(sampleIndex.search(long).elapsed < .seconds(1))
    _ = sampleIndex.search("\u{0}\u{FEFF}🎵🎶 Ω≈ç√")
    _ = sampleIndex.search(String(repeating: "x", count: 10_000))
}

/// The review's false positives at four letters: none of them match any more.
@Test func shortWordsHaveNoTypoNeighbours() {
    let catalog = LibraryCatalog(tracks: [
        makeTrack("Bertrand", artist: "Bear", album: "With You"),
        makeTrack("Beat It", artist: "Michael Jackson", album: "Thriller"),
    ])
    let index = SearchIndex(catalog)
    #expect(index.search("beat").tracks.map(\.title) == ["Beat It"])
    #expect(index.search("beat").artists.isEmpty)
    #expect(index.search("wish").isEmpty)
    #expect(index.search("bert").tracks.map(\.title) == ["Bertrand"])
}

/// Spec §5.5 tier 3: three letters or more also match inside a word, below prefixes and above typos, with the inner
/// letters highlighted. CJK titles have no spaces, so this is how a name inside one is found.
@Test func substringsMatchInsideWords() {
    let catalog = LibraryCatalog(tracks: [
        makeTrack("Glove", artist: "Hands", album: "Wear"),
        makeTrack("Love Song", artist: "Adele", album: "21"),
        makeTrack("First Love", artist: "宇多田ヒカル", album: "First Love"),
        makeTrack("Loveless", artist: "MBV", album: "Loveless"),
        makeTrack("Lovely", artist: "Billie", album: "Single"),
    ])
    let index = SearchIndex(catalog)
    let love = index.search("love").tracks
    // Exact and prefix matches first; "Glove" (inside the word) after them.
    #expect(love.last?.title == "Glove")
    #expect(love.last?.match == .substring)
    #expect(love.first?.match == .exact)
    let ove = index.search("ove").tracks
    #expect(Set(ove.map(\.title)) == ["Glove", "Love Song", "First Love", "Loveless", "Lovely"])
    #expect(ove.allSatisfy { $0.match == .substring })
    let glove = try! #require(ove.first { $0.title == "Glove" })
    #expect(glove.titleHighlights.map { String(glove.title[$0]) } == ["ove"])
    let hikaru = index.search("ヒカル")
    #expect(hikaru.artists.map(\.title) == ["宇多田ヒカル"])
    #expect(hikaru.tracks.map(\.title) == ["First Love"])
    let artist = try! #require(hikaru.artists.first)
    #expect(artist.titleHighlights.map { String(artist.title[$0]) } == ["ヒカル"])
    // Two letters never match inside a word.
    #expect(index.search("ov").isEmpty)
    // A substring hit still ranks above a typo hit.
    let mixed = SearchIndex(
        LibraryCatalog(tracks: [
            makeTrack("Overture", artist: "X", album: "Y"),
            makeTrack("Ballroom", artist: "X", album: "Z"),
        ]))
    #expect(mixed.search("allro").tracks.first?.title == "Ballroom")
}
