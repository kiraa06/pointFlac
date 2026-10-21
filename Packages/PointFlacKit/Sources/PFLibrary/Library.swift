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
        let result = await inbox.importFiles(urls)
        let names = result.added.map(\.id)
        var outcome = LibraryImportResult(
            added: [], rejected: result.rejected,
            duplicates: urls.count - result.added.count - result.rejected.count)
        do {
            let (report, added) = try await run(.ifChanged) { store in
                var report = ScanReport()
                try store.scan(folder: LibraryStore.libraryFolderID, into: &report)
                // In the library folder a file's path relative to it is its name.
                let ids = try names.compactMap {
                    try store.trackID(folder: LibraryStore.libraryFolderID, relativePath: $0)
                }
                return ImportScan(report: report, added: ids)
            }.pair
            outcome.added = added
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
    @discardableResult
    public func addFolder(_ url: URL) async throws -> ScanReport {
        try await run(.ifChanged) { store in
            let id = try store.addFolder(url)
            var report = ScanReport()
            try store.scan(folder: id, into: &report)
            return report
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

    /// For tests: lowers the per-folder file cap.
    func setMaxFilesPerFolder(_ cap: Int) async {
        _ = try? await run(.never) { $0.maxFilesPerFolder = cap }
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
    private enum Publish {
        case never
        case always
        case ifChanged
    }

    /// Runs `body` on the library's queue; then, when `rule` says the result changed the library, publishes the
    /// catalog before the caller resumes, so `current` already shows what the call did.
    private func run<T: Sendable>(
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

    private static func log(_ error: any Error, during operation: String) {
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

private struct ImportScan: Sendable, ChangeReporting {
    var report: ScanReport
    var added: [String]
    var changedLibrary: Bool { !report.changedNothing }
    var pair: (ScanReport, [String]) { (report, added) }
}

/// A folder the library reads: the app's own library folder (always first) or one added in place.
public struct LibraryFolder: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
}
