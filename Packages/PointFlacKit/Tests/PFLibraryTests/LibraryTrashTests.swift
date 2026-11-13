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
/// The move itself is injected (`TrashFolder.move`), inside the real coordinated write: the system trash would fill the
/// Mac's Trash from a host test. `realTrashOnThisVolume` runs the real one once, and empties what it trashed.
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

    /// The download folder's rule, with a move that puts the file in `bin`, or fails.
    func rule(_ folder: URL? = nil, failing: Bool = false, timeout: Duration = .seconds(30)) -> TrashFolder {
        let bin = bin
        let trashed = trashed
        return TrashFolder(folder ?? downloads, timeout: timeout) { file in
            trashed.append(file.lastPathComponent)
            if failing { throw CocoaError(.featureUnsupported) }
            let target = bin.appending(path: file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: target)
            return target
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

/// Review fix: the folder picked for downloads gone as a whole (moved, its volume ejected) is not "the file is already
/// gone": the song leaves pointFlac, remembered as removed, so it does not come back with the folder.
@Test func aFileWhoseDownloadFolderIsGoneIsRememberedAsRemoved() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let file = box.downloads.appending(path: "A/01.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Away")])
    _ = try await library.addFolder(box.downloads)
    let track = try #require(library.current.tracks.values.first)
    let away = box.root.appending(path: "Moved Away", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: box.downloads, to: away)

    let removal = try await library.remove(trackIDs: [track.id], trashing: box.rule())

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 1, trashedFiles: 0, trashFailures: 1))
    #expect(box.trashed.all.isEmpty)
    #expect(try await box.removedRows(library) == 1)
    try FileManager.default.moveItem(at: away, to: box.downloads)
    let rescan = await library.rescan()
    #expect(rescan.added.isEmpty, "the song came back with its folder")
    #expect(box.exists(file))
}

/// Review fix: the move happens before the database transaction, never inside it, so a slow file provider never holds
/// the library's write lock. A second connection tries to start a write while the move runs.
@Test func theMoveRunsOutsideTheDatabaseTransaction() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let file = box.downloads.appending(path: "01.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Song")])
    _ = try await library.addFolder(box.downloads)
    let track = try #require(library.current.tracks.values.first)
    let database = box.database
    let bin = box.bin
    let writable = Flag()
    let rule = TrashFolder(box.downloads) { file in
        let other = try SQLiteDatabase(url: database)
        do {
            try other.execute("BEGIN IMMEDIATE")
            try other.execute("ROLLBACK")
            writable.set(true)
        } catch {
            writable.set(false)
        }
        let target = bin.appending(path: file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    let removal = try await library.remove(trackIDs: [track.id], trashing: rule)

    #expect(removal.trashedFiles == 1)
    #expect(writable.value == true, "the move ran while the library held its write lock")
    #expect(library.current.tracks.isEmpty)
}

/// Review fix: a file provider that never grants the coordinated write (a stalled iCloud Drive) is given up on after
/// the timeout, and the coordination cancelled, so the move never runs later. The file is kept: the song leaves
/// pointFlac only, with a `removed` row, and the removal reports the failure.
@Test func aMoveTheProviderNeverGrantsIsGivenUpAndTheFileKept() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let file = box.downloads.appending(path: "01.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Stalled")])
    _ = try await library.addFolder(box.downloads)
    let track = try #require(library.current.tracks.values.first)
    let holder = CoordinationHolder(file)
    try await holder.hold()

    let start = ContinuousClock.now
    let removal = try await library.remove(
        trackIDs: [track.id], trashing: box.rule(timeout: .milliseconds(300)))
    let took = ContinuousClock.now - start
    await holder.release()
    try await Task.sleep(for: .milliseconds(300))

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 1, trashedFiles: 0, trashFailures: 1))
    #expect(took < .seconds(2), "the removal waited \(took) for the provider")
    #expect(box.trashed.all.isEmpty, "the cancelled coordination ran the move after all")
    #expect(box.exists(file))
    #expect(try await box.removedRows(library) == 1)
    #expect(library.current.tracks.isEmpty)
}

/// Re-review fix: a song whose file iCloud evicted shows only as its placeholder, ".Name.flac.icloud". Deleting it moves
/// the placeholder to Recently Deleted, so the next scan does not download the song back.
@Test func anEvictedFilesPlaceholderMovesToRecentlyDeleted() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let (file, placeholder, track) = try await evicted(box, library)

    let removal = try await library.remove(trackIDs: [track], trashing: box.rule())

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 0, trashedFiles: 1, trashFailures: 0))
    #expect(box.trashed.all == [placeholder.lastPathComponent])
    #expect(!box.exists(placeholder), "the placeholder is still in the folder")
    #expect(!box.exists(file))
    #expect(try await box.removedRows(library) == 0)
}

/// Its placeholder that would not move is kept, and the song is remembered as removed, so the scan leaves it in iCloud.
@Test func anEvictedFilesPlaceholderThatWillNotMoveIsKept() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    let (_, placeholder, track) = try await evicted(box, library)

    let removal = try await library.remove(trackIDs: [track], trashing: box.rule(failing: true))

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 1, trashedFiles: 0, trashFailures: 1))
    #expect(box.trashed.all == [placeholder.lastPathComponent], "the move was tried")
    #expect(box.exists(placeholder))
    #expect(try await box.removedRows(library) == 1)
}

/// A song in the download folder whose file iCloud then evicted, leaving only ".01 Fold.flac.icloud": the file, the
/// placeholder and the track.
private func evicted(_ box: TrashSandbox, _ library: Library) async throws -> (URL, URL, String) {
    let file = box.downloads.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
    try TaggedFlac.write("s16-44100", to: file, tags: [("TITLE", "Fold")])
    _ = try await library.addFolder(box.downloads)
    let track = try #require(library.current.tracks.values.first).id
    let placeholder = file.deletingLastPathComponent().appending(path: ".01 Fold.flac.icloud")
    try FileManager.default.removeItem(at: file)
    try Data("placeholder".utf8).write(to: placeholder)
    return (file, placeholder, track)
}

/// Re-review fix: one stalled provider costs a removal one timeout, not one per song. After the first file times out
/// the rest are not tried: each is kept, remembered as removed, and reported.
@Test func afterOneTimeoutTheRestAreNotTried() async throws {
    let box = try TrashSandbox()
    let library = try box.open()
    for number in 1...3 {
        try TaggedFlac.write(
            ["s16-44100", "s24-48000", "s24-96000"][number - 1], to: box.downloads.appending(path: "0\(number).flac"),
            tags: [("TITLE", "Song \(number)")])
    }
    _ = try await library.addFolder(box.downloads)
    let ids = library.current.tracks.values.map(\.id)
    #expect(ids.count == 3)
    // Every file held, so whichever is tried first times out. (A write held on the folder does not hold the files.)
    let holders = (1...3).map { CoordinationHolder(box.downloads.appending(path: "0\($0).flac")) }
    for holder in holders { try await holder.hold() }

    let start = ContinuousClock.now
    let removal = try await library.remove(trackIDs: ids, trashing: box.rule(timeout: .seconds(1)))
    let took = ContinuousClock.now - start
    for holder in holders { await holder.release() }

    #expect(removal == LibraryRemoval(deletedFiles: 0, removedFromLibrary: 3, trashedFiles: 0, trashFailures: 3))
    #expect(took < .seconds(2), "the removal waited \(took): a timeout per song")
    #expect(box.trashed.all.isEmpty)
    for number in 1...3 { #expect(box.exists(box.downloads.appending(path: "0\(number).flac"))) }
    #expect(try await box.removedRows(library) == 3)
}

/// The real move, once: the coordinated write and `FileManager.trashItem` on a temporary file, on a volume with a
/// trash (the Mac's own). What it trashed is deleted again, so nothing piles up in the Trash.
@Test(.enabled(if: volumeHasTrash(FileManager.default.temporaryDirectory)))
func realTrashOnThisVolume() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "LibraryRealTrash-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "pointFlac trash test \(UUID().uuidString).flac")
    try Data([1, 2, 3]).write(to: file)

    let trashed = try TrashFolder(folder).moveToRecentlyDeleted(file)

    let resulting = try #require(trashed, "the trash did not say where the file went")
    #expect(!FileManager.default.fileExists(atPath: file.path), "the file is still in its folder")
    #expect(FileManager.default.fileExists(atPath: resulting.path), "nothing at \(resulting.path)")
    #expect(throws: Never.self, "the trashed copy is left in the Trash") {
        try FileManager.default.removeItem(at: resulting)
    }
}

/// Whether the volume holding `url` has a trash to move files into (the simulator's never do).
private func volumeHasTrash(_ url: URL) -> Bool {
    (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)) != nil
}

/// A Boolean set from a `@Sendable` closure.
private final class Flag: Sendable {
    private let state = Mutex<Bool?>(nil)
    func set(_ value: Bool) { state.withLock { $0 = value } }
    var value: Bool? { state.withLock { $0 } }
}

/// Holds a coordinated write of a file on a thread of its own until released (thirty seconds at most), as a file
/// provider that has not granted access yet would. The tests release it only once the removal has returned: a hold
/// that ran out by itself could end before the removal's timeout came round on a loaded machine.
private final class CoordinationHolder: Sendable {
    let file: URL
    private let held = Mutex(false)
    private let finished = Mutex(false)
    private let released = DispatchSemaphore(value: 0)

    init(_ file: URL) { self.file = file }

    func hold() async throws {
        let file = file
        Thread.detachNewThread { [self] in
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: [], error: &error) { _ in
                held.withLock { $0 = true }
                // Let go after thirty seconds at most, so code that never gives up fails the test rather than hangs it.
                _ = released.wait(timeout: .now() + 30)
            }
            finished.withLock { $0 = true }
        }
        while !held.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
    }

    func release() async {
        released.signal()
        while !finished.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
