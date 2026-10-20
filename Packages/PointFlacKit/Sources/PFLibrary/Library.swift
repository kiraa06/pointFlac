import Foundation
import PFCore
import PFFlac
import Synchronization

/// What an import into the library did.
public struct LibraryImportResult: Sendable {
    /// The library tracks for the files added, in the order picked.
    public var added: [String]
    /// The files refused, and why (spec §5.3).
    public var rejected: [ImportRejection]
    /// Files skipped because the library already has them.
    public var duplicates: Int
}

/// pointFlac's music library (spec §5.4): a SQLite database of the FLAC files in the app's own library folder and in
/// folders added in place, with their tags, formats, album grouping and covers.
///
/// Every operation runs on one private serial queue at utility priority: never on the main actor, and never on Swift's
/// cooperative pool, whose few threads must not block on file I/O. Operations run one at a time, in the order called.
///
/// The library publishes an immutable `LibraryCatalog` after each change. `current` returns the latest at once, from
/// any thread; `changes()` streams them. Search builds its index from a catalog (PFSearch), so it never touches the
/// database.
///
/// Files only enter through the admission rule: an import goes through `ImportInbox`, and a scan validates every new
/// or changed file with `FlacValidator` (by way of `FlacMetadataReader`). A file that fails is remembered with its size
/// and date, so later scans skip it without reading it until it changes.
public final class Library: Sendable {
    private let queue = DispatchQueue(label: "io.github.kiraa06.pointflac.library", qos: .utility)
    private let store: Confined
    private let inbox: ImportInbox
    private let published = Mutex<
        (catalog: LibraryCatalog, subscribers: [UUID: AsyncStream<LibraryCatalog>.Continuation])
    >(
        (.empty, [:]))

    /// `LibraryStore` is not thread-safe; it is only ever touched on `queue`.
    private final class Confined: @unchecked Sendable {
        let store: LibraryStore
        init(_ store: LibraryStore) { self.store = store }
    }

    /// Opens (or creates) the library. The database is read once here, so `current` is the stored library from the
    /// start, before any scan; call `rescan()` at launch to pick up what changed while the app was not running.
    ///
    /// - Parameters:
    ///   - databaseURL: the SQLite file, typically in Application Support (not Documents: the Files app shows that).
    ///   - libraryFolder: `Documents/Library`, where imports are copied.
    ///   - artworkFolder: where covers are kept, typically in Caches or Application Support.
    ///   - maxFileBytes: files larger than this are refused (spec §5.8).
    public init(
        databaseURL: URL, libraryFolder: URL, artworkFolder: URL,
        maxFileBytes: Int64 = ImportInbox.defaultMaxFileBytes
    ) throws {
        let store = try LibraryStore(
            databaseURL: databaseURL, libraryFolder: libraryFolder, artworkFolder: artworkFolder,
            maxFileBytes: maxFileBytes)
        self.store = Confined(store)
        inbox = ImportInbox(libraryFolder: libraryFolder, maxFileBytes: maxFileBytes)
        let catalog = try store.catalog()
        published.withLock { $0.catalog = catalog }
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
        let catalog = published.withLock { state in
            state.subscribers[id] = continuation
            return state.catalog
        }
        continuation.yield(catalog)
        continuation.onTermination = { [weak self] _ in
            self?.published.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Copies picked files into the library folder through the admission rule (`ImportInbox`), then reads them in.
    public func importFiles(_ urls: [URL]) async -> LibraryImportResult {
        let result = await inbox.importFiles(urls)
        let names = result.added.map(\.id)
        let added = await run(publishing: true) { store in
            var report = ScanReport()
            try store.scan(folder: LibraryStore.libraryFolderID, into: &report)
            // In the library folder a file's path relative to it is its name.
            return try names.compactMap { try store.trackID(folder: LibraryStore.libraryFolderID, relativePath: $0) }
        }
        return LibraryImportResult(
            added: added ?? [], rejected: result.rejected,
            duplicates: urls.count - result.added.count - result.rejected.count)
    }

    /// Re-reads what changed in every folder since the last scan: run at launch and when the app returns to the
    /// foreground. Only new or changed files (by size and modification date) are read.
    @discardableResult
    public func rescan() async -> ScanReport {
        await run(publishing: true) { try $0.scanAll() } ?? ScanReport()
    }

    /// Adds a folder the user picked to be read in place (spec §4.7 "Add folder"), remembers access to it with a
    /// security-scoped bookmark, and scans it.
    @discardableResult
    public func addFolder(_ url: URL) async throws -> ScanReport {
        try await runThrowing(publishing: true) { store in
            let id = try store.addFolder(url)
            var report = ScanReport()
            try store.scan(folder: id, into: &report)
            return report
        }
    }

    /// The folders the library reads: the library folder first, then the folders added in place.
    public func folders() async -> [LibraryFolder] {
        await run(publishing: false) { $0.folders.map { LibraryFolder(id: $0.id, name: $0.name) } } ?? []
    }

    /// Forgets a folder added in place, and its tracks. The files themselves are never touched.
    public func removeFolder(_ id: Int64) async throws {
        try await runThrowing(publishing: true) { try $0.removeFolder(id) }
    }

    /// The stored cover for `artworkID` (a JPEG at most 600 px on its long side), or nil. Safe from any thread; held
    /// in a byte-bounded memory cache.
    public func artwork(_ artworkID: String?) -> Data? {
        guard let artworkID else { return nil }
        return store.store.artwork.data(for: artworkID)
    }

    /// For tests: how many files scans have read in full.
    func probeCount() async -> Int {
        await run(publishing: false) { $0.probes } ?? -1
    }

    /// Runs `body` on the library's queue; when `publishing`, then publishes the catalog it may have changed.
    private func runThrowing<T: Sendable>(
        publishing: Bool, _ body: @escaping @Sendable (LibraryStore) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                let outcome = Result { try body(store.store) }
                // Published before the caller resumes, so `current` already shows what the call did.
                if publishing, let catalog = try? store.store.catalog() { self.publish(catalog) }
                continuation.resume(with: outcome)
            }
        }
    }

    private func run<T: Sendable>(publishing: Bool, _ body: @escaping @Sendable (LibraryStore) throws -> T) async -> T?
    {
        try? await runThrowing(publishing: publishing, body)
    }

    private func publish(_ catalog: LibraryCatalog) {
        let subscribers = published.withLock { state in
            state.catalog = catalog
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(catalog) }
    }
}

/// A folder the library reads: the app's own library folder (always first) or one added in place.
public struct LibraryFolder: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
}
