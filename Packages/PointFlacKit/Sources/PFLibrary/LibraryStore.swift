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
    /// iCloud files not yet downloaded. Their download has been started; a later scan adds them.
    public var pendingDownloads = 0

    public init() {}
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
    /// A scan reads no more than this many files per folder: a bound on a hostile or mistaken folder pick.
    static let maxFilesPerFolder = 250_000

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
        """
    ]

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
    func addFolder(_ url: URL) throws -> Int64 {
        let scopedNow = url.startAccessingSecurityScopedResource()
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            if scopedNow { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        if let existing = roots.first(where: { $0.value.standardizedFileURL == url.standardizedFileURL })?.key {
            if scopedNow { url.stopAccessingSecurityScopedResource() }
            return existing
        }
        try database.query(
            "INSERT INTO folders(kind, bookmark, name, added_at) VALUES ('bookmark', ?, ?, ?)",
            [.blob(bookmark), .text(url.lastPathComponent), .real(Date().timeIntervalSince1970)])
        guard let id = try database.query("SELECT last_insert_rowid()").first?.first?.int else {
            throw LibraryDatabaseError(code: 0, message: "no folder id")
        }
        roots[id] = url
        if scopedNow { scoped[id] = url }
        return id
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
    }

    /// Scans every folder whose location is known. Folders that cannot be found this launch are left as they are.
    ///
    /// Tracks whose file is gone are removed only after every folder has been scanned, so a file moved from one
    /// folder into another is found as a move, and keeps its ID, whichever folder is scanned first.
    func scanAll() throws -> ScanReport {
        var report = ScanReport()
        var gone: [String: KnownTrack] = [:]
        for id in roots.keys.sorted() {
            try scan(folder: id, into: &report, gone: &gone)
        }
        try removeGone(gone, into: &report)
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
    /// to `gone`. A track whose file is now refused (replaced by something that is not FLAC) is removed at once.
    private func scan(folder: Int64, into report: inout ScanReport, gone: inout [String: KnownTrack]) throws {
        guard let root = roots[folder] else { return }
        let (disk, pending) = enumerate(root: root, external: folder != Self.libraryFolderID)
        report.pendingDownloads += pending

        let known = try knownTracks()
        let here = Dictionary(known.filter { $0.folderID == folder }.map { ($0.relativePath, $0) }) { a, _ in a }
        let skipped = try skippedFiles(in: folder)
        let onDisk = Set(disk.map(\.relativePath))
        // Gone from this folder: candidates for a move, else removed at the end of the pass.
        var missing = gone
        for track in here.values where !onDisk.contains(track.relativePath) { missing[track.id] = track }
        var byContent: [String: [KnownTrack]] = [:]
        for track in known { byContent[track.contentID, default: []].append(track) }

        try database.transaction {
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
                let refusal: String?
                var probed: ProbedTrack?
                if file.size > maxFileBytes {
                    refusal = "Too large to add"
                } else {
                    probes += 1
                    switch probe(file.url, external: folder != Self.libraryFolderID) {
                    case .success(let value):
                        probed = value
                        refusal = nil
                    case .failure(let rejection):
                        refusal = Self.describe(rejection)
                    }
                }
                guard let probed else {
                    try skip(file, in: folder, reason: refusal ?? "Could not be read", report: &report)
                    if let previous = here[file.relativePath] {
                        // It was music and is not any more: the track goes, never pointing at a refused file.
                        try delete(previous.id)
                        report.removed.append(previous.id)
                        byContent[previous.contentID]?.removeAll { $0.id == previous.id }
                    }
                    continue
                }
                try database.query(
                    "DELETE FROM skipped WHERE folder_id = ? AND rel_path = ?",
                    [.integer(folder), .text(file.relativePath)])

                let previous = here[file.relativePath]
                if let previous, previous.contentID == probed.contentID {
                    // The same audio, read again: tags edited, say. Keeps its ID.
                    try write(probed, id: previous.id, file: file, folder: folder, insert: false)
                    report.updated.append(previous.id)
                    continue
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
                    continue
                }
                // New. A bit-identical copy of a track that is still there gets an ID from its location, so both
                // stay in the library (an album and a compilation can share a rip).
                let id =
                    sameAudio.isEmpty
                    ? probed.contentID
                    : StableHash.hex(of: Array("\(probed.contentID)\u{1F}\(folder)\u{1F}\(file.relativePath)".utf8))
                try write(probed, id: id, file: file, folder: folder, insert: true)
                byContent[probed.contentID, default: []].append(
                    KnownTrack(
                        id: id, folderID: folder, relativePath: file.relativePath, size: file.size,
                        modified: file.modified, contentID: probed.contentID))
                report.added.append(id)
            }
            try database.query(
                "DELETE FROM skipped WHERE folder_id = ? AND rel_path NOT IN (SELECT value FROM json_each(?))",
                [.integer(folder), .text(Self.jsonArray(onDisk))])
        }
        gone = missing
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
        let title =
            probed.title ?? ((file.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
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
        try database.query("SELECT id, folder_id, rel_path, size, mtime, content_id FROM tracks").compactMap { row in
            guard let id = row[0].string, let folder = row[1].int, let path = row[2].string, let size = row[3].int,
                let modified = row[4].double, let content = row[5].string
            else { return nil }
            return KnownTrack(
                id: id, folderID: folder, relativePath: path, size: size, modified: modified, contentID: content)
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

    /// The `.flac` files under `root` (not hidden, not inside hidden folders or packages), with size and date, and how
    /// many iCloud files are still to download. Only names and attributes are read here, never file contents.
    private func enumerate(root: URL, external: Bool) -> (files: [DiskFile], pending: Int) {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return ([], 0) }
        var files: [DiskFile] = []
        var pending = 0
        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            let attributes = enumerator.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            if type == .typeDirectory {
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
                    pending += 1
                    let real = root.appending(path: (relative as NSString).deletingLastPathComponent)
                        .appending(path: String(placeholder))
                    try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                }
                continue
            }
            guard type == .typeRegular, name.lowercased().hasSuffix(".flac") else { continue }
            let url = root.appending(path: relative)
            if external, Self.isNotDownloaded(url) {
                pending += 1
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            files.append(DiskFile(relativePath: relative, url: url, size: size, modified: modified))
            if files.count >= Self.maxFilesPerFolder { break }
        }
        return (files.sorted { $0.relativePath < $1.relativePath }, pending)
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
                channels, total_frames, album_id, artwork_id FROM tracks
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
                    totalFrames: row[13].int ?? 0, artworkID: row[15].string))
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
