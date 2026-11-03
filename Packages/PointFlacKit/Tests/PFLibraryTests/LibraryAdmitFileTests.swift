import Foundation
import PFCore
import PFTestSupport
import Testing

@testable import PFLibrary

/// A download saved to the folder the user picked for downloads lands in a folder the library reads in place. The
/// library takes that one file in at once (`admitFile`), without reading the rest of a folder that may hold thousands
/// of songs, and the download is confirmed against the catalog before its staged copy is deleted.
private final class AdmitSandbox {
    let root: URL
    var libraryFolder: URL { root.appending(path: "Documents/Library", directoryHint: .isDirectory) }
    var database: URL { root.appending(path: "Support/library.sqlite") }
    var artwork: URL { root.appending(path: "Support/Artwork", directoryHint: .isDirectory) }
    var picked: URL { root.appending(path: "iCloud Drive/pointFlac", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "LibraryAdmit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func open() throws -> Library {
        try Library(databaseURL: database, libraryFolder: libraryFolder, artworkFolder: artwork)
    }
}

@Test func aFileSavedIntoAFolderReadInPlaceIsAdmittedAlone() async throws {
    let box = try AdmitSandbox()
    let library = try box.open()
    _ = try await library.addFolder(box.picked)
    // Put there behind the library's back (by the Files app, say): only a scan adds it.
    try TaggedFlac.write(
        "s24-48000", to: box.picked.appending(path: "Other/Album/01.flac"), tags: [("TITLE", "Not Yet")])
    let saved = box.picked.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
    try TaggedFlac.write(
        "s16-44100", to: saved,
        tags: [("TITLE", "Fold"), ("ARTIST", "Ada Vale"), ("ALBUM", "Paper Moons"), ("TRACKNUMBER", "1")])
    let probes = await library.probeCount()

    let id = try #require(try await library.admitFile(saved))

    let track = try #require(library.current.tracks[id])
    #expect(track.title == "Fold")
    #expect(!track.isInLibraryFolder)
    #expect(library.current.albums.map(\.title) == ["Paper Moons"])
    // One file read, not the folder.
    #expect(await library.probeCount() == probes + 1)
    // A later scan finds it where it is, unchanged, and adds only the other file.
    let rescan = await library.rescan()
    #expect(rescan.added.count == 1)
    #expect(rescan.removed.isEmpty && rescan.moved.isEmpty)
    #expect(library.current.tracks[id] != nil)
}

@Test func aFileAlreadyInTheLibraryUnchangedIsNotReadAgain() async throws {
    let box = try AdmitSandbox()
    let library = try box.open()
    let saved = box.picked.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
    try TaggedFlac.write("s16-44100", to: saved, tags: [("TITLE", "Fold"), ("ALBUM", "Paper Moons")])
    _ = try await library.addFolder(box.picked)
    let known = try #require(library.current.tracks.values.first?.id)
    let probes = await library.probeCount()
    let published = library.publishCount

    let id = try await library.admitFile(saved)

    #expect(id == known)
    #expect(await library.probeCount() == probes)
    // Nothing changed, so no new catalog.
    #expect(library.publishCount == published)
}

@Test func downloadingASongTheUserRemovedBringsItBack() async throws {
    let box = try AdmitSandbox()
    let library = try box.open()
    let saved = box.picked.appending(path: "A/B/song.flac")
    try TaggedFlac.write("s16-44100", to: saved, tags: [("TITLE", "Again"), ("ALBUM", "B")])
    _ = try await library.addFolder(box.picked)
    let id = try #require(library.current.tracks.values.first?.id)
    _ = try await library.remove(trackIDs: [id])
    #expect(library.current.tracks.isEmpty)
    // A rescan alone leaves a removed file out, while it is unchanged.
    await library.rescan()
    #expect(library.current.tracks.isEmpty)

    // Downloaded again, byte for byte: the download is the user asking for the song, so it comes back.
    let admitted = try await library.admitFile(saved)

    #expect(admitted == id)
    #expect(library.current.tracks[id]?.title == "Again")
    let rescan = await library.rescan()
    #expect(rescan.removed.isEmpty)
    #expect(library.current.tracks[id] != nil)
}

@Test func aFileOutsideEveryFolderIsRefused() async throws {
    let box = try AdmitSandbox()
    let library = try box.open()
    let stray = box.root.appending(path: "Elsewhere/song.flac")
    try TaggedFlac.write("s16-44100", to: stray, tags: [("TITLE", "Stray")])

    await #expect(throws: LibraryError.outsideFolders("song.flac")) { try await library.admitFile(stray) }
    #expect(library.current.tracks.isEmpty)
}

@Test func aFileTheAdmissionRuleRefusesIsNotAdmitted() async throws {
    let box = try AdmitSandbox()
    let library = try box.open()
    _ = try await library.addFolder(box.picked)
    let bad = box.picked.appending(path: "A/B/bad.flac")
    try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Fixtures.url(Fixtures.named("renamed-mp3")), to: bad)

    let id = try await library.admitFile(bad)

    #expect(id == nil)
    #expect(library.current.tracks.isEmpty)
}

@Test func theFolderHoldingAPathIsFound() async throws {
    let box = try AdmitSandbox()
    let library = try box.open()
    #expect(await library.folder(containing: box.picked) == nil)
    _ = try await library.addFolder(box.picked)
    let added = try #require(await library.folders().last)

    #expect(await library.folder(containing: box.picked) == added)
    #expect(await library.folder(containing: box.picked.appending(path: "Ada Vale/Paper Moons")) == added)
    // "pointFlac 2" is not inside "pointFlac".
    #expect(await library.folder(containing: box.root.appending(path: "iCloud Drive/pointFlac 2")) == nil)
    #expect(await library.folder(containing: box.root.appending(path: "iCloud Drive")) == nil)
    #expect(await library.folder(containing: box.libraryFolder.appending(path: "x"))?.id == 1)
}
