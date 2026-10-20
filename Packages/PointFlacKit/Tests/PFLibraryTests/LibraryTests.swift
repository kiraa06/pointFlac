import Foundation
import ImageIO
import PFCore
import PFFlac
import PFTestSupport
import Testing

@testable import PFLibrary

/// A library in a fresh temporary folder, removed when the test ends.
private final class TemporaryLibraryRoot {
    let root: URL
    var libraryFolder: URL { root.appending(path: "Documents/Library", directoryHint: .isDirectory) }
    var database: URL { root.appending(path: "Support/library.sqlite") }
    var artwork: URL { root.appending(path: "Support/Artwork", directoryHint: .isDirectory) }
    var outside: URL { root.appending(path: "Picked", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "LibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func open() throws -> Library {
        try Library(databaseURL: database, libraryFolder: libraryFolder, artworkFolder: artwork)
    }

    /// A tagged copy of `fixture` outside the library, as the document picker would hand it over.
    func picked(_ fixture: String, as name: String, tags: [(String, String)], picture: Data? = nil) throws -> URL {
        let url = outside.appending(path: UUID().uuidString).appending(path: name)
        try TaggedFlac.write(fixture, to: url, tags: tags, picture: picture)
        return url
    }
}

private func tags(
    title: String, artist: String, album: String, number: Int? = nil, albumArtist: String? = nil, disc: Int? = nil,
    year: Int? = nil
) -> [(String, String)] {
    var tags = [("TITLE", title), ("ARTIST", artist), ("ALBUM", album)]
    if let number { tags.append(("TRACKNUMBER", "\(number)")) }
    if let albumArtist { tags.append(("ALBUMARTIST", albumArtist)) }
    if let disc { tags.append(("DISCNUMBER", "\(disc)")) }
    if let year { tags.append(("DATE", "\(year)-01-01")) }
    return tags
}

@Test func importsGroupsAndOrdersAlbums() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    let urls = [
        try temp.picked(
            "s24-96000", as: "02.flac",
            tags: tags(title: "Second", artist: "Alpha", album: "First Light", number: 2, year: 1999)),
        try temp.picked(
            "s16-44100", as: "01.flac",
            tags: tags(title: "First", artist: "Alpha", album: "First Light", number: 1, year: 1998)),
        try temp.picked("s24-48000", as: "B1.flac", tags: tags(title: "Bee", artist: "Beta", album: "Beta Max")),
        // The disguised MP3, as it is: TaggedFlac only rewrites real FLAC.
        Fixtures.url(Fixtures.named("renamed-mp3")),
    ]

    let result = await library.importFiles(urls)

    #expect(result.added.count == 3)
    #expect(result.rejected.map(\.reason) == [.badMagic])
    let catalog = library.current
    #expect(catalog.albums.map(\.title) == ["First Light", "Beta Max"])
    let first = try #require(catalog.albums.first)
    #expect(first.artist == "Alpha" && first.year == 1998)
    #expect(catalog.tracks(of: first.id).map(\.title) == ["First", "Second"])
    #expect(first.bestFormat == AudioFormat(sampleRate: 96_000, bitsPerSample: 24, channels: 2))
    #expect(first.formatLabel == "FLAC 24/96")
    let track = try #require(catalog.tracks(of: first.id).last)
    #expect(track.format.sampleRate == 96_000 && track.totalFrames == 4096)
    #expect(track.url.deletingLastPathComponent().lastPathComponent == "Library")
    #expect(FileManager.default.fileExists(atPath: track.url.path))
}

@Test func rescanReadsOnlyWhatChanged() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    let a = temp.libraryFolder.appending(path: "a.flac")
    let b = temp.libraryFolder.appending(path: "b.flac")
    try TaggedFlac.write("s16-44100", to: a, tags: tags(title: "A", artist: "X", album: "Y"))
    try TaggedFlac.write("s24-48000", to: b, tags: tags(title: "B", artist: "X", album: "Y"))

    let first = await library.rescan()
    #expect(first.added.count == 2)
    #expect(await library.probeCount() == 2)

    let second = await library.rescan()
    #expect(second.added.isEmpty && second.updated.isEmpty && second.unchanged == 2)
    #expect(await library.probeCount() == 2)

    // A tag edit: same audio, so the same track, read again.
    let idBefore = try #require(library.current.tracks.values.first { $0.title == "A" }?.id)
    try TaggedFlac.write("s16-44100", to: a, tags: tags(title: "A (Remastered)", artist: "X", album: "Y"))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: a.path)
    let third = await library.rescan()
    #expect(third.updated == [idBefore] && third.unchanged == 1)
    #expect(await library.probeCount() == 3)
    #expect(library.current.tracks[idBefore]?.title == "A (Remastered)")
}

@Test func deletedFilesLeaveAndMovedFilesKeepTheirID() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    let a = temp.libraryFolder.appending(path: "a.flac")
    let b = temp.libraryFolder.appending(path: "b.flac")
    try TaggedFlac.write("s16-44100", to: a, tags: tags(title: "A", artist: "X", album: "Y"))
    try TaggedFlac.write("s24-48000", to: b, tags: tags(title: "B", artist: "X", album: "Y"))
    await library.rescan()
    let idA = try #require(library.current.tracks.values.first { $0.title == "A" }?.id)
    let idB = try #require(library.current.tracks.values.first { $0.title == "B" }?.id)

    let moved = temp.libraryFolder.appending(path: "Sub/renamed.flac")
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: a, to: moved)
    try FileManager.default.removeItem(at: b)
    let report = await library.rescan()

    #expect(report.moved == [idA])
    #expect(report.removed == [idB])
    #expect(library.current.tracks.keys.sorted() == [idA])
    #expect(library.current.tracks[idA]?.url.lastPathComponent == "renamed.flac")
}

@Test func refusedFilesAreRememberedNotReread() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    try FileManager.default.createDirectory(at: temp.libraryFolder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: Fixtures.url(Fixtures.named("renamed-mp3")), to: temp.libraryFolder.appending(path: "fake.flac"))
    try FileManager.default.copyItem(
        at: Fixtures.url(Fixtures.named("truncated-meta")), to: temp.libraryFolder.appending(path: "cut.flac"))
    try Data("x".utf8).write(to: temp.libraryFolder.appending(path: "._AppleDouble.flac"))
    try Data("x".utf8).write(to: temp.libraryFolder.appending(path: "notes.txt"))

    let first = await library.rescan()
    #expect(first.rejected == ["fake.flac": "Not a FLAC file", "cut.flac": "Damaged or incomplete FLAC"])
    #expect(library.current.tracks.isEmpty)
    let probes = await library.probeCount()

    let second = await library.rescan()
    #expect(second.rejected.isEmpty && second.unchanged == 2)
    #expect(await library.probeCount() == probes)

    try FileManager.default.removeItem(at: temp.libraryFolder.appending(path: "fake.flac"))
    try TaggedFlac.write("s16-44100", to: temp.libraryFolder.appending(path: "fake.flac"), tags: [("TITLE", "Fixed")])
    let third = await library.rescan()
    #expect(third.added.count == 1)
    #expect(library.current.tracks.values.map(\.title) == ["Fixed"])
}

@Test func libraryPersistsAcrossLaunches() async throws {
    let temp = try TemporaryLibraryRoot()
    do {
        let library = try temp.open()
        let url = try temp.picked("s24-96000", as: "keep.flac", tags: tags(title: "Kept", artist: "Z", album: "Saved"))
        _ = await library.importFiles([url])
        #expect(library.current.tracks.count == 1)
    }
    // A new launch: the database answers before any scan.
    let reopened = try temp.open()
    #expect(reopened.current.tracks.values.map(\.title) == ["Kept"])
    #expect(reopened.current.albums.map(\.title) == ["Saved"])
    let report = await reopened.rescan()
    #expect(report.unchanged == 1 && report.added.isEmpty)
}

@Test func albumArtistCompilationAndUntaggedGrouping() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    let folder = temp.libraryFolder
    // Tagged compilation: one album despite two artists.
    try TaggedFlac.write(
        "s16-44100", to: folder.appending(path: "c1.flac"),
        tags: tags(title: "One", artist: "P", album: "Hits", number: 1, albumArtist: "Various Artists"))
    try TaggedFlac.write(
        "s16-48000", to: folder.appending(path: "c2.flac"),
        tags: tags(title: "Two", artist: "Q", album: "Hits", number: 2, albumArtist: "Various Artists"))
    // COMPILATION=1 without ALBUMARTIST: one album too.
    try TaggedFlac.write(
        "s24-44100", to: folder.appending(path: "k1.flac"),
        tags: tags(title: "K1", artist: "R", album: "Mix") + [("COMPILATION", "1")])
    try TaggedFlac.write(
        "s24-48000", to: folder.appending(path: "k2.flac"),
        tags: tags(title: "K2", artist: "S", album: "Mix") + [("COMPILATION", "1")])
    // Same title, different artists, no album artist: two albums.
    try TaggedFlac.write(
        "s24-88200", to: folder.appending(path: "g1.flac"), tags: tags(title: "G1", artist: "T", album: "Greatest"))
    try TaggedFlac.write(
        "s24-96000", to: folder.appending(path: "g2.flac"), tags: tags(title: "G2", artist: "U", album: "Greatest"))
    // Multi-disc in two folders.
    try TaggedFlac.write(
        "s24-176400", to: folder.appending(path: "Box/CD2/a.flac"),
        tags: tags(title: "D2", artist: "V", album: "Box", number: 1, disc: 2))
    try TaggedFlac.write(
        "s24-192000", to: folder.appending(path: "Box/CD1/a.flac"),
        tags: tags(title: "D1", artist: "V", album: "Box", number: 1, disc: 1))
    // Untagged files: titled from the file name, one album per folder.
    try TaggedFlac.write("s32-44100", to: folder.appending(path: "Loose/Untitled one.flac"), tags: [])
    try TaggedFlac.write("s32-48000", to: folder.appending(path: "Loose/Untitled two.flac"), tags: [])

    await library.rescan()
    let catalog = library.current
    func album(_ title: String) -> [LibraryAlbum] { catalog.albums.filter { $0.title == title } }

    #expect(album("Hits").count == 1 && album("Hits").first?.artist == "Various Artists")
    #expect(album("Mix").count == 1 && album("Mix").first?.artist == "Various Artists")
    #expect(album("Greatest").count == 2)
    let box = try #require(album("Box").first)
    #expect(catalog.tracks(of: box.id).map(\.title) == ["D1", "D2"])
    #expect(box.bestFormat.sampleRate == 192_000)
    let loose = try #require(album(AlbumGrouping.unknownAlbum).first)
    #expect(loose.artist == AlbumGrouping.unknownArtist)
    #expect(catalog.tracks(of: loose.id).map(\.title) == ["Untitled one", "Untitled two"])
    #expect(loose.bestFormat.bitsPerSample == 32)
}

/// Spec §5.8: tags are untrusted. Huge, empty-keyed, control-character, non-ASCII and malformed comment bodies all
/// import without harm, cleaned and capped.
@Test func hostileTagsAreCleanedAndBounded() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    let folder = temp.libraryFolder
    let huge = String(repeating: "Ä", count: 1_000_000)
    try TaggedFlac.write(
        "s16-44100", to: folder.appending(path: "huge.flac"),
        tags: [("TITLE", huge), ("ARTIST", "  Björk\u{0}\u{7}\n\tGuðmundsdóttir  "), ("ALBUM", "\u{FEFF}Homogenic")])
    try TaggedFlac.write(
        "s16-48000", to: folder.appending(path: "empty.flac"),
        tags: [
            ("", "no key"), ("=", "x"), ("TITLE", ""), ("ARTIST", "   "), ("ALBUM", "日本語のアルバム"),
            ("TRACKNUMBER", "99999999999999999999"), ("DATE", "abcd"),
        ])
    try TaggedFlac.write(
        "s24-44100", to: folder.appending(path: "keys.flac"),
        tags: [("título", "x"), ("Title", "Mixed Case Key"), ("ÄRTIST", "y")])
    // A comment that claims a million entries but holds one, and one whose vendor length overruns the block.
    var overrun = TaggedFlac.le32(4) + Array("test".utf8) + TaggedFlac.le32(1_000_000)
    overrun += TaggedFlac.le32(11) + Array("TITLE=Short".utf8)
    try TaggedFlac.write("s24-48000", to: folder.appending(path: "overrun.flac"), rawComment: overrun)
    try TaggedFlac.write(
        "s24-88200", to: folder.appending(path: "vendor.flac"), rawComment: TaggedFlac.le32(0x7FFF_FFFF) + [1, 2, 3])
    // Invalid UTF-8 in a value.
    let badUTF8 =
        TaggedFlac.le32(0) + TaggedFlac.le32(1) + TaggedFlac.le32(9) + Array("TITLE=".utf8) + [0xC3, 0x28, 0xFF]
    try TaggedFlac.write("s24-96000", to: folder.appending(path: "utf8.flac"), rawComment: badUTF8)

    let report = await library.rescan()
    #expect(report.added.count == 6 && report.rejected.isEmpty)
    let byFile = Dictionary(uniqueKeysWithValues: library.current.tracks.values.map { ($0.url.lastPathComponent, $0) })

    let hugeTrack = try #require(byFile["huge.flac"])
    #expect(hugeTrack.title.unicodeScalars.count == 512)
    #expect(hugeTrack.artist == "Björk Guðmundsdóttir")
    #expect(hugeTrack.album == "Homogenic")
    let empty = try #require(byFile["empty.flac"])
    #expect(empty.title == "empty" && empty.artist.isEmpty && empty.album == "日本語のアルバム")
    #expect(empty.trackNumber == nil && empty.year == nil)
    #expect(byFile["keys.flac"]?.title == "Mixed Case Key")
    #expect(byFile["overrun.flac"]?.title == "Short")
    #expect(byFile["vendor.flac"]?.title == "vendor")
    let utf8 = try #require(byFile["utf8.flac"])
    #expect(utf8.title.hasPrefix("\u{FFFD}("))
}

@Test func artworkIsExtractedOnceAndDownsampled() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    let cover = TaggedFlac.png(size: 1_200)
    let folder = temp.libraryFolder
    try TaggedFlac.write(
        "s16-44100", to: folder.appending(path: "1.flac"), tags: tags(title: "1", artist: "A", album: "Art", number: 1),
        picture: cover)
    try TaggedFlac.write(
        "s16-48000", to: folder.appending(path: "2.flac"), tags: tags(title: "2", artist: "A", album: "Art", number: 2),
        picture: cover)
    try TaggedFlac.write(
        "s24-44100", to: folder.appending(path: "3.flac"), tags: tags(title: "3", artist: "B", album: "Junk"),
        picture: Data("not an image".utf8))

    await library.rescan()
    let catalog = library.current
    let art = try #require(catalog.albums.first { $0.title == "Art" })
    let artworkID = try #require(art.artworkID)
    #expect(catalog.tracks(of: art.id).allSatisfy { $0.artworkID == artworkID })
    #expect(catalog.albums.first { $0.title == "Junk" }?.artworkID == nil)
    let stored = try FileManager.default.contentsOfDirectory(atPath: temp.artwork.path)
    #expect(stored == ["\(artworkID).jpg"])
    let data = try #require(library.artwork(artworkID))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == ArtworkStore.sleevePixels)
    #expect(library.artwork("../../etc/passwd") == nil)
    #expect(library.artwork(nil) == nil)

    // The covered tracks leave: their cover goes too.
    for name in ["1.flac", "2.flac"] { try FileManager.default.removeItem(at: folder.appending(path: name)) }
    await library.rescan()
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.artwork.path).isEmpty)
}

@Test func foldersAddedInPlaceAreReadWhereTheyAre() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    let external = temp.root.appending(path: "External Music", directoryHint: .isDirectory)
    try TaggedFlac.write(
        "s24-96000", to: external.appending(path: "Artist/Album/01.flac"),
        tags: tags(title: "In Place", artist: "E", album: "Ext"))
    try FileManager.default.createDirectory(at: external.appending(path: ".hidden"), withIntermediateDirectories: true)
    try TaggedFlac.write(
        "s16-44100", to: external.appending(path: ".hidden/secret.flac"),
        tags: tags(title: "Hidden", artist: "E", album: "Ext"))
    // The same rip in the library folder too: both stay, with different IDs.
    try TaggedFlac.write(
        "s24-96000", to: temp.libraryFolder.appending(path: "copy.flac"),
        tags: tags(title: "Copy", artist: "E", album: "Ext"))
    await library.rescan()

    let report = try await library.addFolder(external)
    #expect(report.added.count == 1)
    #expect(await library.folders().map(\.name) == ["Library", "External Music"])
    let tracks = library.current.tracks.values.sorted { $0.title < $1.title }
    #expect(tracks.map(\.title) == ["Copy", "In Place"])
    #expect(Set(tracks.map(\.id)).count == 2)
    #expect(tracks[1].url.path.hasSuffix("External Music/Artist/Album/01.flac"))
    #expect(FileManager.default.fileExists(atPath: tracks[1].url.path))

    // Adding it again changes nothing; removing it forgets its tracks but never touches the files.
    _ = try await library.addFolder(external)
    #expect(await library.folders().count == 2)
    let id = try #require(await library.folders().last?.id)
    try await library.removeFolder(id)
    #expect(library.current.tracks.values.map(\.title) == ["Copy"])
    #expect(FileManager.default.fileExists(atPath: external.appending(path: "Artist/Album/01.flac").path))
}

@Test func changesStreamPublishesEachCatalog() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try temp.open()
    var iterator = library.changes().makeAsyncIterator()
    #expect(await iterator.next()?.tracks.isEmpty == true)
    let url = try temp.picked("s16-44100", as: "x.flac", tags: tags(title: "Streamed", artist: "S", album: "T"))
    _ = await library.importFiles([url])
    #expect(await iterator.next()?.tracks.values.map(\.title) == ["Streamed"])
}

@Test func oversizedFilesAreRefused() async throws {
    let temp = try TemporaryLibraryRoot()
    let library = try Library(
        databaseURL: temp.database, libraryFolder: temp.libraryFolder, artworkFolder: temp.artwork, maxFileBytes: 1_000)
    let url = try temp.picked("s16-44100", as: "big.flac", tags: tags(title: "Big", artist: "B", album: "C"))
    let result = await library.importFiles([url])
    #expect(result.added.isEmpty)
    #expect(result.rejected.map(\.exceedsSizeLimit) == [true])
    #expect(result.rejected.first?.message == "Too large to add")

    try TaggedFlac.write("s16-44100", to: temp.libraryFolder.appending(path: "placed.flac"), tags: [])
    let report = await library.rescan()
    #expect(report.rejected == ["placed.flac": "Too large to add"])
    #expect(library.current.tracks.isEmpty)
}

@Test func contentIdentityIgnoresTagsAndNames() throws {
    let temp = try TemporaryLibraryRoot()
    let a = temp.root.appending(path: "a.flac")
    let b = temp.root.appending(path: "other name.flac")
    let c = temp.root.appending(path: "c.flac")
    try TaggedFlac.write("s16-44100", to: a, tags: [("TITLE", "One")])
    try TaggedFlac.write(
        "s16-44100", to: b, tags: [("TITLE", "Two"), ("ARTIST", String(repeating: "x", count: 5_000))])
    try TaggedFlac.write("s16-48000", to: c, tags: [("TITLE", "One")])
    let idA = try #require(ContentIdentity.compute(fileAt: a))
    #expect(idA.count == 32)
    #expect(ContentIdentity.compute(fileAt: b) == idA)
    #expect(ContentIdentity.compute(fileAt: c) != idA)
    // An ID3v2 prefix (the validator allows one) is skipped.
    #expect(ContentIdentity.compute(fileAt: Fixtures.url(Fixtures.named("id3-s24-48000"))) != nil)
    #expect(ContentIdentity.compute(fileAt: Fixtures.url(Fixtures.named("renamed-mp3"))) == nil)
}

@Test func coverProbeReadsAtMostTheFrontCover() throws {
    let temp = try TemporaryLibraryRoot()
    let url = temp.root.appending(path: "pics.flac")
    let front = TaggedFlac.png(size: 16, red: 0.1)
    // Back cover (type 0 here) first, then the front: the front wins.
    var data = try TaggedFlac.make(from: "s16-44100", tags: [("TITLE", "P")], picture: front, pictureType: 3)
    try data.write(to: url)
    #expect(FlacProbe.cover(fileAt: url) == front)
    data = try TaggedFlac.make(from: "s16-44100", tags: [], picture: front, pictureType: 4, extraPictures: 2)
    try data.write(to: url)
    #expect(FlacProbe.cover(fileAt: url) == front)
    #expect(FlacProbe.parsePicture([0, 0, 0, 3, 0xFF, 0xFF, 0xFF, 0xFF]) == nil)
    #expect(FlacProbe.parsePicture([]) == nil)
}
