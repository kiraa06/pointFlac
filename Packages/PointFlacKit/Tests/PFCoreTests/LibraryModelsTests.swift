import Foundation
import Testing

@testable import PFCore

private func track(
    _ id: String, title: String = "T", artist: String = "A", albumArtist: String = "", album: String = "Al",
    disc: Int? = nil, number: Int? = nil, year: Int? = nil, bits: Int = 16, rate: Int = 44_100
) -> LibraryTrack {
    LibraryTrack(
        id: id, url: URL(fileURLWithPath: "/\(id).flac"), title: title, artist: artist, albumArtist: albumArtist,
        album: album,
        albumID: AlbumGrouping.albumID(
            albumArtist: albumArtist, artist: artist, album: album, compilation: false, folder: "f"),
        discNumber: disc, trackNumber: number, year: year,
        format: AudioFormat(sampleRate: rate, bitsPerSample: bits, channels: 2), totalFrames: Int64(rate) * 3,
        artworkID: nil)
}

@Test func albumKeysFoldCaseAccentsAndSpaces() {
    let a = AlbumGrouping.albumID(
        albumArtist: "", artist: "Beyoncé", album: "Lemonade", compilation: false, folder: "x")
    let b = AlbumGrouping.albumID(
        albumArtist: "", artist: " beyonce ", album: "LEMONADE", compilation: false, folder: "y")
    #expect(a == b)
    let various = AlbumGrouping.albumID(albumArtist: "", artist: "P", album: "Hits", compilation: true, folder: "x")
    #expect(
        various
            == AlbumGrouping.albumID(
                albumArtist: "Various Artists", artist: "Q", album: "Hits", compilation: false, folder: "z"))
    // Untitled albums stay apart per folder.
    #expect(
        AlbumGrouping.albumID(albumArtist: "", artist: "P", album: "", compilation: false, folder: "x")
            != AlbumGrouping.albumID(albumArtist: "", artist: "P", album: "", compilation: false, folder: "y"))
    #expect(a.count == 32)
}

@Test func catalogOrdersShelfAndTracks() {
    let catalog = LibraryCatalog(tracks: [
        track("3", title: "Gamma", artist: "Zed", album: "Last", number: 1, year: 2001),
        track("2", title: "Beta", artist: "Abe", album: "Second", disc: 2, number: 1, year: 1999),
        track(
            "1", title: "Alpha", artist: "Abe", album: "Second", disc: 1, number: 9, year: 1999, bits: 24, rate: 96_000),
        track("4", title: "Untracked", artist: "Abe", album: "Second", disc: 1, year: 1999),
        track("5", title: "First", artist: "Abe", album: "First", number: 1, year: 1980),
    ])
    #expect(catalog.albums.map(\.title) == ["First", "Second", "Last"])
    let second = catalog.albums[1]
    #expect(catalog.tracks(of: second.id).map(\.title) == ["Alpha", "Untracked", "Beta"])
    #expect(second.bestFormat == AudioFormat(sampleRate: 96_000, bitsPerSample: 24, channels: 2))
    #expect(second.formatLabel == "FLAC 24/96")
    #expect(catalog.tracks(ids: ["5", "missing", "3"]).map(\.title) == ["First", "Gamma"])
    #expect(catalog.tracks(of: "nope").isEmpty && catalog.album("nope") == nil)
    #expect(catalog.tracks["1"]?.durationSeconds == 3)
    #expect(catalog.tracks["3"]?.formatLabel == "FLAC 16/44.1")
}

@Test func bestFormatPrefersBitsThenRate() {
    let a = AudioFormat(sampleRate: 192_000, bitsPerSample: 16, channels: 2)
    let b = AudioFormat(sampleRate: 44_100, bitsPerSample: 24, channels: 2)
    let c = AudioFormat(sampleRate: 96_000, bitsPerSample: 24, channels: 2)
    #expect(AlbumGrouping.lowerResolution(a, b))
    #expect(AlbumGrouping.lowerResolution(b, c))
    #expect(!AlbumGrouping.lowerResolution(c, b))
    #expect(
        LibraryAlbum.formatLabel(AudioFormat(sampleRate: 352_800, bitsPerSample: 32, channels: 2)) == "FLAC 32/352.8")
}

@Test func stableHashIsDeterministic() {
    #expect(StableHash.hex(of: Array("abc".utf8)) == StableHash.hex(of: Array("abc".utf8)))
    #expect(StableHash.hex(of: Array("abc".utf8)) != StableHash.hex(of: Array("abd".utf8)))
    #expect(StableHash.hex(of: []).count == 32)
}
