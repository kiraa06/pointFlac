import Foundation
import PFCore
import PFTestSupport
import Testing

@testable import PFLibrary

/// Kiran's request: delete downloaded albums and songs. A track in the app's own library folder is the app's copy, so
/// removing it deletes the file; a track in a folder added in place is the user's file, so it only leaves the library,
/// and a rescan must not bring it back until the file changes.
private final class RemovalSandbox {
    let root: URL
    var libraryFolder: URL { root.appending(path: "Documents/Library", directoryHint: .isDirectory) }
    var database: URL { root.appending(path: "Support/library.sqlite") }
    var artwork: URL { root.appending(path: "Support/Artwork", directoryHint: .isDirectory) }
    var outside: URL { root.appending(path: "Picked", directoryHint: .isDirectory) }
    var external: URL { root.appending(path: "External Music", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "LibraryRemoval-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func storedCovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: artwork.path).sorted()
    }
}

@Test func deletesOwnFilesAndRows() async throws {
    let box = try RemovalSandbox()
    let library = try box.open()
    let imported = await library.importFiles([
        try box.picked("s16-44100", as: "keep.flac", tags: [("TITLE", "Keep"), ("ALBUM", "Pair")]),
        try box.picked("s24-48000", as: "gone.flac", tags: [("TITLE", "Gone"), ("ALBUM", "Pair")]),
    ])
    #expect(imported.added.count == 2)
    let gone = try #require(library.current.tracks.values.first { $0.title == "Gone" })
    #expect(gone.isInLibraryFolder)
    var changes = library.changes().makeAsyncIterator()
    #expect(await changes.next()?.tracks.count == 2)

    // An unknown ID (a track removed meanwhile) is ignored.
    let removal = try await library.remove(trackIDs: [gone.id, "no-such-track"])

    #expect(removal == LibraryRemoval(deletedFiles: 1, removedFromLibrary: 0))
    #expect(removal.deletedFiles == 1)
    #expect(!box.exists(gone.url))
    #expect(library.current.tracks.values.map(\.title) == ["Keep"])
    // Subscribers see the new catalog, as after any other change.
    #expect(await changes.next()?.tracks.values.map(\.title) == ["Keep"])
    // The library folder itself stays, with the other file in it.
    #expect(box.exists(box.libraryFolder.appending(path: "keep.flac")))
    let rescan = await library.rescan()
    #expect(rescan.added.isEmpty && rescan.removed.isEmpty)
    #expect(library.current.tracks.count == 1)
}

@Test func externalTracksStayOnDisk() async throws {
    let box = try RemovalSandbox()
    let library = try box.open()
    let file = box.external.appending(path: "Artist/Album/01.flac")
    try TaggedFlac.write("s24-96000", to: file, tags: [("TITLE", "In Place"), ("ALBUM", "Ext")])
    _ = try await library.addFolder(box.external)
    let track = try #require(library.current.tracks.values.first)
    #expect(!track.isInLibraryFolder)

    let removal = try await library.remove(trackIDs: [track.id])

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 1))
    #expect(box.exists(file))
    #expect(library.current.tracks.isEmpty)
    // A rescan skips the removed file without reading it, as it skips a refused one.
    let probes = await library.probeCount()
    let rescan = await library.rescan()
    #expect(rescan.added.isEmpty && rescan.unchanged == 1)
    #expect(await library.probeCount() == probes)
    #expect(library.current.tracks[track.id] == nil)
    #expect(box.exists(file))

    // The file changed since it was removed (its date moved): the next scan reads it again, and it is back.
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
    let back = await library.rescan()
    #expect(back.added == [track.id])
    #expect(library.current.tracks[track.id]?.title == "In Place")
}

/// An album split between the library folder and a folder added in place: the app's copies are deleted, the user's
/// file only leaves the library, and the album is gone from the shelf.
@Test func removingAnAlbumRemovesEveryTrack() async throws {
    let box = try RemovalSandbox()
    let library = try box.open()
    let whole = [("ALBUM", "Whole"), ("ALBUMARTIST", "W")]
    let first = box.libraryFolder.appending(path: "W/Whole/01.flac")
    let second = box.libraryFolder.appending(path: "W/Whole/02.flac")
    let third = box.external.appending(path: "03.flac")
    try TaggedFlac.write("s16-44100", to: first, tags: [("TITLE", "One"), ("TRACKNUMBER", "1")] + whole)
    try TaggedFlac.write("s24-48000", to: second, tags: [("TITLE", "Two"), ("TRACKNUMBER", "2")] + whole)
    try TaggedFlac.write("s24-96000", to: third, tags: [("TITLE", "Three"), ("TRACKNUMBER", "3")] + whole)
    let other = box.libraryFolder.appending(path: "other.flac")
    try TaggedFlac.write("s32-48000", to: other, tags: [("TITLE", "Else"), ("ALBUM", "Other")])
    await library.rescan()
    _ = try await library.addFolder(box.external)
    let album = try #require(library.current.albums.first { $0.title == "Whole" })
    #expect(album.trackIDs.count == 3)

    let removal = try await library.remove(trackIDs: album.trackIDs)

    #expect(removal == LibraryRemoval(deletedFiles: 2, removedFromLibrary: 1))
    #expect(library.current.albums.map(\.title) == ["Other"])
    #expect(!box.exists(first) && !box.exists(second))
    #expect(box.exists(third) && box.exists(other))
    // The folders the deletion emptied go too, up to the library folder, which stays.
    #expect(!box.exists(box.libraryFolder.appending(path: "W")))
    #expect(box.exists(box.libraryFolder))
    await library.rescan()
    #expect(library.current.albums.map(\.title) == ["Other"])
}

/// A folder the deletion leaves non-empty stays, and nothing outside the library folder is ever touched.
@Test func onlyEmptiedFoldersInsideTheLibraryFolderGo() async throws {
    let box = try RemovalSandbox()
    let library = try box.open()
    let lone = box.libraryFolder.appending(path: "Solo/lone.flac")
    let shared = box.libraryFolder.appending(path: "Shared/a.flac")
    let neighbour = box.libraryFolder.appending(path: "Shared/notes.txt")
    try TaggedFlac.write("s16-44100", to: lone, tags: [("TITLE", "Lone")])
    try TaggedFlac.write("s24-48000", to: shared, tags: [("TITLE", "Shared")])
    try Data("liner notes".utf8).write(to: neighbour)
    await library.rescan()
    let ids = library.current.tracks.values.map(\.id)

    let removal = try await library.remove(trackIDs: ids)

    #expect(removal == LibraryRemoval(deletedFiles: 2, removedFromLibrary: 0))
    #expect(!box.exists(box.libraryFolder.appending(path: "Solo")))
    #expect(box.exists(neighbour))
    #expect(box.exists(box.libraryFolder))
    #expect(box.exists(box.root.appending(path: "Documents")))
}

/// The safety rule, below the scanner: a library-folder row whose path leads out of the library folder (which no scan
/// writes, but a damaged database might hold) never deletes what it points at, and keeps its track.
@Test func aPathLeadingOutOfTheLibraryFolderIsNeverDeleted() throws {
    let box = try RemovalSandbox()
    let store = try LibraryStore(
        databaseURL: box.database, libraryFolder: box.libraryFolder, artworkFolder: box.artwork, maxFileBytes: 1 << 30)
    try FileManager.default.createDirectory(at: box.libraryFolder, withIntermediateDirectories: true)
    let precious = box.root.appending(path: "Documents/precious.flac")
    try TaggedFlac.write("s16-44100", to: precious, tags: [("TITLE", "Precious")])
    try store.database.query(
        """
        INSERT INTO tracks(id, folder_id, rel_path, size, mtime, content_id, title, artist, album_artist, album,
            sample_rate, bits, channels, total_frames, album_id, added_at)
        VALUES ('escape', 1, '../precious.flac', 1, 1, 'c', 'Escape', '', '', '', 44100, 16, 2, 0, 'a', 0)
        """)

    let removal = try store.remove(trackIDs: ["escape"])

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 0))
    #expect(box.exists(precious))
    #expect(try store.trackID(folder: LibraryStore.libraryFolderID, relativePath: "../precious.flac") == "escape")
    #expect(box.exists(box.root.appending(path: "Documents")))
}

/// A file deleted in the Files app before any rescan: its track still leaves, and counts as deleted.
@Test func aFileAlreadyGoneStillLeaves() async throws {
    let box = try RemovalSandbox()
    let library = try box.open()
    let file = box.libraryFolder.appending(path: "Album/gone.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Gone")])
    await library.rescan()
    let id = try #require(library.current.tracks.keys.first)
    try FileManager.default.removeItem(at: file)

    let removal = try await library.remove(trackIDs: [id])

    #expect(removal == LibraryRemoval(deletedFiles: 1, removedFromLibrary: 0))
    #expect(library.current.tracks.isEmpty)
    #expect(!box.exists(box.libraryFolder.appending(path: "Album")))
}

@Test func orphanedArtworkIsCleaned() async throws {
    let box = try RemovalSandbox()
    let library = try box.open()
    let cover = TaggedFlac.png(size: 32, red: 0.8)
    let otherCover = TaggedFlac.png(size: 32, red: 0.1)
    let folder = box.libraryFolder
    try TaggedFlac.write(
        "s16-44100", to: folder.appending(path: "1.flac"), tags: [("TITLE", "1"), ("ALBUM", "Art")], picture: cover)
    try TaggedFlac.write(
        "s16-48000", to: folder.appending(path: "2.flac"), tags: [("TITLE", "2"), ("ALBUM", "Art")], picture: cover)
    try TaggedFlac.write(
        "s24-44100", to: folder.appending(path: "3.flac"), tags: [("TITLE", "3"), ("ALBUM", "Kept")],
        picture: otherCover)
    await library.rescan()
    let art = try #require(library.current.albums.first { $0.title == "Art" })
    let artID = try #require(art.artworkID)
    let keptID = try #require(library.current.albums.first { $0.title == "Kept" }?.artworkID)
    #expect(try box.storedCovers() == ["\(artID).jpg", "\(keptID).jpg"].sorted())

    // One of the album's tracks goes: the other still uses the cover, so it stays.
    _ = try await library.remove(trackIDs: [art.trackIDs[0]])
    #expect(try box.storedCovers() == ["\(artID).jpg", "\(keptID).jpg"].sorted())
    #expect(library.artwork(artID) != nil)

    // The last one goes: so does its cover, file and row; the other album's cover is untouched.
    _ = try await library.remove(trackIDs: [art.trackIDs[1]])
    #expect(try box.storedCovers() == ["\(keptID).jpg"])
    #expect(library.artwork(artID) == nil)
    #expect(library.artwork(keptID) != nil)
}
