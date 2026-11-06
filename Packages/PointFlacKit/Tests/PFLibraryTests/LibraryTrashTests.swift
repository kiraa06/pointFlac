import Foundation
import PFCore
import PFTestSupport
import Synchronization
import Testing

@testable import PFLibrary

/// Kiran's request: deleting a song whose file is in the folder chosen for downloads moves the file to Recently
/// Deleted, where it can be restored for 30 days, instead of leaving it behind. Only files inside that folder; every
/// other track keeps today's rule. Should the move fail, the file is never deleted: the song leaves pointFlac only, as
/// for any folder read in place, and the removal says so.
///
/// The trash operation is injected (`TrashFolder.trash`): the real one would fill the Mac's Trash from a host test.
private final class TrashSandbox {
    let root: URL
    var libraryFolder: URL { root.appending(path: "Documents/Library", directoryHint: .isDirectory) }
    var database: URL { root.appending(path: "Support/library.sqlite") }
    var artwork: URL { root.appending(path: "Support/Artwork", directoryHint: .isDirectory) }
    /// The folder picked for downloads, read in place.
    var downloads: URL { root.appending(path: "iCloud Drive/pointFlac", directoryHint: .isDirectory) }
    /// Another folder read in place.
    var other: URL { root.appending(path: "On My iPhone/Music", directoryHint: .isDirectory) }
    /// Where the injected trash puts what it is given, standing in for Recently Deleted.
    var bin: URL { root.appending(path: "Recently Deleted", directoryHint: .isDirectory) }
    let trashed = Calls()

    /// The names the trash was handed, in order.
    final class Calls: Sendable {
        private let names = Mutex<[String]>([])
        func append(_ name: String) { names.withLock { $0.append(name) } }
        var all: [String] { names.withLock { $0 } }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "LibraryTrash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func open() throws -> Library {
        try Library(databaseURL: database, libraryFolder: libraryFolder, artworkFolder: artwork)
    }

    /// The download folder's rule, with a trash that moves the file into `bin`, or fails.
    func rule(_ folder: URL? = nil, failing: Bool = false) -> TrashFolder {
        let bin = bin
        let trashed = trashed
        return TrashFolder(folder ?? downloads) { file in
            trashed.append(file.lastPathComponent)
            if failing { throw CocoaError(.featureUnsupported) }
            try FileManager.default.moveItem(at: file, to: bin.appending(path: file.lastPathComponent))
        }
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func removedRows(_ library: Library) async throws -> Int {
        let rows = try await library.run(.never) { try $0.database.query("SELECT COUNT(*) FROM removed") }
        return Int(rows.first?.first?.int ?? -1)
    }
}

@Test func aFileInTheDownloadFolderMovesToRecentlyDeleted() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let file = box.downloads.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Fold"), ("ALBUM", "Paper Moons")])
    _ = try await library.addFolder(box.downloads)
    let track = try #require(library.current.tracks.values.first)

    let removal = try await library.remove(trackIDs: [track.id], trashing: box.rule())

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 0, trashedFiles: 1, trashFailures: 0))
    #expect(!box.exists(file), "the file left the download folder")
    #expect(box.exists(box.bin.appending(path: "01 Fold.flac")), "it is in Recently Deleted")
    #expect(library.current.tracks.isEmpty)
    #expect(try await box.removedRows(library) == 0, "nothing remembers it as removed")

    // Restored from Recently Deleted: the next scan finds it, as it would any file put back in the folder.
    try FileManager.default.moveItem(at: box.bin.appending(path: "01 Fold.flac"), to: file)
    let rescan = await library.rescan()
    #expect(rescan.added == [track.id])
    #expect(library.current.tracks[track.id]?.title == "Fold")
}

@Test func whenTrashingFailsTheFileStaysAndOnlyLeavesPointFlac() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let file = box.downloads.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Fold")])
    _ = try await library.addFolder(box.downloads)
    let track = try #require(library.current.tracks.values.first)

    let removal = try await library.remove(trackIDs: [track.id], trashing: box.rule(failing: true))

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 1, trashedFiles: 0, trashFailures: 1))
    #expect(box.trashed.all == ["01 Fold.flac"], "the move was tried")
    #expect(box.exists(file), "a file that would not move to Recently Deleted is kept")
    #expect(library.current.tracks.isEmpty)
    #expect(try await box.removedRows(library) == 1)
    // As for any folder read in place: a rescan leaves it out until it changes.
    let rescan = await library.rescan()
    #expect(rescan.added.isEmpty)
    #expect(library.current.tracks.isEmpty)
    #expect(box.exists(file))
}

@Test func otherFoldersAndTheAppsOwnFilesKeepTodaysRule() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let downloaded = box.downloads.appending(path: "A/B/01.flac")
    let elsewhere = box.other.appending(path: "02.flac")
    let own = box.libraryFolder.appending(path: "03.flac")
    try TaggedFlac.write("s16-44100", to: downloaded, tags: [("TITLE", "Downloaded")])
    try TaggedFlac.write("s24-48000", to: elsewhere, tags: [("TITLE", "Elsewhere")])
    try TaggedFlac.write("s24-96000", to: own, tags: [("TITLE", "Own")])
    await library.rescan()
    _ = try await library.addFolder(box.downloads)
    _ = try await library.addFolder(box.other)
    let ids = library.current.tracks.values.map(\.id)
    #expect(ids.count == 3)

    let removal = try await library.remove(trackIDs: ids, trashing: box.rule())

    #expect(removal == LibraryRemoval(deletedFiles: 1, removedFromLibrary: 1, trashedFiles: 1, trashFailures: 0))
    #expect(box.trashed.all == ["01.flac"], "only the download folder's file goes to the trash")
    #expect(!box.exists(downloaded))
    #expect(box.exists(elsewhere), "another folder's file is the user's, and stays")
    #expect(!box.exists(own), "the app's own copy is deleted, as before")
    #expect(try await box.removedRows(library) == 1)
    #expect(library.current.tracks.isEmpty)
}

@Test func withoutADownloadFolderNothingIsTrashed() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let file = box.downloads.appending(path: "01.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Kept")])
    _ = try await library.addFolder(box.downloads)
    let track = try #require(library.current.tracks.values.first)

    let removal = try await library.remove(trackIDs: [track.id])

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 1))
    #expect(box.exists(file))
}

/// The download folder picked inside a folder the library already reads: only the files inside it are trashed.
@Test func onlyFilesInsideTheDownloadFolderAreTrashed() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let picked = box.other.appending(path: "pointFlac", directoryHint: .isDirectory)
    let inside = picked.appending(path: "Artist/Album/01.flac")
    let beside = box.other.appending(path: "pointFlac 2/02.flac")
    try TaggedFlac.write("s16-44100", to: inside, tags: [("TITLE", "Inside")])
    try TaggedFlac.write("s24-48000", to: beside, tags: [("TITLE", "Beside")])
    _ = try await library.addFolder(box.other)
    let ids = library.current.tracks.values.map(\.id)

    let removal = try await library.remove(trackIDs: ids, trashing: box.rule(picked))

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 1, trashedFiles: 1, trashFailures: 0))
    #expect(!box.exists(inside))
    #expect(box.exists(beside), "a folder whose name merely starts the same is not inside it")
}

/// The safety rule: should something other than a file have taken the track's name (a folder, say), it is never
/// handed to the trash. The track leaves pointFlac only, and the removal reports that the move did not happen.
@Test func onlyAFileIsEverTrashed() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let file = box.downloads.appending(path: "01.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Song")])
    _ = try await library.addFolder(box.downloads)
    let track = try #require(library.current.tracks.values.first)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    try Data("keep me".utf8).write(to: file.appending(path: "notes.txt"))

    let removal = try await library.remove(trackIDs: [track.id], trashing: box.rule())

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 1, trashedFiles: 0, trashFailures: 1))
    #expect(box.trashed.all.isEmpty)
    #expect(box.exists(file.appending(path: "notes.txt")))
}
