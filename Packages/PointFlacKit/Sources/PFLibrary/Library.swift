import Foundation
import PFCore
import PFFlac
import Synchronization
import os

/// What an import into the library did.
public struct LibraryImportResult: Sendable {
    /// The library tracks for the files added, in the order picked.
    public var added: [String]
    /// The files refused, and why (spec §5.3).
    public var rejected: [ImportRejection]
    /// Files skipped because the library already has them.
    public var duplicates: Int
    /// The library tracks those duplicates matched, in the order picked: what a download the library already had
    /// became. One the library can't name (not read yet, say) is left out.
    public var existing: [String] = []
    /// Set when the files were copied in but could not all be recorded (a database error): they are in the library
    /// folder, and the next rescan picks them up.
    public var error: String?
}

/// pointFlac's music library (spec §5.4): a SQLite database of the FLAC files in the app's own library folder and in
/// folders added in place, with their tags, formats, album grouping and covers.
///
/// Every operation runs on one private serial queue at utility priority: never on the main actor, and never on Swift's
/// cooperative pool, whose few threads must not block on file I/O. Operations run one at a time, in the order called.
///
/// The library publishes an immutable `LibraryCatalog` whenever the library changed: after each committed batch of a
/// scan (so the shelf fills in during a first import), and at its end. A scan that changed nothing publishes nothing.
/// `current` returns the latest at once, from any thread; `changes()` streams them. Search builds its index from a
/// catalog (PFSearch), so it never touches the database.
///
/// Files only enter through the admission rule: an import goes through `ImportInbox`, and a scan validates every new
/// or changed file with `FlacValidator` (by way of `FlacMetadataReader`). A file that fails is remembered with its size
/// and date, so later scans skip it without reading it until it changes.
///
/// Errors are never swallowed: scans report them in `ScanReport.errors`, imports in `LibraryImportResult.error`, and
/// both log them (`os.Logger`, category "library"; codes public, messages private).
public final class Library: Sendable {
    private let queue = DispatchQueue(label: "io.github.kiraa06.pointflac.library", qos: .utility)
    private let store: Confined
    private let inbox: ImportInbox
    private let published = Mutex<
        (catalog: LibraryCatalog, subscribers: [UUID: AsyncStream<LibraryCatalog>.Continuation])
    >((.empty, [:]))
    private let repairScheduled = Mutex(false)
    /// For tests: how many files the loudness scan has opened to decode.
    let loudnessDecodes = Mutex(0)
    /// A loudness scan is running (`scanLoudness` runs one at a time), and what was asked for meanwhile.
    let loudnessScan = Mutex<(running: Bool, pending: LoudnessRequest?)>((false, nil))
    /// For tests: finished meters the scan holds to pool an album, now and at most.
    let loudnessMeters = Mutex<(current: Int, peak: Int)>((0, 0))
    /// For tests: called after each decoded chunk of a loudness scan.
    let loudnessChunkHook = Mutex<(@Sendable () -> Void)?>(nil)
    /// For tests: given each fresh scan that a cancelled scan hands its merged requests to, so a test can wait for it.
    let loudnessHandoffHook = Mutex<(@Sendable (Task<Void, Never>) -> Void)?>(nil)
    /// For tests: every album pool fails, as libebur128's would if it could not pool the meters.
    let loudnessPoolFault = Mutex(false)
    /// For tests: awaited after each track's measurement, before it is stored.
    let loudnessHook = Mutex<(@Sendable (String) async -> Void)?>(nil)
    /// For tests: how many catalogs have been published.
    private let publishedCount = Mutex(0)
    static let logger = Logger(subsystem: "io.github.kiraa06.pointflac", category: "library")

    /// `LibraryStore` is not thread-safe; it is only ever touched on `queue`.
    private final class Confined: @unchecked Sendable {
        let store: LibraryStore
        init(_ store: LibraryStore) { self.store = store }
    }

    /// Opens (or creates) the library. The database is read once here, so `current` is the stored library from the
    /// start, before any scan; call `rescan()` at launch to pick up what changed while the app was not running.
    ///
    /// - Parameters:
    ///   - databaseURL: the SQLite file, in Application Support (not Documents: the Files app shows that).
    ///   - libraryFolder: `Documents/Library`, where imports are copied.
    ///   - artworkFolder: where covers are kept, in Application Support. Caches is refused: the system purges it, and
    ///     covers are extracted only once.
    ///   - maxFileBytes: files larger than this are refused (spec §5.8).
    public init(
        databaseURL: URL, libraryFolder: URL, artworkFolder: URL,
        maxFileBytes: Int64 = ImportInbox.defaultMaxFileBytes
    ) throws {
        if Self.isInCaches(artworkFolder) { throw LibraryError.artworkFolderInCaches }
        let store = try LibraryStore(
            databaseURL: databaseURL, libraryFolder: libraryFolder, artworkFolder: artworkFolder,
            maxFileBytes: maxFileBytes)
        self.store = Confined(store)
        inbox = ImportInbox(libraryFolder: libraryFolder, maxFileBytes: maxFileBytes)
        let catalog = try store.catalog()
        published.withLock { $0.catalog = catalog }
        store.onBatchCommitted = { [weak self] in self?.publishCatalog() }
    }

    /// The latest catalog. Never blocks on a scan in progress.
    public var current: LibraryCatalog {
        published.withLock { $0.catalog }
    }

    /// Every catalog from now on, starting with the current one. Each new subscriber gets its own stream; a slow reader
    /// only ever sees the newest catalog, never a backlog.
    public func changes() -> AsyncStream<LibraryCatalog> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: LibraryCatalog.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        // Registered and given the current catalog under one lock, so a publish can never slip in between and leave
        // the stream ending on the older catalog.
        published.withLock { state in
            state.subscribers[id] = continuation
            continuation.yield(state.catalog)
        }
        continuation.onTermination = { [weak self] _ in
            self?.published.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Copies picked files into the library folder through the admission rule (`ImportInbox`), then reads them in.
    public func importFiles(_ urls: [URL]) async -> LibraryImportResult {
        let result = await inbox.importReporting(urls)
        let names = result.added.map(\.id)
        let existing = result.existing
        var outcome = LibraryImportResult(
            added: [], rejected: result.rejected,
            duplicates: urls.count - result.added.count - result.rejected.count)
        do {
            let scan = try await run(.ifChanged) { store in
                var report = ScanReport()
                try store.scan(folder: LibraryStore.libraryFolderID, into: &report)
                // In the library folder a file's path relative to it is its name.
                let ids = { (names: [String]) in
                    try names.compactMap { try store.trackID(folder: LibraryStore.libraryFolderID, relativePath: $0) }
                }
                return ImportScan(report: report, added: try ids(names), existing: try ids(existing))
            }
            let report = scan.report
            outcome.added = scan.added
            outcome.existing = scan.existing
            if !report.errors.isEmpty { outcome.error = report.errors.joined(separator: "; ") }
        } catch {
            outcome.error = String(describing: error)
            Self.log(error, during: "import")
        }
        return outcome
    }

    /// Re-reads what changed in every folder since the last scan: run at launch and when the app returns to the
    /// foreground. Only new or changed files (by size and modification date) are read. Errors are in the report.
    @discardableResult
    public func rescan() async -> ScanReport {
        do {
            let report = try await run(.ifChanged) { try $0.scanAll() }
            for error in report.errors { Self.logger.error("Scan: \(error, privacy: .private)") }
            return report
        } catch {
            Self.log(error, during: "rescan")
            var report = ScanReport()
            report.errors.append(String(describing: error))
            return report
        }
    }

    /// Adds a folder the user picked to be read in place (spec §4.7 "Add folder"), remembers access to it with a
    /// security-scoped bookmark, and scans it. Throws `LibraryError.overlappingFolder` for a folder inside or around
    /// one already read.
    ///
    /// Always publishes a catalog: a folder found again (one whose bookmark did not resolve at launch) brings its
    /// songs back even when the scan finds every file unchanged.
    @discardableResult
    public func addFolder(_ url: URL) async throws -> ScanReport {
        try await run(.always) { store in
            let id = try store.addFolder(url)
            var report = ScanReport()
            try store.scan(folder: id, into: &report)
            return report
        }
    }

    /// Takes in one file just saved inside a folder the library reads, without scanning the rest of that folder, and
    /// publishes the catalog when it changed: for a download filed into the folder the user picked for downloads,
    /// which may hold thousands of songs. Returns the file's track ID, so the caller can confirm the catalog has it
    /// before deleting its own copy; nil when the admission rule refuses the file or it cannot be read now. A file
    /// the user removed from the library before comes back (`LibraryStore.admit(file:)`). Throws
    /// `LibraryError.outsideFolders` when no folder the library reads holds the file.
    public func admitFile(_ url: URL) async throws -> String? {
        try await run(.ifChanged) { try $0.admit(file: url) }.id
    }

    /// The folder the library reads that is, or holds, `url`: the library folder, a folder added in place, or nil.
    /// Lets a caller tell whether a folder inside one already read needs adding (`addFolder` refuses it as
    /// overlapping, though its files are read already).
    public func folder(containing url: URL) async -> LibraryFolder? {
        try? await run(.never) { store in
            store.folder(containing: url).map { id in
                LibraryFolder(id: id, name: store.folders.first { $0.id == id }?.name ?? url.lastPathComponent)
            }
        }
    }

    /// The folders the library reads: the library folder first, then the folders added in place.
    public func folders() async -> [LibraryFolder] {
        (try? await run(.never) { $0.folders.map { LibraryFolder(id: $0.id, name: $0.name) } })
            ?? []
    }

    /// Forgets a folder added in place, and its tracks. The files themselves are never touched.
    public func removeFolder(_ id: Int64) async throws {
        try await run(.always) { try $0.removeFolder(id) }
    }

    /// Takes tracks out of the library at the user's request (Delete Album, Delete Song), and publishes the new
    /// catalog before returning. A track in the app's own library folder is deleted from the device, with any folder
    /// that leaves empty below the library folder. A track whose file is inside `trashing`'s folder (the folder the
    /// user picked for downloads) has its file moved to Recently Deleted, where the user can restore it; should that
    /// fail, the file stays and the track is treated as below. A track in any other folder added in place only leaves
    /// the library: its file is the user's and is never touched, and rescans leave it out until it changes. Covers no
    /// track uses any more are deleted. Unknown IDs are ignored.
    ///
    /// Should it fail, the database rolls back but a file already deleted stays deleted, so the library rescans
    /// before throwing: its catalog, and the shelf, never list a file that is gone.
    public func remove(trackIDs: [String], trashing: TrashFolder? = nil) async throws -> LibraryRemoval {
        do {
            return try await run(.ifChanged) { try $0.remove(trackIDs: trackIDs, trashing: trashing) }
        } catch {
            Self.log(error, during: "remove")
            await rescan()
            throw error
        }
    }

    /// Counts one listen of `trackID` (the library track's ID) at `date`, and returns its new total. Does not publish a
    /// catalog: a listen changes no track, and the shelf keeps its own running counts (`listenStats()` seeds them).
    /// Should the database fail, the failure is logged and the result is a zero count, which a caller ignores.
    @discardableResult
    public func recordListen(trackID: String, at date: Date) async -> ListenStat {
        do {
            return try await run(.never) { try $0.recordListen(trackID: trackID, at: date) }
        } catch {
            Self.log(error, during: "recordListen")
            return ListenStat(count: 0, lastAt: nil)
        }
    }

    /// Every listen the library has recorded, keyed by track ID. Includes tracks no longer in the library.
    public func listenStats() async -> [String: ListenStat] {
        (try? await run(.never) { try $0.listenStats() }) ?? [:]
    }

    // MARK: Playlists
    //
    // Favourites and the user's named playlists (spec "Playlists as custom pressings" §5). They run on the library's
    // queue like everything else, and none publishes a catalog: a playlist changes no track. The app keeps its own copy,
    // read again with `playlists()` after each change. A change the rules refuse throws `PlaylistError`; a database
    // failure throws `LibraryDatabaseError`. None touches a file or the catalog.

    /// Every playlist: Favourites first, then the others in the order they were made (ties by ID). Each carries every
    /// track ID it stores, in order, including songs not in the catalog now (a file gone for now): the app filters them
    /// to the catalog. Should the database fail, the failure is logged and the result is empty.
    public func playlists() async -> [Playlist] {
        do {
            return try await run(.never) { try $0.playlists() }
        } catch {
            Self.log(error, during: "playlists")
            return []
        }
    }

    /// Makes a playlist with no songs. `name` is trimmed and must then be 1 to 60 characters (`invalidName`); duplicate
    /// names are allowed. `colourID` is the pressing colour's ID, stored as given; it must not be empty
    /// (`invalidColour`). The new playlist's ID is a lower-case UUID.
    public func createPlaylist(name: String, colourID: String) async throws -> Playlist {
        try await run(.never) { try $0.createPlaylist(name: name, colourID: colourID) }
    }

    /// Renames a playlist, under `createPlaylist`'s rule for names. Favourites can't be renamed (`favouritesIsFixed`).
    public func renamePlaylist(id: String, name: String) async throws {
        try await run(.never) { try $0.renamePlaylist(id: id, name: name) }
    }

    /// Changes a playlist's pressing colour. Favourites' too: Ruby is only its default.
    public func setPlaylistColour(id: String, colourID: String) async throws {
        try await run(.never) { try $0.setPlaylistColour(id: id, colourID: colourID) }
    }

    /// Deletes a playlist, but never its songs' tracks or files. Favourites can't be deleted (`favouritesIsFixed`).
    public func deletePlaylist(id: String) async throws {
        try await run(.never) { try $0.deletePlaylist(id: id) }
    }

    /// Appends songs to the end of a playlist, in the order given, each once: repeats in `ids`, and songs the playlist
    /// already holds, are skipped. Returns how many were added. An ID not in the catalog is stored all the same.
    @discardableResult
    public func addTracks(_ ids: [String], to playlistID: String) async throws -> Int {
        try await run(.never) { try $0.addTracks(ids, to: playlistID) }
    }

    /// Takes songs out of a playlist; the rest keep their order. IDs the playlist does not hold are ignored.
    public func removeTracks(_ ids: [String], from playlistID: String) async throws {
        try await run(.never) { try $0.removeTracks(ids, from: playlistID) }
    }

    /// Puts a playlist's songs in the order of `trackIDs`, which must be exactly the songs it stores (as
    /// `playlists()` lists them, unfiltered), each once. Anything else throws `notFound` and changes nothing.
    public func reorderPlaylist(id: String, trackIDs: [String]) async throws {
        try await run(.never) { try $0.reorderPlaylist(id: id, trackIDs: trackIDs) }
    }

    /// The stored cover for `artworkID` (a JPEG at most 600 px on its long side), or nil. Safe from any thread; held
    /// in a byte-bounded memory cache. A cover whose file has gone is regenerated from its track in the background,
    /// so a later call finds it again.
    public func artwork(_ artworkID: String?) -> Data? {
        guard let artworkID else { return nil }
        let artwork = store.store.artwork
        if let data = artwork.data(for: artworkID) { return data }
        if artwork.isValid(artworkID) { scheduleArtworkRepair() }
        return nil
    }

    /// For tests: how many files scans have read in full.
    func probeCount() async -> Int {
        (try? await run(.never) { $0.probes }) ?? -1
    }

    /// For tests: commit and publish every `size` probed files.
    func setBatchSize(_ size: Int) async {
        _ = try? await run(.never) { $0.batchSize = size }
    }

    /// For tests: how many catalogs have been published since the library opened.
    var publishCount: Int { publishedCount.withLock { $0 } }

    /// For tests: every track's `r128_state` (0 not measured, 1 measured, 2 unmeasurable), by track ID.
    func loudnessStates() async -> [String: Int] {
        let rows = (try? await run(.never) { try $0.database.query("SELECT id, r128_state FROM tracks") }) ?? []
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in row[0].string.map { ($0, Int(row[1].int ?? -1)) } })
    }

    /// For tests: lowers the largest album the loudness scan pools.
    func setMaxLoudnessAlbum(_ cap: Int) async {
        _ = try? await run(.never) { $0.maxAlbumTracks = cap }
    }

    /// For tests: lowers the per-folder file cap.
    func setMaxFilesPerFolder(_ cap: Int) async {
        _ = try? await run(.never) { $0.maxFilesPerFolder = cap }
    }

    /// For tests: the next removal fails inside its transaction, after deleting its files.
    func failNextRemoval() async {
        _ = try? await run(.never) { $0.removalFault = LibraryDatabaseError(code: 1, message: "injected failure") }
    }

    /// For tests: waits until everything queued before it has run.
    func barrier() async {
        _ = try? await run(.never) { _ in true }
    }

    private func scheduleArtworkRepair() {
        let first = repairScheduled.withLock { scheduled in
            defer { scheduled = true }
            return !scheduled
        }
        guard first else { return }
        queue.async { [store] in
            do { try store.store.repairArtwork() } catch { Self.log(error, during: "artwork repair") }
            self.repairScheduled.withLock { $0 = false }
        }
    }

    /// When a call publishes a catalog: never (reads), always (a folder removed), or if its scan changed something.
    enum Publish {
        case never
        case always
        case ifChanged
    }

    /// Runs `body` on the library's queue; then, when `rule` says the result changed the library, publishes the
    /// catalog before the caller resumes, so `current` already shows what the call did.
    func run<T: Sendable>(
        _ rule: Publish, _ body: @escaping @Sendable (LibraryStore) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                let outcome = Result { try body(store.store) }
                if case .success(let value) = outcome {
                    let changed =
                        switch rule {
                        case .never: false
                        case .always: true
                        case .ifChanged: (value as? ChangeReporting)?.changedLibrary ?? true
                        }
                    if changed { self.publishCatalog() }
                }
                continuation.resume(with: outcome)
            }
        }
    }

    /// Reads the catalog and publishes it. On the library's queue only.
    private func publishCatalog() {
        let catalog: LibraryCatalog
        do {
            catalog = try store.store.catalog()
        } catch {
            Self.log(error, during: "publish")
            return
        }
        let subscribers = published.withLock { state in
            state.catalog = catalog
            return Array(state.subscribers.values)
        }
        publishedCount.withLock { $0 += 1 }
        for subscriber in subscribers { subscriber.yield(catalog) }
    }

    static func log(_ error: any Error, during operation: String) {
        let code = (error as? LibraryDatabaseError).map { String($0.code) } ?? "-"
        logger.error(
            "\(operation, privacy: .public) failed (code \(code, privacy: .public)): \(String(describing: error), privacy: .private)"
        )
    }

    private static func isInCaches(_ folder: URL) -> Bool {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let cachesPath = caches.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(cachesPath)
    }
}

/// Results that say whether they changed the library, so a no-op scan publishes nothing.
private protocol ChangeReporting {
    var changedLibrary: Bool { get }
}

extension ScanReport: ChangeReporting {
    var changedLibrary: Bool { !changedNothing }
}

/// What admitting one file did (`LibraryStore.admit(file:)`): the scan of that file, and its track, if admitted.
struct AdmitScan: Sendable {
    var report: ScanReport
    var id: String?
}

extension AdmitScan: ChangeReporting {
    var changedLibrary: Bool { !report.changedNothing }
}

private struct ImportScan: Sendable, ChangeReporting {
    var report: ScanReport
    var added: [String]
    var existing: [String]
    var changedLibrary: Bool { !report.changedNothing }
}

/// What removing tracks did (`Library.remove(trackIDs:trashing:)`).
public struct LibraryRemoval: Sendable, Equatable {
    /// Tracks whose file was deleted from the app's library folder, or was already gone from it.
    public var deletedFiles: Int
    /// Tracks that left the library while their file stays where it is: those in folders added in place, including
    /// `trashFailures`.
    public var removedFromLibrary: Int
    /// Tracks whose file moved to Recently Deleted (or was already gone from the folder): those in the folder picked
    /// for downloads.
    public var trashedFiles = 0
    /// Tracks whose file should have moved to Recently Deleted but would not (a provider without a trash, an error):
    /// they left the library, and their file stays in its folder. The UI says so.
    public var trashFailures = 0
}

extension LibraryRemoval: ChangeReporting {
    var changedLibrary: Bool { deletedFiles + removedFromLibrary + trashedFiles > 0 }
}

/// Which files a removal moves to Recently Deleted instead of keeping: those inside `folder`, the folder the user
/// picked for downloads. The app hands it in; the library knows nothing of downloads.
public struct TrashFolder: Sendable {
    /// The folder, as the app resolved it (its security scope is opened around the removal).
    public var folder: URL
    /// How long a file's provider (iCloud Drive) may take to grant the coordinated write before the move is given up.
    public var timeout: Duration
    /// The move itself, run inside the coordinated write: the system trash (`systemTrash`) unless a test or the
    /// simulator's stand-in replaces it. Returns where the file went, or nil when the trash did not say.
    public var move: @Sendable (URL) throws -> URL?

    public init(
        _ folder: URL, timeout: Duration = .seconds(30),
        move: @escaping @Sendable (URL) throws -> URL? = TrashFolder.systemTrash
    ) {
        self.folder = folder
        self.timeout = timeout
        self.move = move
    }

    /// Why a move did not happen.
    public enum Failure: Error, Sendable {
        /// The file's provider did not grant the coordinated write within `timeout`; the move was called off.
        case timedOut
    }

    /// `FileManager.trashItem`: Recently Deleted in the Files app, for iCloud Drive and On My iPhone; the Trash on a
    /// Mac. Throws when the volume has none (the simulator's never do: Cocoa error 3328).
    public static func systemTrash(_ file: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Moves `file` to Recently Deleted inside a coordinated write for deleting, so a file provider takes part and
    /// nobody writes the file meanwhile, and returns where it went. Blocking: called on the library's queue.
    ///
    /// The provider gets `timeout` to grant the write; past that the move is called off and the coordinator cancelled,
    /// so the move never runs later, and this throws `Failure.timedOut`. A move that has started is left to finish. A
    /// refused coordination, or a move that fails, throws; the file is then left where it was.
    public func moveToRecentlyDeleted(_ file: URL) throws -> URL? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.writingIntent(with: file, options: .forDeleting)
        let box = MoveBox()
        let done = DispatchSemaphore(value: 0)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let move = move
        coordinator.coordinate(with: [intent], queue: queue) { error in
            let proceed = box.phase.withLock { phase -> Bool in
                guard case .waiting = phase else { return false }
                if let error {
                    phase = .finished(.failure(error))
                    return false
                }
                phase = .working
                return true
            }
            if proceed {
                let result = Result { try move(intent.url) }
                box.phase.withLock { $0 = .finished(result) }
            }
            done.signal()
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if done.wait(timeout: .now() + seconds) == .timedOut {
            let gaveUp = box.phase.withLock { phase -> Bool in
                guard case .waiting = phase else { return false }
                phase = .abandoned
                return true
            }
            if gaveUp {
                coordinator.cancel()
                throw Failure.timedOut
            }
            done.wait()
        }
        guard case .finished(let result) = box.phase.withLock({ $0 }) else { throw Failure.timedOut }
        return try result.get()
    }

    /// Where a coordinated move is: waiting for the grant, running, done, or given up before it was granted.
    private enum Phase: Sendable {
        case waiting
        case working
        case finished(Result<URL?, any Error>)
        case abandoned
    }

    private final class MoveBox: Sendable {
        let phase = Mutex<Phase>(.waiting)
    }
}

/// A folder the library reads: the app's own library folder (always first) or one added in place.
public struct LibraryFolder: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
}
