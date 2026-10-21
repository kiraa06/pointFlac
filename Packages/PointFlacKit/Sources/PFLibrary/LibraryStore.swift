import Foundation
import PFCore
import PFFlac

/// What one scan did.
public struct ScanReport: Sendable, Equatable {
    /// Tracks new to the library.
    public var added: [String] = []
    /// Tracks whose file changed (tags edited, say) and was read again.
    public var updated: [String] = []
    /// Tracks found under a new path, keeping their ID.
    public var moved: [String] = []
    /// Tracks whose file is gone.
    public var removed: [String] = []
    /// Files not read again because their size and modification date are unchanged.
    public var unchanged = 0
    /// Files that are not admitted, by path relative to their folder, with the reason. Each is reported once, on the
    /// scan that first sees it (or sees it changed); later scans skip it without reading it.
    public var rejected: [String: String] = [:]
    /// iCloud files not yet downloaded. Their download has been started; a later scan adds them, and a track already
    /// in the library whose file was evicted stays, marked cloud-pending.
    public var pendingDownloads = 0
    /// Tracks whose cloud-pending mark changed (evicted, or downloaded again).
    public var cloudChanged: [String] = []
    /// Files that could not be read this time (locked by data protection, a provider that failed). Transient: they
    /// are neither remembered as refused nor removed, and the next scan tries them again.
    public var unreadable: [String] = []
    /// Folders that could not be listed in full (missing, offline, no permission, or over the file cap). Nothing was
    /// removed from them.
    public var incompleteFolders: [String] = []
    /// What went wrong, for logs and diagnostics: database or file-system errors. Empty when the scan succeeded.
    public var errors: [String] = []

    public init() {}

    /// True when the scan changed nothing in the library, so there is no new catalog to publish.
    public var changedNothing: Bool {
        added.isEmpty && updated.isEmpty && moved.isEmpty && removed.isEmpty && cloudChanged.isEmpty
    }
}

/// Why the library refused an operation.
public enum LibraryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The folder is inside, or contains, one the library already reads; its files would be listed twice.
    case overlappingFolder(String)
    /// Artwork must live where the system never purges it (Application Support), not in Caches (§5.4).
    case artworkFolderInCaches

    public var description: String {
        switch self {
        case .overlappingFolder(let name): "“\(name)” overlaps a folder the library already reads"
        case .artworkFolderInCaches: "The artwork folder must not be in Caches"
        }
    }
}

/// The library's database, folders, scanner and artwork, confined to the library's serial queue.
///
/// Schema (version 1). Paths are stored relative to their folder, because iOS moves the app's container (and so
/// `Documents/Library`) when the app is updated; folders outside the app are found again through their bookmarks.
/// - `folders`: the app's own library folder (id 1), and each folder added in place, with its security-scoped bookmark.
/// - `tracks`: one row per admitted file: identity, location, size and modification date (what decides a re-read),
///   cleaned tags, format, album key and cover.
/// - `artwork`: one row per distinct stored cover.
/// - `skipped`: files that were refused, with their size and modification date, so a rescan never reads them again
///   until they change.
final class LibraryStore {
    static let libraryFolderID: Int64 = 1
    /// A scan reads no more than this many files per folder: a bound on a hostile or mistaken folder pick. A folder
    /// that reaches it is listed as incomplete, and nothing is removed from it.
    var maxFilesPerFolder = 250_000

    static let migrations = [
        """
        CREATE TABLE folders(
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,
            bookmark BLOB,
            name TEXT NOT NULL,
            added_at REAL NOT NULL);
        CREATE TABLE artwork(
            id TEXT PRIMARY KEY,
            bytes INTEGER NOT NULL);
        CREATE TABLE tracks(
            id TEXT PRIMARY KEY,
            folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            rel_path TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            content_id TEXT NOT NULL,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album_artist TEXT NOT NULL,
            album TEXT NOT NULL,
            disc INTEGER,
            track INTEGER,
            year INTEGER,
            sample_rate INTEGER NOT NULL,
            bits INTEGER NOT NULL,
            channels INTEGER NOT NULL,
            total_frames INTEGER NOT NULL,
            album_id TEXT NOT NULL,
            artwork_id TEXT REFERENCES artwork(id) ON DELETE SET NULL,
            added_at REAL NOT NULL,
            UNIQUE(folder_id, rel_path));
        CREATE INDEX tracks_content ON tracks(content_id);
        CREATE TABLE skipped(
            folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            rel_path TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            reason TEXT NOT NULL,
            PRIMARY KEY(folder_id, rel_path));
        """,
        // v2: a track whose iCloud file was evicted stays in the library, marked, instead of being removed.
        "ALTER TABLE tracks ADD COLUMN cloud_pending INTEGER NOT NULL DEFAULT 0;",
    ]

    /// Probed files per transaction: each batch is committed and published, so a scan killed part-way keeps what it
    /// read, and the shelf fills in while a first import runs.
    var batchSize = 150
    /// Called on the library's queue after each committed batch (the library publishes a catalog).
    var onBatchCommitted: (() -> Void)?

    let database: SQLiteDatabase
    let artwork: ArtworkStore
    private let maxFileBytes: Int64
    /// Each folder's location for this launch.
    private(set) var roots: [Int64: URL] = [:]
    /// External folders whose security scope this store opened. Held for the store's life: tracks in them must stay
    /// readable for playback, which starts long after a scan.
    private var scoped: [Int64: URL] = [:]
    /// For tests: how many files have been read in full (validated, tags, identity, cover).
    private(set) var probes = 0

    init(databaseURL: URL, libraryFolder: URL, artworkFolder: URL, maxFileBytes: Int64) throws {
        database = try SQLiteDatabase(url: databaseURL)
        try database.migrate(Self.migrations)
        artwork = ArtworkStore(folder: artworkFolder)
        self.maxFileBytes = maxFileBytes
        try database.query(
            "INSERT OR IGNORE INTO folders(id, kind, bookmark, name, added_at) VALUES (?, 'library', NULL, 'Library', ?)",
            [.integer(Self.libraryFolderID), .real(Date().timeIntervalSince1970)])
        roots[Self.libraryFolderID] = libraryFolder
        try resolveBookmarks()
    }

    deinit {
        for url in scoped.values { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Folders

    /// Adds a folder to be read in place, remembering access to it, and returns its ID. A folder already added
    /// returns its existing ID.
    ///
    /// A folder inside or around one already read (the library folder included) is refused: its files would be listed
    /// twice, and removing one folder would take the other's tracks.
    func addFolder(_ url: URL) throws -> Int64 {
        let candidate = Self.comparablePath(url)
        if let existing = roots.first(where: { Self.comparablePath($0.value) == candidate })?.key { return existing }
        for root in roots.values {
            let other = Self.comparablePath(root)
            if candidate.hasPrefix(other) || other.hasPrefix(candidate) {
                throw LibraryError.overlappingFolder(url.lastPathComponent)
            }
        }
        let scopedNow = url.startAccessingSecurityScopedResource()
        var kept = false
        // Whatever fails below, a scope this call opened and did not hand to `scoped` is closed again.
        defer {
            if scopedNow, !kept { url.stopAccessingSecurityScopedResource() }
        }
        let bookmark = try url.bookmarkData(
            options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
        try database.query(
            "INSERT INTO folders(kind, bookmark, name, added_at) VALUES ('bookmark', ?, ?, ?)",
            [.blob(bookmark), .text(url.lastPathComponent), .real(Date().timeIntervalSince1970)])
        guard let id = try database.query("SELECT last_insert_rowid()").first?.first?.int else {
            throw LibraryDatabaseError(code: 0, message: "no folder id")
        }
        roots[id] = url
        if scopedNow {
            scoped[id] = url
            kept = true
        }
        return id
    }

    /// A folder's path for overlap checks: symlinks resolved (so /var and /private/var agree), with a trailing slash so
    /// "/Music" is not taken for a parent of "/Music 2".
    private static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// Forgets a folder added in place, and its tracks. The files themselves are never touched.
    func removeFolder(_ id: Int64) throws {
        guard id != Self.libraryFolderID else { return }
        try database.query("DELETE FROM folders WHERE id = ?", [.integer(id)])
        roots[id] = nil
        scoped.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    var folders: [(id: Int64, name: String)] {
        let rows = (try? database.query("SELECT id, name FROM folders ORDER BY id")) ?? []
        return rows.compactMap { row in row[0].int.map { ($0, row[1].string ?? "") } }
    }

    #if os(macOS)
        private static let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
        private static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
        private static let bookmarkCreation: URL.BookmarkCreationOptions = []
        private static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    #endif

    private func resolveBookmarks() throws {
        let rows = try database.query("SELECT id, bookmark FROM folders WHERE kind = 'bookmark'")
        for row in rows {
            guard let id = row[0].int, let bookmark = row[1].data else { continue }
            var stale = false
            // A folder that cannot be found (deleted, its volume gone) keeps its rows: it may come back.
            guard
                let url = try? URL(
                    resolvingBookmarkData: bookmark, options: Self.bookmarkResolution, relativeTo: nil,
                    bookmarkDataIsStale: &stale)
            else { continue }
            if url.startAccessingSecurityScopedResource() { scoped[id] = url }
            roots[id] = url
            if stale,
                let fresh = try? url.bookmarkData(
                    options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
            {
                try database.query("UPDATE folders SET bookmark = ? WHERE id = ?", [.blob(fresh), .integer(id)])
            }
        }
    }

    // MARK: Scanning

    private struct DiskFile {
        var relativePath: String
        var url: URL
        var size: Int64
        var modified: Double
    }

    private struct KnownTrack {
        var id: String
        var folderID: Int64
        var relativePath: String
        var size: Int64
        var modified: Double
        var contentID: String
        var cloudPending: Bool
    }

    /// What a folder listing found.
    private struct Listing {
        var files: [DiskFile] = []
        /// Relative paths of `.flac` files whose bytes are in iCloud, not on the device.
        var cloudPending: Set<String> = []
        /// False when anything could not be listed or the file cap was reached: then an absent file proves nothing.
        var complete = true
    }

    /// The root folder itself could not be listed.
    private struct FolderUnreadable: Error, CustomStringConvertible {
        var name: String
        var underlying: String
        var description: String { "folder \(name) unreadable: \(underlying)" }
    }

    /// Scans every folder whose location is known. Folders that cannot be found this launch are left as they are.
    ///
    /// Tracks whose file is gone are removed only after every folder has been scanned, so a file moved from one
    /// folder into another is found as a move, and keeps its ID, whichever folder is scanned first. A folder that
    /// cannot be listed, or only in part, removes nothing (`ScanReport.incompleteFolders`).
    func scanAll() throws -> ScanReport {
        var report = ScanReport()
        var gone: [String: KnownTrack] = [:]
        for id in roots.keys.sorted() {
            // One folder's failure (a database error mid-scan) leaves the others to scan; its batches committed so
            // far stand, and it removes nothing.
            do {
                try scan(folder: id, into: &report, gone: &gone)
            } catch {
                report.errors.append(String(describing: error))
            }
        }
        try removeGone(gone, into: &report)
        do { try repairArtwork() } catch { report.errors.append(String(describing: error)) }
        return report
    }

    /// Scans one folder (`scanAll` explains moves and removals).
    func scan(folder: Int64, into report: inout ScanReport) throws {
        var gone: [String: KnownTrack] = [:]
        try scan(folder: folder, into: &report, gone: &gone)
        try removeGone(gone, into: &report)
    }

    /// Removes the tracks whose file is gone, then every cover no track uses any more (gone, refused or re-tagged).
    private func removeGone(_ gone: [String: KnownTrack], into report: inout ScanReport) throws {
        try database.transaction {
            for id in gone.keys.sorted() {
                try delete(id)
                report.removed.append(id)
            }
            try database.query(
                "DELETE FROM artwork WHERE id NOT IN (SELECT artwork_id FROM tracks WHERE artwork_id IS NOT NULL)")
        }
        let keep = Set(try database.query("SELECT id FROM artwork").compactMap { $0[0].string })
        artwork.removeAll(except: keep)
    }

    /// Re-reads only what changed in `folder`: new files and files whose size or modification date differ. A file
    /// found under a new path with the identity of a track whose file is gone (here, or in a folder scanned before in
    /// this pass, `gone`) is that track moved, and keeps its ID. Tracks whose file is gone from this folder are added
    /// to `gone`, unless the listing was incomplete or the file is only evicted to iCloud. A track whose file is now
    /// refused (replaced by something that is not FLAC) is removed at once; one that merely cannot be read now is
    /// left as it is.
    ///
    /// Writes are committed every `batchSize` probed files, and `onBatchCommitted` runs after each commit.
    private func scan(folder: Int64, into report: inout ScanReport, gone: inout [String: KnownTrack]) throws {
        guard let root = roots[folder] else { return }
        let name = root.lastPathComponent
        let listing: Listing
        do {
            listing = try enumerate(root: root, external: folder != Self.libraryFolderID)
        } catch {
            // The library folder before the first import does not exist yet, and holds nothing: not a fault.
            let empty = folder == Self.libraryFolderID && !FileManager.default.fileExists(atPath: root.path)
            if empty, try !knownTracks().contains(where: { $0.folderID == folder }) { return }
            report.incompleteFolders.append(name)
            report.errors.append(String(describing: error))
            return
        }
        if !listing.complete { report.incompleteFolders.append(name) }
        report.pendingDownloads += listing.cloudPending.count
        let disk = listing.files

        let known = try knownTracks()
        let here = Dictionary(known.filter { $0.folderID == folder }.map { ($0.relativePath, $0) }) { a, _ in a }
        let skipped = try skippedFiles(in: folder)
        let onDisk = Set(disk.map(\.relativePath))
        // Gone from this folder: candidates for a move, else removed at the end of the pass. Only a complete listing
        // proves a file gone, and an evicted iCloud file is not gone.
        var missing = gone
        if listing.complete {
            for track in here.values
            where !onDisk.contains(track.relativePath) && !listing.cloudPending.contains(track.relativePath) {
                missing[track.id] = track
            }
        }
        var byContent: [String: [KnownTrack]] = [:]
        for track in known { byContent[track.contentID, default: []].append(track) }

        try database.execute("BEGIN IMMEDIATE")
        do {
            var probedInBatch = 0
            for file in disk {
                if let track = here[file.relativePath], track.size == file.size, track.modified == file.modified {
                    report.unchanged += 1
                    continue
                }
                if let refused = skipped[file.relativePath], refused.size == file.size,
                    refused.modified == file.modified
                {
                    report.unchanged += 1
                    continue
                }
                if probedInBatch >= batchSize {
                    try database.execute("COMMIT")
                    onBatchCommitted?()
                    try database.execute("BEGIN IMMEDIATE")
                    probedInBatch = 0
                }
                probedInBatch += 1
                try scanFile(
                    file, folder: folder, here: here, report: &report, missing: &missing, byContent: &byContent)
            }
            // Cloud-pending marks follow the listing: set for evicted files, cleared once a file is back.
            for track in here.values {
                let pending = listing.cloudPending.contains(track.relativePath)
                let present = onDisk.contains(track.relativePath)
                guard pending != track.cloudPending, pending || present else { continue }
                try database.query(
                    "UPDATE tracks SET cloud_pending = ? WHERE id = ?", [.integer(pending ? 1 : 0), .text(track.id)])
                report.cloudChanged.append(track.id)
            }
            if listing.complete {
                try database.query(
                    "DELETE FROM skipped WHERE folder_id = ? AND rel_path NOT IN (SELECT value FROM json_each(?))",
                    [.integer(folder), .text(Self.jsonArray(onDisk))])
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        gone = missing
    }

    /// Reads one new or changed file and records what it is.
    private func scanFile(
        _ file: DiskFile, folder: Int64, here: [String: KnownTrack], report: inout ScanReport,
        missing: inout [String: KnownTrack], byContent: inout [String: [KnownTrack]]
    ) throws {
        let previous = here[file.relativePath]
        let probed: ProbedTrack
        if file.size > maxFileBytes {
            try refuse(
                file, previous: previous, folder: folder, reason: "Too large to add", report: &report,
                byContent: &byContent)
            return
        }
        probes += 1
        switch probe(file.url, external: folder != Self.libraryFolderID) {
        case .success(let value):
            probed = value
        case .failure(.unreadable):
            // Transient (data protection while locked, a provider that failed): not remembered, nothing removed.
            report.unreadable.append(file.relativePath)
            return
        case .failure(let rejection):
            try refuse(
                file, previous: previous, folder: folder, reason: Self.describe(rejection), report: &report,
                byContent: &byContent)
            return
        }
        try database.query(
            "DELETE FROM skipped WHERE folder_id = ? AND rel_path = ?", [.integer(folder), .text(file.relativePath)])

        if let previous, previous.contentID == probed.contentID {
            // The same audio, read again: tags edited, say. Keeps its ID.
            try write(probed, id: previous.id, file: file, folder: folder, insert: false)
            report.updated.append(previous.id)
            return
        }
        if let previous {
            // The file at this path is a different recording now: the old track is gone.
            try delete(previous.id)
            report.removed.append(previous.id)
            missing[previous.id] = nil
            byContent[previous.contentID]?.removeAll { $0.id == previous.id }
        }
        let sameAudio = byContent[probed.contentID] ?? []
        if let moved = sameAudio.first(where: { missing[$0.id] != nil || !exists($0) }) {
            try write(probed, id: moved.id, file: file, folder: folder, insert: false)
            missing[moved.id] = nil
            report.moved.append(moved.id)
            return
        }
        // New. A bit-identical copy of a track that is still there gets an ID from its location, so both stay in the
        // library (an album and a compilation can share a rip).
        let id =
            sameAudio.isEmpty
            ? probed.contentID
            : StableHash.hex(of: Array("\(probed.contentID)\u{1F}\(folder)\u{1F}\(file.relativePath)".utf8))
        try write(probed, id: id, file: file, folder: folder, insert: true)
        byContent[probed.contentID, default: []].append(
            KnownTrack(
                id: id, folderID: folder, relativePath: file.relativePath, size: file.size, modified: file.modified,
                contentID: probed.contentID, cloudPending: false))
        report.added.append(id)
    }

    /// Remembers `file` as refused, and removes the track that was there: it was music and is not any more.
    private func refuse(
        _ file: DiskFile, previous: KnownTrack?, folder: Int64, reason: String, report: inout ScanReport,
        byContent: inout [String: [KnownTrack]]
    ) throws {
        try skip(file, in: folder, reason: reason, report: &report)
        if let previous {
            try delete(previous.id)
            report.removed.append(previous.id)
            byContent[previous.contentID]?.removeAll { $0.id == previous.id }
        }
    }

    /// Regenerates every stored cover whose file has gone (deleted by hand, or a restore without it) from the first
    /// track that uses it. Covers that cannot be regenerated are dropped from their tracks.
    func repairArtwork() throws {
        let rows = try database.query(
            """
            SELECT a.id, t.folder_id, t.rel_path FROM artwork a JOIN tracks t ON t.artwork_id = a.id
            GROUP BY a.id
            """)
        for row in rows {
            guard let id = row[0].string, !artwork.exists(id), let folder = row[1].int, let root = roots[folder],
                let path = row[2].string
            else { continue }
            let url = root.appending(path: path)
            if let cover = FlacProbe.cover(fileAt: url), artwork.store(cover) == id { continue }
            try database.query("UPDATE tracks SET artwork_id = NULL WHERE artwork_id = ?", [.text(id)])
            try database.query("DELETE FROM artwork WHERE id = ?", [.text(id)])
        }
    }

    /// Whether a known track's file is still where the database says.
    private func exists(_ track: KnownTrack) -> Bool {
        guard let root = roots[track.folderID] else { return true }  // Unknown this launch: assume it is still there.
        return FileManager.default.fileExists(atPath: root.appending(path: track.relativePath).path)
    }

    private func probe(_ url: URL, external: Bool) -> Result<ProbedTrack, FlacRejection> {
        guard external else { return FlacProbe.probe(fileAt: url) }
        // A file provider's folder: read under coordination, so the provider can fetch or lock the file.
        var result: Result<ProbedTrack, FlacRejection> = .failure(.unreadable)
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error)
        {
            result = FlacProbe.probe(fileAt: $0)
        }
        return error == nil ? result : .failure(.unreadable)
    }

    private func skip(_ file: DiskFile, in folder: Int64, reason: String, report: inout ScanReport) throws {
        try database.query(
            "INSERT OR REPLACE INTO skipped(folder_id, rel_path, size, mtime, reason) VALUES (?, ?, ?, ?, ?)",
            [.integer(folder), .text(file.relativePath), .integer(file.size), .real(file.modified), .text(reason)])
        report.rejected[file.relativePath] = reason
    }

    private func write(_ probed: ProbedTrack, id: String, file: DiskFile, folder: Int64, insert: Bool) throws {
        let stem = ((file.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let title = probed.title ?? TagText.clean(stem) ?? "Untitled"
        let folderKey = "\(folder)/\((file.relativePath as NSString).deletingLastPathComponent)"
        let albumID = AlbumGrouping.albumID(
            albumArtist: probed.albumArtist, artist: probed.artist, album: probed.album,
            compilation: probed.compilation, folder: folderKey)
        var artworkID: String?
        if let cover = probed.cover, let stored = artwork.store(cover) {
            try database.query(
                "INSERT OR IGNORE INTO artwork(id, bytes) VALUES (?, ?)", [.text(stored), .integer(Int64(cover.count))])
            artworkID = stored
        }
        let values: [SQLValue] = [
            .integer(folder), .text(file.relativePath), .integer(file.size), .real(file.modified),
            .text(probed.contentID), .text(title), .text(probed.artist), .text(probed.albumArtist), .text(probed.album),
            .optional(probed.discNumber), .optional(probed.trackNumber), .optional(probed.year),
            .integer(Int64(probed.format.sampleRate)), .integer(Int64(probed.format.bitsPerSample)),
            .integer(Int64(probed.format.channels)), .integer(probed.totalFrames), .text(albumID),
            .optional(artworkID),
        ]
        if insert {
            try database.query(
                """
                INSERT INTO tracks(folder_id, rel_path, size, mtime, content_id, title, artist, album_artist, album,
                    disc, track, year, sample_rate, bits, channels, total_frames, album_id, artwork_id, added_at, id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [.real(Date().timeIntervalSince1970), .text(id)])
        } else {
            try database.query(
                """
                UPDATE tracks SET folder_id = ?, rel_path = ?, size = ?, mtime = ?, content_id = ?, title = ?,
                    artist = ?, album_artist = ?, album = ?, disc = ?, track = ?, year = ?, sample_rate = ?, bits = ?,
                    channels = ?, total_frames = ?, album_id = ?, artwork_id = ?
                WHERE id = ?
                """, values + [.text(id)])
        }
    }

    /// The track at `relativePath` in `folder`, if any.
    func trackID(folder: Int64, relativePath: String) throws -> String? {
        try database.query(
            "SELECT id FROM tracks WHERE folder_id = ? AND rel_path = ?", [.integer(folder), .text(relativePath)]
        ).first?.first?.string
    }

    private func delete(_ id: String) throws {
        try database.query("DELETE FROM tracks WHERE id = ?", [.text(id)])
    }

    private func knownTracks() throws -> [KnownTrack] {
        try database.query("SELECT id, folder_id, rel_path, size, mtime, content_id, cloud_pending FROM tracks")
            .compactMap { row in
                guard let id = row[0].string, let folder = row[1].int, let path = row[2].string, let size = row[3].int,
                    let modified = row[4].double, let content = row[5].string
                else { return nil }
                return KnownTrack(
                    id: id, folderID: folder, relativePath: path, size: size, modified: modified, contentID: content,
                    cloudPending: row[6].int == 1)
            }
    }

    private func skippedFiles(in folder: Int64) throws -> [String: (size: Int64, modified: Double)] {
        var result: [String: (size: Int64, modified: Double)] = [:]
        for row in try database.query(
            "SELECT rel_path, size, mtime FROM skipped WHERE folder_id = ?", [.integer(folder)])
        {
            guard let path = row[0].string, let size = row[1].int, let modified = row[2].double else { continue }
            result[path] = (size, modified)
        }
        return result
    }

    /// The `.flac` files under `root` (not hidden, not inside hidden folders or packages), with size and date, and the
    /// iCloud files still to download (whose download is started here). Only names and attributes are read, never file
    /// contents.
    ///
    /// Throws when `root` itself cannot be listed (missing, offline provider, no security scope). Any error below the
    /// root, or reaching `maxFilesPerFolder`, marks the listing incomplete, so the scan removes nothing from it.
    private func enumerate(root: URL, external: Bool) throws -> Listing {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            throw FolderUnreadable(name: root.lastPathComponent, underlying: (error as NSError).localizedDescription)
        }
        var listing = Listing()
        var failed = false
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [],
                errorHandler: { _, _ in
                    failed = true
                    return true
                })
        else { throw FolderUnreadable(name: root.lastPathComponent, underlying: "no enumerator") }
        while let url = enumerator.nextObject() as? URL {
            // The enumerator may resolve symlinks in the root (/var → /private/var), so the relative path is taken
            // from the item's depth below the root, not from a string prefix.
            let components = url.pathComponents
            let depth = enumerator.level
            guard depth >= 1, components.count >= depth else { continue }
            let relative = components.suffix(depth).joined(separator: "/")
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if name.hasPrefix(".") || name.hasSuffix(".app") || name.hasSuffix(".bundle") {
                    enumerator.skipDescendants()
                }
                continue
            }
            if name.hasPrefix(".") {
                // "._Song.flac" AppleDouble files and other hidden names are never music. ".Song.flac.icloud" is an
                // iCloud placeholder for "Song.flac": start its download, and a later scan reads it.
                let placeholder = name.dropFirst().dropLast(".icloud".count)
                if name.hasSuffix(".icloud"), placeholder.lowercased().hasSuffix(".flac"), !placeholder.hasPrefix(".") {
                    let directory = (relative as NSString).deletingLastPathComponent
                    let real = directory.isEmpty ? String(placeholder) : "\(directory)/\(placeholder)"
                    listing.cloudPending.insert(real)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: root.appending(path: real))
                }
                continue
            }
            guard values?.isRegularFile == true, name.lowercased().hasSuffix(".flac") else { continue }
            if external, Self.isNotDownloaded(url) {
                listing.cloudPending.insert(relative)
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            listing.files.append(
                DiskFile(relativePath: relative, url: root.appending(path: relative), size: size, modified: modified))
            if listing.files.count >= maxFilesPerFolder {
                failed = true
                break
            }
        }
        listing.files.sort { $0.relativePath < $1.relativePath }
        listing.complete = !failed
        return listing
    }

    /// An iCloud file whose bytes are not on the device. Reading it would block on the download.
    private static func isNotDownloaded(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
            values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus
        else { return false }
        return status != .current && status != .downloaded
    }

    // MARK: Reading

    /// Every track whose folder can be found this launch, as the catalog the UI and search see.
    func catalog() throws -> LibraryCatalog {
        let rows = try database.query(
            """
            SELECT id, folder_id, rel_path, title, artist, album_artist, album, disc, track, year, sample_rate, bits,
                channels, total_frames, album_id, artwork_id, cloud_pending FROM tracks
            """)
        var tracks: [LibraryTrack] = []
        tracks.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row[0].string, let folder = row[1].int, let root = roots[folder], let path = row[2].string
            else { continue }
            tracks.append(
                LibraryTrack(
                    id: id, url: root.appending(path: path), title: row[3].string ?? "", artist: row[4].string ?? "",
                    albumArtist: row[5].string ?? "", album: row[6].string ?? "", albumID: row[14].string ?? "",
                    discNumber: row[7].int.map(Int.init), trackNumber: row[8].int.map(Int.init),
                    year: row[9].int.map(Int.init),
                    format: AudioFormat(
                        sampleRate: Int(row[10].int ?? 0), bitsPerSample: Int(row[11].int ?? 0),
                        channels: Int(row[12].int ?? 0)),
                    totalFrames: row[13].int ?? 0, artworkID: row[15].string, isCloudPending: row[16].int == 1))
        }
        return LibraryCatalog(tracks: tracks)
    }

    private static func describe(_ rejection: FlacRejection) -> String {
        switch rejection {
        case .badMagic: "Not a FLAC file"
        case .notFlacName: "Only .flac files can be added"
        case .unreadable: "Could not be read"
        default: "Damaged or incomplete FLAC"
        }
    }

    private static func jsonArray(_ strings: Set<String>) -> String {
        (try? String(data: JSONEncoder().encode(Array(strings)), encoding: .utf8)) ?? "[]"
    }
}
