import Foundation
import PFCore
import PFTestSupport
import Testing

@testable import PFLibrary

/// Fix round 1: what must never cost the user tracks (unreadable folders, iCloud eviction, transient read errors), and
/// what must never be lost silently (database errors, scan progress, covers).
private final class Sandbox {
    let root: URL
    var libraryFolder: URL { root.appending(path: "Documents/Library", directoryHint: .isDirectory) }
    var database: URL { root.appending(path: "Support/library.sqlite") }
    var artwork: URL { root.appending(path: "Support/Artwork", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "LibraryRobustness-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Tests make files and folders unreadable; make everything removable again.
        if let paths = FileManager.default.subpaths(atPath: root.path) {
            for path in paths {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: root.appending(path: path).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func open() throws -> Library {
        try Library(databaseURL: database, libraryFolder: libraryFolder, artworkFolder: artwork)
    }

    /// Writes distinct tagged FLAC files (one fixture each, so each has its own identity) into `folder`.
    func fill(_ folder: URL, count: Int, prefix: String = "t") throws -> [URL] {
        let fixtures = [
            "s16-44100", "s16-48000", "s24-44100", "s24-48000", "s24-88200", "s24-96000", "s24-176400", "s24-192000",
            "s32-44100", "s32-48000", "s32-96000", "s32-192000",
        ]
        return try (0..<count).map { i in
            let url = folder.appending(path: "\(prefix)\(i).flac")
            try TaggedFlac.write(fixtures[i], to: url, tags: [("TITLE", "\(prefix)\(i)"), ("ALBUM", "A")])
            return url
        }
    }
}

// MARK: 1. Unreadable or partial folders remove nothing

@Test func aMissingFolderRemovesNothing() async throws {
    let box = try Sandbox()
    let library = try box.open()
    let external = box.root.appending(path: "Drive", directoryHint: .isDirectory)
    _ = try box.fill(external, count: 3)
    _ = try await library.addFolder(external)
    #expect(library.current.tracks.count == 3)

    // The drive is unplugged (or its provider is offline): the folder cannot be listed.
    try FileManager.default.moveItem(at: external, to: box.root.appending(path: "Unplugged"))
    let report = await library.rescan()

    #expect(report.removed.isEmpty)
    #expect(report.incompleteFolders == ["Drive"])
    #expect(!report.errors.isEmpty)
    #expect(library.current.tracks.count == 3)

    // It comes back: everything is still there, unchanged.
    try FileManager.default.moveItem(at: box.root.appending(path: "Unplugged"), to: external)
    let back = await library.rescan()
    #expect(back.incompleteFolders.isEmpty && back.unchanged == 3 && back.removed.isEmpty)
}

@Test func anUnreadableSubfolderRemovesNothing() async throws {
    let box = try Sandbox()
    let library = try box.open()
    let sub = box.libraryFolder.appending(path: "Locked", directoryHint: .isDirectory)
    _ = try box.fill(sub, count: 2)
    _ = try box.fill(box.libraryFolder, count: 1, prefix: "top")
    await library.rescan()
    #expect(library.current.tracks.count == 3)

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sub.path)
    let report = await library.rescan()
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path)

    #expect(report.removed.isEmpty)
    #expect(report.incompleteFolders == ["Library"])
    #expect(library.current.tracks.count == 3)
}

@Test func reachingTheFileCapRemovesNothing() async throws {
    let box = try Sandbox()
    let library = try box.open()
    _ = try box.fill(box.libraryFolder, count: 4)
    await library.rescan()
    await library.setMaxFilesPerFolder(2)

    let report = await library.rescan()

    #expect(report.removed.isEmpty)
    #expect(report.incompleteFolders == ["Library"])
    #expect(library.current.tracks.count == 4)
}

// MARK: 2. iCloud eviction keeps the track, marked

@Test func anEvictedFileStaysMarkedCloudPending() async throws {
    let box = try Sandbox()
    let library = try box.open()
    let urls = try box.fill(box.libraryFolder, count: 2)
    await library.rescan()
    let id = try #require(library.current.tracks.values.first { $0.title == "t0" }?.id)

    // iCloud evicts t0.flac: the file is replaced by its hidden ".t0.flac.icloud" placeholder.
    let saved = box.root.appending(path: "saved.flac")
    try FileManager.default.moveItem(at: urls[0], to: saved)
    try Data("placeholder".utf8).write(to: box.libraryFolder.appending(path: ".t0.flac.icloud"))
    let evicted = await library.rescan()

    #expect(evicted.removed.isEmpty)
    #expect(evicted.cloudChanged == [id] && evicted.pendingDownloads == 1)
    #expect(library.current.tracks[id]?.isCloudPending == true)
    #expect(library.current.tracks.count == 2)

    // Downloaded again: the mark clears, and the track is the same one.
    try FileManager.default.removeItem(at: box.libraryFolder.appending(path: ".t0.flac.icloud"))
    try FileManager.default.moveItem(at: saved, to: urls[0])
    let back = await library.rescan()
    #expect(back.cloudChanged == [id] && back.removed.isEmpty && back.added.isEmpty)
    #expect(library.current.tracks[id]?.isCloudPending == false)
}

// MARK: 3. Batches commit and publish as they go

@Test func scansCommitAndPublishInBatches() throws {
    let box = try Sandbox()
    _ = try box.fill(box.libraryFolder, count: 7)
    let store = try LibraryStore(
        databaseURL: box.database, libraryFolder: box.libraryFolder, artworkFolder: box.artwork,
        maxFileBytes: ImportInbox.defaultMaxFileBytes)
    store.batchSize = 3
    var committed: [Int] = []
    store.onBatchCommitted = {
        // A second connection sees each batch as soon as it is committed: a scan killed now keeps it.
        let reader = try? SQLiteDatabase(url: box.database)
        let count = (try? reader?.query("SELECT COUNT(*) FROM tracks"))??.first?.first?.int ?? -1
        committed.append(Int(count))
    }
    var report = ScanReport()
    try store.scan(folder: LibraryStore.libraryFolderID, into: &report)

    #expect(committed == [3, 6])
    #expect(report.added.count == 7)
    #expect(try store.catalog().tracks.count == 7)
}

@Test func theShelfFillsInDuringAScan() async throws {
    let box = try Sandbox()
    _ = try box.fill(box.libraryFolder, count: 6)
    let library = try box.open()
    await library.setBatchSize(2)
    let before = library.publishCount

    await library.rescan()

    // Two committed batches of two published on the way, then the end of the scan: three catalogs, not one.
    #expect(library.publishCount - before == 3)
    #expect(library.current.tracks.count == 6)
}

// MARK: 4. Database errors surface

@Test func databaseErrorsAreReportedNotSwallowed() async throws {
    let box = try Sandbox()
    let library = try box.open()
    _ = try box.fill(box.libraryFolder, count: 1)
    // Something breaks the database under the library (here: another connection drops a table it needs).
    let saboteur = try SQLiteDatabase(url: box.database)
    try saboteur.execute("DROP TABLE skipped")

    let report = await library.rescan()
    #expect(!report.errors.isEmpty)

    let picked = box.root.appending(path: "Picked/new.flac")
    try TaggedFlac.write("s24-96000", to: picked, tags: [("TITLE", "New")])
    let result = await library.importFiles([picked])
    #expect(result.error != nil)
    #expect(result.added.isEmpty)
}

// MARK: 5. Transient read failures are not remembered

@Test func unreadableFilesAreRetriedAndKeepTheirTrack() async throws {
    let box = try Sandbox()
    let library = try box.open()
    let urls = try box.fill(box.libraryFolder, count: 2)
    let locked = box.libraryFolder.appending(path: "locked.flac")
    try TaggedFlac.write("s32-48000", to: locked, tags: [("TITLE", "Locked")])
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

    let first = await library.rescan()
    #expect(first.unreadable == ["locked.flac"] && first.rejected.isEmpty && first.added.count == 2)

    // Readable again (the device unlocked): read and added, because it was never remembered as refused.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
    let second = await library.rescan()
    #expect(second.added.count == 1 && library.current.tracks.count == 3)

    // A known track whose file turns unreadable (and changed) stays as it is.
    let id = try #require(library.current.tracks.values.first { $0.title == "t0" }?.id)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o000, .modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: urls[0].path)
    let third = await library.rescan()
    #expect(third.unreadable == ["t0.flac"] && third.removed.isEmpty)
    #expect(library.current.tracks[id] != nil)
}

// MARK: 6. Cover reads stay bounded

@Test func coverReadsStayBoundedWithManyLargePictures() throws {
    let box = try Sandbox()
    let url = box.root.appending(path: "pictures.flac")
    var big = Data(count: 1 << 20)
    big[0] = 1
    // Twenty 1 MiB pictures, none of them a front cover.
    try TaggedFlac.make(from: "s16-44100", tags: [], picture: big, pictureType: 4, extraPictures: 19).write(to: url)
    let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(size > 20 << 20)

    var bytesRead = 0
    let cover = FlacProbe.cover(fileAt: url, bytesRead: &bytesRead)

    #expect(cover == big)  // the first picture, as the fallback
    #expect(bytesRead < (1 << 20) + 4096, "read \(bytesRead) of \(size) bytes")
}

// MARK: 7. changes() never ends on a stale catalog

@Test func subscribersAlwaysEndOnTheLatestCatalog() async throws {
    let box = try Sandbox()
    let library = try box.open()
    let folder = box.libraryFolder
    let streams = await withTaskGroup(of: [AsyncStream<LibraryCatalog>].self) { group in
        group.addTask {
            for i in 0..<8 {
                try? TaggedFlac.write(
                    [
                        "s16-44100", "s16-48000", "s24-44100", "s24-48000", "s24-88200", "s24-96000", "s32-44100",
                        "s32-48000",
                    ][i], to: folder.appending(path: "\(i).flac"), tags: [])
                await library.rescan()
            }
            return []
        }
        for _ in 0..<4 {
            group.addTask {
                var made: [AsyncStream<LibraryCatalog>] = []
                for _ in 0..<50 {
                    made.append(library.changes())
                    await Task.yield()
                }
                return made
            }
        }
        var all: [AsyncStream<LibraryCatalog>] = []
        for await made in group { all += made }
        return all
    }
    let final = library.current.tracks.count
    #expect(final == 8)
    for stream in streams {
        var iterator = stream.makeAsyncIterator()
        // Newest-only buffering: what is waiting is the last catalog this stream was given.
        #expect(await iterator.next()?.tracks.count == final)
    }
}

// MARK: 8. Artwork

@Test func artworkMayNotLiveInCaches() throws {
    let box = try Sandbox()
    let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
    #expect(throws: LibraryError.artworkFolderInCaches) {
        try Library(
            databaseURL: box.database, libraryFolder: box.libraryFolder,
            artworkFolder: caches.appending(path: "pointflac-test-artwork-\(UUID().uuidString)"))
    }
}

@Test func aMissingCoverFileIsRegenerated() async throws {
    let box = try Sandbox()
    try TaggedFlac.write(
        "s16-44100", to: box.libraryFolder.appending(path: "c.flac"), tags: [("TITLE", "C")],
        picture: TaggedFlac.png(size: 300))
    let artworkID: String
    do {
        let library = try box.open()
        await library.rescan()
        artworkID = try #require(library.current.albums.first?.artworkID)
    }
    try FileManager.default.removeItem(at: box.artwork.appending(path: "\(artworkID).jpg"))

    // A fresh launch, so no memory cache: the first read misses and schedules the repair.
    let library = try box.open()
    #expect(library.artwork(artworkID) == nil)
    await library.barrier()
    #expect(library.artwork(artworkID) != nil)

    // A rescan repairs too.
    try FileManager.default.removeItem(at: box.artwork.appending(path: "\(artworkID).jpg"))
    await library.rescan()
    #expect(FileManager.default.fileExists(atPath: box.artwork.appending(path: "\(artworkID).jpg").path))
}

@Test func artworkBoundsRefuseHugeImages() {
    // Over the byte bound: refused before ImageIO sees it.
    let store = ArtworkStore(folder: FileManager.default.temporaryDirectory.appending(path: "art-\(UUID().uuidString)"))
    #expect(store.store(Data(count: ArtworkStore.maxSourceBytes + 1)) == nil)
    // A PNG whose header claims 7000 × 7000 (49 Mpx): refused from the header, never decoded.
    #expect(ArtworkStore.downsample(PNGHeader.claiming(width: 7_000, height: 7_000)) == nil)
    #expect(ArtworkStore.maxSourcePixels <= 36_000_000)
    // A real, small image passes.
    #expect(ArtworkStore.downsample(TaggedFlac.png(size: 32)) != nil)
}

/// A PNG with only a signature, an IHDR claiming `width` × `height`, and IEND.
enum PNGHeader {
    static func claiming(width: Int, height: Int) -> Data {
        func be32(_ n: Int) -> [UInt8] {
            [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return be32(body.count) + typed + be32(Int(crc32(typed)))
        }
        let ihdr = be32(width) + be32(height) + [8, 2, 0, 0, 0]
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IEND", [])
        return Data(bytes)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

// MARK: 10. Minors

@Test func overlappingFoldersAreRefused() async throws {
    let box = try Sandbox()
    let library = try box.open()
    try FileManager.default.createDirectory(
        at: box.libraryFolder.appending(path: "Inside"), withIntermediateDirectories: true)
    let outside = box.root.appending(path: "Music", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside.appending(path: "Child"), withIntermediateDirectories: true)
    let sibling = box.root.appending(path: "Music 2", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

    await #expect(throws: LibraryError.self) {
        try await library.addFolder(box.libraryFolder.appending(path: "Inside"))
    }
    await #expect(throws: LibraryError.self) { try await library.addFolder(box.root.appending(path: "Documents")) }
    _ = try await library.addFolder(outside)
    await #expect(throws: LibraryError.self) { try await library.addFolder(outside.appending(path: "Child")) }
    await #expect(throws: LibraryError.self) { try await library.addFolder(box.root) }
    // "Music 2" is not inside "Music".
    _ = try await library.addFolder(sibling)
    #expect(await library.folders().count == 3)
}

@Test func fileNameTitlesAreCleanedAndYearsRangeChecked() async throws {
    let box = try Sandbox()
    let library = try box.open()
    try TaggedFlac.write(
        "s16-44100", to: box.libraryFolder.appending(path: "  Spaced\tName  .flac"), tags: [("DATE", "0000")])
    try TaggedFlac.write(
        "s16-48000", to: box.libraryFolder.appending(path: "b.flac"), tags: [("TITLE", "B"), ("DATE", "2101")])
    try TaggedFlac.write(
        "s24-44100", to: box.libraryFolder.appending(path: "c.flac"), tags: [("TITLE", "C"), ("DATE", "1999-05-01")])
    await library.rescan()
    let byTitle = Dictionary(uniqueKeysWithValues: library.current.tracks.values.map { ($0.title, $0) })
    #expect(Set(byTitle.keys) == ["Spaced Name", "B", "C"])
    #expect(byTitle["Spaced Name"]?.year == nil && byTitle["B"]?.year == nil && byTitle["C"]?.year == 1999)
}

@Test func aNoOpRescanPublishesNothing() async throws {
    let box = try Sandbox()
    let library = try box.open()
    var iterator = library.changes().makeAsyncIterator()
    #expect(await iterator.next()?.tracks.count == 0)
    let quiet = await library.rescan()
    #expect(quiet.changedNothing)
    _ = try box.fill(box.libraryFolder, count: 1)
    await library.rescan()
    // Had the no-op rescan published, this would be its empty catalog.
    #expect(await iterator.next()?.tracks.count == 1)
}
