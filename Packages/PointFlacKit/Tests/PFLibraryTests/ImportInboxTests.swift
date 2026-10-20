import Foundation
import PFCore
import PFFlac
import PFTestSupport
import Testing

@testable import PFLibrary

/// A fresh, empty library folder for one test, removed again when the test ends.
private final class TemporaryLibrary {
    let folder: URL
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ImportInboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        folder = root.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // A test may have made the folder read-only; make it removable again first.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// The names of the files in the library folder, sorted.
    func contents() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted()
    }

    /// A copy of fixture `name` outside the library folder, under `fileName`.
    func source(_ name: String, as fileName: String) throws -> URL {
        let outside = root.appending(path: "Sources-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let url = outside.appending(path: fileName)
        try FileManager.default.copyItem(at: Fixtures.url(Fixtures.named(name)), to: url)
        return url
    }
}

private func fixture(_ name: String) -> URL {
    Fixtures.url(Fixtures.named(name))
}

@Test func importsValidAndRejectsDisguised() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder)

    let result = await inbox.importFiles([fixture("s24-48000"), fixture("renamed-mp3")])

    #expect(result.added.count == 1)
    #expect(result.rejected.count == 1)
    let rejection = try #require(result.rejected.first)
    #expect(rejection.fileName == "renamed-mp3.flac" && rejection.reason == .badMagic)
    #expect(rejection.message == "Not a FLAC file")

    let added = try #require(result.added.first)
    #expect(added.id == "s24-48000.flac")
    #expect(added.url.path == library.folder.appending(path: "s24-48000.flac").path)
    #expect(added.title == "Fixture Title" && added.artist == "Fixture Artist" && added.album == "Fixture Album")
    #expect(added.format == AudioFormat(sampleRate: 48_000, bitsPerSample: 24, channels: 2))
    #expect(added.totalFrames == 4096)
    #expect(FileManager.default.fileExists(atPath: added.url.path))
    #expect(library.contents() == ["s24-48000.flac"])
    #expect(await inbox.list() == [added])
}

@Test func skipsDuplicates() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder)

    let first = await inbox.importFiles([fixture("s24-48000")])
    let second = await inbox.importFiles([fixture("s24-48000")])

    #expect(first.added.count == 1)
    #expect(second.added.isEmpty && second.rejected.isEmpty)
    #expect(await inbox.list().count == 1)
}

/// Same name but another size is a different file: it is added beside the first, under a numbered name, and is itself
/// a duplicate from then on.
@Test func sameNameWithAnotherSizeIsNotADuplicate() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder)
    let original = try library.source("s24-48000", as: "Song.flac")
    let other = try library.source("s16-44100", as: "Song.flac")

    let first = await inbox.importFiles([original])
    let second = await inbox.importFiles([other])
    let again = await inbox.importFiles([original, other])

    #expect(first.added.map(\.id) == ["Song.flac"])
    #expect(second.added.map(\.id) == ["Song 2.flac"])
    // Untagged: the title falls back to the library file name, without the extension.
    #expect(second.added.first?.title == "Song 2")
    #expect(second.added.first?.format == AudioFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2))
    #expect(again.added.isEmpty && again.rejected.isEmpty)
    #expect(library.contents() == ["Song 2.flac", "Song.flac"])
    #expect(await inbox.list().map(\.id) == ["Song.flac", "Song 2.flac"])
}

/// Anything already at the name, even a folder, makes the inbox move on to the next numbered name.
@Test func neverCopiesOntoSomethingElse() async throws {
    let library = try TemporaryLibrary()
    try FileManager.default.createDirectory(
        at: library.folder.appending(path: "s24-48000.flac"), withIntermediateDirectories: true)
    let inbox = ImportInbox(libraryFolder: library.folder)

    let result = await inbox.importFiles([fixture("s24-48000")])

    #expect(result.added.map(\.id) == ["s24-48000 2.flac"] && result.rejected.isEmpty)
    #expect(await inbox.list().map(\.id) == ["s24-48000 2.flac"])
}

/// The library folder is read-only here, so any attempt to copy into it fails, and would surface as `.unreadable`. The
/// disguised MP3 is rejected for what it is, `.badMagic`, so it was validated before any copy was tried.
@Test func rejectsBeforeCopying() async throws {
    let library = try TemporaryLibrary()
    try FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.folder.path)
    let inbox = ImportInbox(libraryFolder: library.folder)

    let result = await inbox.importFiles([fixture("renamed-mp3")])

    #expect(result.added.isEmpty)
    #expect(result.rejected.map(\.reason) == [.badMagic])
    #expect(!FileManager.default.fileExists(atPath: library.folder.appending(path: "renamed-mp3.flac").path))
    #expect(library.contents().isEmpty)
}

@Test func rejectionMessages() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder)

    let result = await inbox.importFiles([
        fixture("not-flac-name"), fixture("renamed-mp3"), fixture("truncated-meta"), fixture("bad-frame-crc"),
    ])

    #expect(result.added.isEmpty)
    #expect(result.rejected.map(\.reason) == [.notFlacName, .badMagic, .truncated, .frameCRCMismatch])
    #expect(
        result.rejected.map(\.message) == [
            "Only .flac files can be added", "Not a FLAC file", "Damaged or incomplete FLAC",
            "Damaged or incomplete FLAC",
        ])
    #expect(library.contents().isEmpty)
}

@Test func listsWhatIsAlreadyInTheFolder() async throws {
    let library = try TemporaryLibrary()
    _ = await ImportInbox(libraryFolder: library.folder).importFiles([fixture("s32-48000"), fixture("s16-44100")])

    // A new inbox over the same folder, as after a relaunch.
    let files = await ImportInbox(libraryFolder: library.folder).list()

    #expect(files.map(\.id) == ["s16-44100.flac", "s32-48000.flac"])
    #expect(files.map(\.format.bitsPerSample) == [16, 32])
    #expect(await ImportInbox(libraryFolder: library.root.appending(path: "Missing")).list().isEmpty)
}
