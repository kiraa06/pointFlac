import Foundation
import PFCore
import PFTestSupport
import Synchronization
import Testing

@testable import PFLibrary

private final class ListenSandbox {
    let root: URL
    var libraryFolder: URL { root.appending(path: "Documents/Library", directoryHint: .isDirectory) }
    var database: URL { root.appending(path: "Support/library.sqlite") }
    var artwork: URL { root.appending(path: "Support/Artwork", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ListenStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func open() throws -> Library {
        try Library(databaseURL: database, libraryFolder: libraryFolder, artworkFolder: artwork)
    }
}

/// Whole seconds, because the database stores `Date` as a REAL and a round trip must compare equal.
private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func recordListenCountsAndPersists() async throws {
    let box = try ListenSandbox()
    var library: Library? = try box.open()
    let first = await library?.recordListen(trackID: "t1", at: at(1_000))
    #expect(first == ListenStat(count: 1, lastAt: at(1_000)))
    let second = await library?.recordListen(trackID: "t1", at: at(2_000))
    #expect(second == ListenStat(count: 2, lastAt: at(2_000)))
    _ = await library?.recordListen(trackID: "t2", at: at(1_500))
    await library?.barrier()
    library = nil

    let reopened = try box.open()
    let stats = await reopened.listenStats()
    #expect(stats == ["t1": ListenStat(count: 2, lastAt: at(2_000)), "t2": ListenStat(count: 1, lastAt: at(1_500))])
}

@Test func listensDoNotPublishACatalog() async throws {
    let box = try ListenSandbox()
    let library = try box.open()
    let seen = Mutex(0)
    let reader = Task {
        for await _ in library.changes() { seen.withLock { $0 += 1 } }
    }
    defer { reader.cancel() }
    // The stream starts with the current catalog.
    while seen.withLock({ $0 }) < 1 { try await Task.sleep(for: .milliseconds(5)) }

    _ = await library.recordListen(trackID: "t1", at: at(1))
    await library.barrier()
    try await Task.sleep(for: .milliseconds(100))

    #expect(seen.withLock { $0 } == 1)
}

@Test func migrationFromV4KeepsTracks() throws {
    let box = try ListenSandbox()
    try FileManager.default.createDirectory(
        at: box.database.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = try SQLiteDatabase(url: box.database)
    try old.migrate(Array(LibraryStore.migrations.prefix(4)))
    try old.query("INSERT INTO folders(id, kind, name, added_at) VALUES (1, 'library', 'Library', 0)")
    try old.query(
        """
        INSERT INTO tracks(id, folder_id, rel_path, size, mtime, content_id, title, artist, album_artist, album,
            sample_rate, bits, channels, total_frames, album_id, added_at)
        VALUES ('kept', 1, 'kept.flac', 1, 1, 'c', 'Kept', '', '', '', 44100, 16, 2, 0, 'a', 42)
        """)
    #expect(old.userVersion == 4)

    let store = try LibraryStore(
        databaseURL: box.database, libraryFolder: box.libraryFolder, artworkFolder: box.artwork, maxFileBytes: 1 << 30)

    #expect(store.database.userVersion == LibraryStore.migrations.count)
    #expect(LibraryStore.migrations.count == 5)
    #expect(try store.database.query("SELECT id FROM tracks").count == 1)
    #expect(try store.listenStats().isEmpty)
    #expect(try store.recordListen(trackID: "kept", at: at(5)) == ListenStat(count: 1, lastAt: at(5)))
}

@Test func tracksAndAlbumsCarryWhenTheyWereAdded() async throws {
    let box = try ListenSandbox()
    let library = try box.open()
    let before = Date().addingTimeInterval(-1)
    let outside = box.root.appending(path: "Picked", directoryHint: .isDirectory)
    var urls: [URL] = []
    for (fixture, name) in [("s16-44100", "one.flac"), ("s24-48000", "two.flac")] {
        let url = outside.appending(path: name)
        try TaggedFlac.write(fixture, to: url, tags: [("TITLE", name), ("ALBUM", "Pair")])
        urls.append(url)
    }
    _ = await library.importFiles(urls)

    let catalog = library.current
    let tracks = catalog.tracks.values
    #expect(tracks.count == 2)
    #expect(tracks.allSatisfy { $0.addedAt >= before && $0.addedAt <= Date().addingTimeInterval(1) })
    let album = try #require(catalog.albums.first)
    #expect(album.addedAt == tracks.map(\.addedAt).max())
}
