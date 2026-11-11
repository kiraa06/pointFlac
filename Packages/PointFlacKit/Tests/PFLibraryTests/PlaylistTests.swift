import Foundation
import PFCore
import PFTestSupport
import Testing

@testable import PFLibrary

/// Plan 11, Task A: Favourites and named playlists, stored in the library (spec "Playlists as custom pressings" §5).
/// Track IDs are soft references: a song the user deletes leaves every playlist, but a song whose file is only gone for
/// now stays in its playlists, and is back when its file returns. Playlist edits never touch files or the catalog.
private final class PlaylistSandbox {
    let root: URL
    var libraryFolder: URL { root.appending(path: "Documents/Library", directoryHint: .isDirectory) }
    var database: URL { root.appending(path: "Support/library.sqlite") }
    var artwork: URL { root.appending(path: "Support/Artwork", directoryHint: .isDirectory) }
    var outside: URL { root.appending(path: "Picked", directoryHint: .isDirectory) }
    /// The folder picked for downloads, read in place.
    var downloads: URL { root.appending(path: "iCloud Drive/pointFlac", directoryHint: .isDirectory) }
    /// Another folder read in place.
    var external: URL { root.appending(path: "On My iPhone/Music", directoryHint: .isDirectory) }
    /// Where the injected trash puts what it is given, standing in for Recently Deleted.
    var bin: URL { root.appending(path: "Recently Deleted", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "Playlists-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func open() throws -> Library {
        try Library(databaseURL: database, libraryFolder: libraryFolder, artworkFolder: artwork)
    }

    /// A tagged copy of `fixture` outside the library, as the document picker would hand it over.
    func picked(_ fixture: String, as name: String, title: String) throws -> URL {
        let url = outside.appending(path: UUID().uuidString).appending(path: name)
        try TaggedFlac.write(fixture, to: url, tags: [("TITLE", title), ("ALBUM", "Mix")])
        return url
    }

    /// The download folder's rule, with a move that puts the file in `bin`, or fails for the names in `failing`.
    func trash(failing: Set<String> = []) -> TrashFolder {
        let bin = bin
        return TrashFolder(downloads) { file in
            if failing.contains(file.lastPathComponent) { throw CocoaError(.featureUnsupported) }
            let target = bin.appending(path: file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: target)
            return target
        }
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Whole seconds, because the database stores `Date` as a REAL and a round trip must compare equal.
private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

/// Makes the library's playlist writes take `seconds` as now.
private func setClock(_ library: Library, to seconds: Double) async throws {
    try await library.run(.never) { store in store.clock = { at(seconds) } }
}

/// The stored track IDs of playlist `id`, in order, or nil when there is no such playlist.
private func songs(_ library: Library, _ id: String) async -> [String]? {
    await library.playlists().first { $0.id == id }?.trackIDs
}

/// How many `playlist_tracks` rows the database holds for `playlistID`.
private func storedRows(_ library: Library, _ playlistID: String) async throws -> Int {
    let rows = try await library.run(.never) {
        try $0.database.query("SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?", [.text(playlistID)])
    }
    return Int(rows.first?.first?.int ?? -1)
}

// MARK: Favourites and the schema

@Test func aNewLibraryHasFavouritesAndNothingElse() async throws {
    let box = try PlaylistSandbox()
    var library: Library? = try box.open()

    let playlists = await library?.playlists() ?? []
    #expect(playlists.count == 1)
    let favourites = try #require(playlists.first)
    #expect(Playlist.favouritesID == "favourites")
    #expect(favourites.id == Playlist.favouritesID)
    #expect(favourites.name == "Favourites")
    #expect(favourites.kind == .favourites)
    #expect(favourites.colourID == "ruby")
    #expect(favourites.trackIDs.isEmpty)

    // Seeded once, by the migration: opening the library again adds no second one.
    await library?.barrier()
    library = nil
    let reopened = try box.open()
    #expect(await reopened.playlists() == playlists)
}

@Test func aVersion5DatabaseMigratesWithNoDataLoss() throws {
    let box = try PlaylistSandbox()
    try FileManager.default.createDirectory(
        at: box.database.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = try SQLiteDatabase(url: box.database)
    try old.migrate(Array(LibraryStore.migrations.prefix(5)))
    try old.query("INSERT INTO folders(id, kind, name, added_at) VALUES (1, 'library', 'Library', 0)")
    try old.query(
        """
        INSERT INTO tracks(id, folder_id, rel_path, size, mtime, content_id, title, artist, album_artist, album,
            sample_rate, bits, channels, total_frames, album_id, added_at, r128_state, r128_lufs)
        VALUES ('kept', 1, 'kept.flac', 1, 1, 'c', 'Kept', 'Ada', '', 'Album', 44100, 16, 2, 0, 'a', 42, 1, -14.5)
        """)
    try old.query("INSERT INTO listens(track_id, count, last_at) VALUES ('kept', 3, 99)")
    try old.query("INSERT INTO removed(folder_id, rel_path, size, mtime) VALUES (1, 'other.flac', 7, 8)")
    #expect(old.userVersion == 5)

    let store = try LibraryStore(
        databaseURL: box.database, libraryFolder: box.libraryFolder, artworkFolder: box.artwork, maxFileBytes: 1 << 30)

    #expect(LibraryStore.migrations.count == 6)
    #expect(store.database.userVersion == 6)
    // Everything the old database held is still there.
    #expect(
        try store.database.query("SELECT id, title, artist, added_at, r128_state, r128_lufs FROM tracks")
            == [[.text("kept"), .text("Kept"), .text("Ada"), .real(42), .integer(1), .real(-14.5)]])
    #expect(try store.listenStats() == ["kept": ListenStat(count: 3, lastAt: at(99))])
    #expect(try store.database.query("SELECT rel_path FROM removed") == [[.text("other.flac")]])
    // The new tables are the spec's, and Favourites is seeded.
    let columns = { (table: String) in
        try store.database.query("SELECT name FROM pragma_table_info(?) ORDER BY cid", [.text(table)])
            .compactMap { $0[0].string }
    }
    #expect(try columns("playlists") == ["id", "name", "kind", "colour", "created_at"])
    #expect(try columns("playlist_tracks") == ["playlist_id", "track_id", "position", "added_at"])
    let playlists = try store.playlists()
    #expect(playlists.map(\.id) == [Playlist.favouritesID])
    #expect(playlists.first?.name == "Favourites")
    #expect(playlists.first?.colourID == "ruby")
    // And they work with the tracks the old database had.
    #expect(try store.addTracks(["kept"], to: Playlist.favouritesID) == 1)
    #expect(try store.playlists().first?.trackIDs == ["kept"])
}

// MARK: Creating, renaming, recolouring, deleting

@Test func aNewPlaylistIsStoredWithItsNameTrimmed() async throws {
    let box = try PlaylistSandbox()
    var library: Library? = try box.open()

    let made = try #require(try await library?.createPlaylist(name: "  Late Night \n", colourID: "ocean"))

    #expect(made.name == "Late Night")
    #expect(made.kind == .custom)
    #expect(made.colourID == "ocean")
    #expect(made.trackIDs.isEmpty)
    #expect(UUID(uuidString: made.id) != nil)
    #expect(made.id == made.id.lowercased())
    let listed = await library?.playlists() ?? []
    #expect(listed.map(\.id) == [Playlist.favouritesID, made.id])
    #expect(listed.last == made)

    // Kept across launches.
    await library?.barrier()
    library = nil
    #expect(try await box.open().playlists() == listed)
}

@Test func namesAreTrimmedAndOneToSixtyCharacters() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()

    // Invisible characters alone (zero-width space, byte-order mark, joiner) would make a blank-looking name.
    let invisible = ["\u{200B}", "\u{FEFF}\u{200B}", " \u{200D} "]
    for bad in ["", "   ", "\n\t ", String(repeating: "x", count: 61), "  " + String(repeating: "é", count: 61) + " "]
        + invisible
    {
        await #expect(throws: PlaylistError.invalidName) {
            _ = try await library.createPlaylist(name: bad, colourID: "jade")
        }
    }
    #expect(await library.playlists().count == 1, "a refused create stores nothing")

    let sixty = String(repeating: "x", count: 60)
    let longest = try await library.createPlaylist(name: "  \(sixty)  ", colourID: "jade")
    #expect(longest.name == sixty)
    // Characters, not bytes: sixty emoji are a valid name.
    let emoji = try await library.createPlaylist(name: String(repeating: "👍🏽", count: 60), colourID: "jade")
    #expect(emoji.name.count == 60)
    let short = try await library.createPlaylist(name: "a", colourID: "jade")
    // Duplicate names are allowed.
    let twin = try await library.createPlaylist(name: " a ", colourID: "onyx")
    #expect(twin.name == "a" && twin.id != short.id)
    #expect(await library.playlists().count == 5)

    // Renaming follows the same rule, and a refused rename changes nothing.
    for bad in ["", "  ", String(repeating: "y", count: 61)] {
        await #expect(throws: PlaylistError.invalidName) { try await library.renamePlaylist(id: short.id, name: bad) }
    }
    #expect(await library.playlists().first { $0.id == short.id }?.name == "a")
}

@Test func playlistsCanBeRenamedAndRecoloured() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    let made = try await library.createPlaylist(name: "Old", colourID: "amber")

    try await library.renamePlaylist(id: made.id, name: "  New  ")
    try await library.setPlaylistColour(id: made.id, colourID: "violet")

    let updated = try #require(await library.playlists().first { $0.id == made.id })
    #expect(updated.name == "New")
    #expect(updated.colourID == "violet")
    #expect(updated.createdAt == made.createdAt)
    #expect(updated.kind == .custom)
    // Favourites keeps its name, but its colour is only a default.
    try await library.setPlaylistColour(id: Playlist.favouritesID, colourID: "smoke")
    #expect(await library.playlists().first?.colourID == "smoke")
    #expect(await library.playlists().first?.name == "Favourites")

    await #expect(throws: PlaylistError.notFound) { try await library.renamePlaylist(id: "nope", name: "x") }
    await #expect(throws: PlaylistError.notFound) { try await library.setPlaylistColour(id: "nope", colourID: "ruby") }
    // A colour must name something; what it names is the app's business.
    await #expect(throws: PlaylistError.invalidColour) {
        try await library.setPlaylistColour(id: made.id, colourID: "")
    }
    await #expect(throws: PlaylistError.invalidColour) { _ = try await library.createPlaylist(name: "x", colourID: "") }
    #expect(await library.playlists().map(\.id) == [Playlist.favouritesID, made.id])
    #expect(await library.playlists().last?.colourID == "violet")
}

@Test func deletingAPlaylistTakesItsSongsWithIt() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    try await setClock(library, to: 100)
    let doomed = try await library.createPlaylist(name: "Doomed", colourID: "onyx")
    try await setClock(library, to: 200)
    let other = try await library.createPlaylist(name: "Other", colourID: "jade")
    _ = try await library.addTracks(["a", "b"], to: doomed.id)
    _ = try await library.addTracks(["a"], to: other.id)
    _ = try await library.addTracks(["b"], to: Playlist.favouritesID)

    try await library.deletePlaylist(id: doomed.id)

    #expect(await library.playlists().map(\.id) == [Playlist.favouritesID, other.id])
    #expect(try await storedRows(library, doomed.id) == 0)
    #expect(await songs(library, other.id) == ["a"])
    #expect(await songs(library, Playlist.favouritesID) == ["b"])
    await #expect(throws: PlaylistError.notFound) { try await library.deletePlaylist(id: doomed.id) }
}

@Test func favouritesCanNeitherBeRenamedNorDeleted() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    _ = try await library.addTracks(["a"], to: Playlist.favouritesID)

    // By any path: a fine name, an empty one, a duplicate, one too long.
    for name in ["Faves", "", "   ", "Favourites", String(repeating: "x", count: 61)] {
        await #expect(throws: PlaylistError.favouritesIsFixed) {
            try await library.renamePlaylist(id: Playlist.favouritesID, name: name)
        }
    }
    await #expect(throws: PlaylistError.favouritesIsFixed) {
        try await library.deletePlaylist(id: Playlist.favouritesID)
    }

    // A playlist named like it is just another playlist.
    let twin = try await library.createPlaylist(name: "Favourites", colourID: "ruby")
    #expect(twin.kind == .custom)
    #expect(twin.id != Playlist.favouritesID)
    try await library.deletePlaylist(id: twin.id)

    let playlists = await library.playlists()
    #expect(playlists.count == 1)
    let favourites = try #require(playlists.first)
    #expect(favourites.id == Playlist.favouritesID)
    #expect(favourites.name == "Favourites")
    #expect(favourites.kind == .favourites)
    #expect(favourites.trackIDs == ["a"])
}

@Test func playlistsComeFavouritesFirstThenOldestFirst() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    try await setClock(library, to: 300)
    let late = try await library.createPlaylist(name: "Late", colourID: "amber")
    try await setClock(library, to: 100)
    let early = try await library.createPlaylist(name: "Early", colourID: "amber")
    try await setClock(library, to: 200)
    let tiedA = try await library.createPlaylist(name: "Tied", colourID: "amber")
    let tiedB = try await library.createPlaylist(name: "Tied", colourID: "amber")

    #expect(early.createdAt == at(100))
    // Favourites was made now, long after these, and still comes first. Ties go by ID.
    let order = await library.playlists().map(\.id)
    #expect(order == [Playlist.favouritesID, early.id] + [tiedA.id, tiedB.id].sorted() + [late.id])
}

// MARK: Songs in a playlist

@Test func addingAppendsEachSongOnce() async throws {
    let box = try PlaylistSandbox()
    var library: Library? = try box.open()
    let made = try #require(try await library?.createPlaylist(name: "Mix", colourID: "citrine"))

    #expect(try await library?.addTracks(["a", "b", "a"], to: made.id) == 2)
    #expect(try await library?.addTracks(["b", "c", "c", "d"], to: made.id) == 2)
    #expect(try await library?.addTracks([], to: made.id) == 0)

    // None of these is in the catalog (it is empty): they are stored, and read back, all the same.
    #expect(library?.current.tracks.isEmpty == true)
    #expect(await songs(library!, made.id) == ["a", "b", "c", "d"])
    await #expect(throws: PlaylistError.notFound) { _ = try await library?.addTracks(["a"], to: "nope") }
    await #expect(throws: PlaylistError.notFound) { _ = try await library?.addTracks([], to: "nope") }

    // Each playlist has its own songs.
    #expect(try await library?.addTracks(["d", "a"], to: Playlist.favouritesID) == 2)
    #expect(await songs(library!, Playlist.favouritesID) == ["d", "a"])
    #expect(await songs(library!, made.id) == ["a", "b", "c", "d"])

    // Kept across launches.
    await library?.barrier()
    library = nil
    let reopened = try box.open()
    #expect(await songs(reopened, made.id) == ["a", "b", "c", "d"])
    #expect(await songs(reopened, Playlist.favouritesID) == ["d", "a"])
}

@Test func removingSongsFromAPlaylistKeepsTheRestInOrder() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    let made = try await library.createPlaylist(name: "Mix", colourID: "citrine")
    _ = try await library.addTracks(["a", "b", "c", "d"], to: made.id)
    _ = try await library.addTracks(["b"], to: Playlist.favouritesID)

    // A song not in the playlist is ignored.
    try await library.removeTracks(["b", "d", "zzz"], from: made.id)

    #expect(await songs(library, made.id) == ["a", "c"])
    #expect(await songs(library, Playlist.favouritesID) == ["b"], "other playlists keep it")
    // Added again, a song goes to the end.
    #expect(try await library.addTracks(["b"], to: made.id) == 1)
    #expect(await songs(library, made.id) == ["a", "c", "b"])
    try await library.removeTracks(["b"], from: Playlist.favouritesID)
    #expect(await songs(library, Playlist.favouritesID) == [])
    await #expect(throws: PlaylistError.notFound) { try await library.removeTracks(["a"], from: "nope") }
}

@Test func reorderingRewritesTheOrder() async throws {
    let box = try PlaylistSandbox()
    var library: Library? = try box.open()
    let made = try #require(try await library?.createPlaylist(name: "Mix", colourID: "citrine"))
    _ = try await library?.addTracks(["a", "b", "c"], to: made.id)

    try await library?.reorderPlaylist(id: made.id, trackIDs: ["c", "a", "b"])
    #expect(await songs(library!, made.id) == ["c", "a", "b"])
    // A song added later still goes to the end.
    _ = try await library?.addTracks(["d"], to: made.id)
    #expect(await songs(library!, made.id) == ["c", "a", "b", "d"])

    // Anything but the playlist's own songs, each once, is refused and changes nothing.
    let refused: [[String]] = [
        [], ["c", "a", "b"], ["c", "a", "b", "d", "e"], ["c", "a", "b", "e"], ["c", "a", "b", "b"],
        ["d", "c", "a", "b", "a"],
    ]
    for ids in refused {
        await #expect(throws: PlaylistError.notFound) { try await library?.reorderPlaylist(id: made.id, trackIDs: ids) }
    }
    #expect(await songs(library!, made.id) == ["c", "a", "b", "d"])
    await #expect(throws: PlaylistError.notFound) { try await library?.reorderPlaylist(id: "nope", trackIDs: []) }

    // Favourites reorders the same way, and the order is kept across launches.
    _ = try await library?.addTracks(["x", "y"], to: Playlist.favouritesID)
    try await library?.reorderPlaylist(id: Playlist.favouritesID, trackIDs: ["y", "x"])
    await library?.barrier()
    library = nil
    let reopened = try box.open()
    #expect(await songs(reopened, made.id) == ["c", "a", "b", "d"])
    #expect(await songs(reopened, Playlist.favouritesID) == ["y", "x"])
}

/// Files are sacred: taking a song out of a playlist, or deleting the playlist, never touches the file or the catalog.
@Test func playlistEditsNeverTouchFilesOrTheCatalog() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    _ = await library.importFiles([try box.picked("s16-44100", as: "song.flac", title: "Song")])
    let song = try #require(library.current.tracks.values.first)
    let made = try await library.createPlaylist(name: "Mix", colourID: "amber")
    _ = try await library.addTracks([song.id], to: made.id)
    _ = try await library.addTracks([song.id], to: Playlist.favouritesID)

    try await library.removeTracks([song.id], from: Playlist.favouritesID)
    try await library.deletePlaylist(id: made.id)

    #expect(library.current.tracks[song.id] != nil)
    #expect(box.exists(song.url))
    #expect(await library.rescan().removed.isEmpty)
}

@Test func playlistCallsPublishNoCatalog() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    let before = library.publishCount

    let made = try await library.createPlaylist(name: "Mix", colourID: "amber")
    try await library.renamePlaylist(id: made.id, name: "Mix 2")
    try await library.setPlaylistColour(id: made.id, colourID: "jade")
    _ = try await library.addTracks(["a", "b"], to: made.id)
    try await library.reorderPlaylist(id: made.id, trackIDs: ["b", "a"])
    try await library.removeTracks(["a"], from: made.id)
    _ = await library.playlists()
    try await library.deletePlaylist(id: made.id)
    await #expect(throws: PlaylistError.self) { try await library.deletePlaylist(id: Playlist.favouritesID) }
    await library.barrier()

    #expect(library.publishCount == before)
}

// MARK: Deleting songs from the library

/// Review focus 1: deleting a song removes it from every playlist.
@Test func aSongTheUserDeletesLeavesEveryPlaylist() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    _ = await library.importFiles([
        try box.picked("s16-44100", as: "keep.flac", title: "Keep"),
        try box.picked("s24-48000", as: "gone.flac", title: "Gone"),
    ])
    let keep = try #require(library.current.tracks.values.first { $0.title == "Keep" })
    let gone = try #require(library.current.tracks.values.first { $0.title == "Gone" })
    let mix = try await library.createPlaylist(name: "Mix", colourID: "amber")
    let solo = try await library.createPlaylist(name: "Solo", colourID: "jade")
    _ = try await library.addTracks([gone.id, keep.id], to: Playlist.favouritesID)
    _ = try await library.addTracks([keep.id, gone.id], to: mix.id)
    _ = try await library.addTracks([gone.id], to: solo.id)

    let removal = try await library.remove(trackIDs: [gone.id])

    #expect(removal == LibraryRemoval(deletedFiles: 1, removedFromLibrary: 0))
    #expect(await songs(library, Playlist.favouritesID) == [keep.id])
    #expect(await songs(library, mix.id) == [keep.id])
    #expect(await songs(library, solo.id) == [], "the playlist stays, empty")
    #expect(try await storedRows(library, solo.id) == 0)
}

/// A move to Recently Deleted, a move that failed (the song still leaves pointFlac), and a plain removal from a folder
/// read in place all take the song out of its playlists. A song not named stays.
@Test func trashedAndPlainRemovalsLeavePlaylistsToo() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    let trashed = box.downloads.appending(path: "Ada Vale/01 Trashed.flac")
    let stuck = box.downloads.appending(path: "Ada Vale/02 Stuck.flac")
    let inPlace = box.external.appending(path: "03 In Place.flac")
    let stays = box.external.appending(path: "04 Stays.flac")
    try TaggedFlac.write("s16-44100", to: trashed, tags: [("TITLE", "Trashed")])
    try TaggedFlac.write("s24-48000", to: stuck, tags: [("TITLE", "Stuck")])
    try TaggedFlac.write("s16-48000", to: inPlace, tags: [("TITLE", "In Place")])
    try TaggedFlac.write("s24-96000", to: stays, tags: [("TITLE", "Stays")])
    _ = try await library.addFolder(box.downloads)
    _ = try await library.addFolder(box.external)
    let id = { (title: String) in try #require(library.current.tracks.values.first { $0.title == title }?.id) }
    let all = [try id("Trashed"), try id("Stuck"), try id("In Place"), try id("Stays")]
    let mix = try await library.createPlaylist(name: "Mix", colourID: "amber")
    _ = try await library.addTracks(all, to: Playlist.favouritesID)
    _ = try await library.addTracks(all.reversed(), to: mix.id)

    let removal = try await library.remove(
        trackIDs: Array(all.prefix(3)), trashing: box.trash(failing: ["02 Stuck.flac"]))

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 2, trashedFiles: 1, trashFailures: 1))
    #expect(box.exists(stuck) && box.exists(inPlace) && !box.exists(trashed))
    #expect(await songs(library, Playlist.favouritesID) == [all[3]])
    #expect(await songs(library, mix.id) == [all[3]])
}

/// The prune is part of the removal's transaction: should it roll back, the playlists are as they were.
@Test func aFailedRemovalLeavesPlaylistsAsTheyWere() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    _ = await library.importFiles([try box.picked("s16-44100", as: "song.flac", title: "Song")])
    let song = try #require(library.current.tracks.values.first)
    _ = try await library.addTracks([song.id], to: Playlist.favouritesID)
    await library.failNextRemoval()

    await #expect(throws: LibraryDatabaseError.self) { _ = try await library.remove(trackIDs: [song.id]) }

    #expect(await songs(library, Playlist.favouritesID) == [song.id])
}

/// Review focus 1: a song whose file is only missing for now (iCloud, an unreachable folder) stays in its playlists,
/// and is in the catalog again when the file returns. A rescan never prunes playlists.
@Test func aSongWhoseFileIsGoneForNowStaysInItsPlaylists() async throws {
    let box = try PlaylistSandbox()
    let library = try box.open()
    let file = box.external.appending(path: "Album/01 Away.flac")
    let aside = box.root.appending(path: "Aside/01 Away.flac")
    try TaggedFlac.write("s24-96000", to: file, tags: [("TITLE", "Away")])
    _ = try await library.addFolder(box.external)
    let song = try #require(library.current.tracks.values.first)
    let mix = try await library.createPlaylist(name: "Mix", colourID: "amber")
    _ = try await library.addTracks([song.id], to: Playlist.favouritesID)
    _ = try await library.addTracks(["other", song.id], to: mix.id)

    try FileManager.default.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: file, to: aside)
    let gone = await library.rescan()

    #expect(gone.removed == [song.id])
    #expect(library.current.tracks[song.id] == nil)
    #expect(await songs(library, Playlist.favouritesID) == [song.id])
    #expect(await songs(library, mix.id) == ["other", song.id])

    try FileManager.default.moveItem(at: aside, to: file)
    let back = await library.rescan()

    #expect(back.added == [song.id])
    #expect(library.current.tracks[song.id]?.title == "Away")
    #expect(await songs(library, Playlist.favouritesID) == [song.id])
    #expect(await songs(library, mix.id) == ["other", song.id])
}
