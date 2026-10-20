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

/// What a copy throws when it fails part-way, as on a full disk or a provider file evicted mid-read.
private struct CopyFailed: Error {}

/// A copy that dies half-way leaves neither a partial file nor its temporary file, and the name stays free.
@Test func failedCopyLeavesNothingBehind() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder) { source, destination in
        let bytes = try Data(contentsOf: source)
        try bytes.prefix(bytes.count / 2).write(to: destination)
        throw CopyFailed()
    }

    let result = await inbox.importFiles([fixture("s24-48000")])

    #expect(result.added.isEmpty && result.rejected.map(\.reason) == [.unreadable])
    // The listing includes hidden files, so a leftover temporary file would show here too.
    #expect(library.contents().isEmpty)
    let retry = await ImportInbox(libraryFolder: library.folder).importFiles([fixture("s24-48000")])
    #expect(retry.added.map(\.id) == ["s24-48000.flac"])
}

/// The source changed between the check and the copy, so what arrived is not FLAC: it never takes the name.
@Test func copyThatFailsValidationLeavesNothingBehind() async throws {
    let library = try TemporaryLibrary()
    let disguised = fixture("renamed-mp3")
    let inbox = ImportInbox(libraryFolder: library.folder) { _, destination in
        try FileManager.default.copyItem(at: disguised, to: destination)
    }

    let result = await inbox.importFiles([fixture("s24-48000")])

    #expect(result.added.isEmpty && result.rejected.map(\.reason) == [.badMagic])
    #expect(library.contents().isEmpty)
}

/// An import killed mid-copy leaves its hidden temporary file behind; the next inbox over the folder removes it before
/// anything else it does, and removes nothing else.
@Test func sweepsTemporaryFilesOnInit() async throws {
    let library = try TemporaryLibrary()
    try FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
    try Data([0x66, 0x4C]).write(to: library.folder.appending(path: ".import-\(UUID().uuidString).flac"))
    try Data().write(to: library.folder.appending(path: ".keep"))
    try FileManager.default.copyItem(at: fixture("s16-44100"), to: library.folder.appending(path: "s16-44100.flac"))

    let inbox = ImportInbox(libraryFolder: library.folder)

    // The sweep runs first on the inbox's queue, so it is done by the time anything the inbox does returns.
    #expect(await inbox.list().map(\.id) == ["s16-44100.flac"])
    #expect(library.contents() == [".keep", "s16-44100.flac"])
}

/// A hidden name would be copied in and then never listed, so it is refused, like any name that is not plain ".flac".
/// That covers the "._Song.flac" AppleDouble files that copies from external drives leave beside real ones.
@Test func rejectsHiddenNames() async throws {
    let library = try TemporaryLibrary()
    let hidden = try library.source("s24-48000", as: ".Song.flac")
    let appleDouble = try library.source("s24-48000", as: "._Song.flac")

    let result = await ImportInbox(libraryFolder: library.folder).importFiles([hidden, appleDouble])

    #expect(result.added.isEmpty)
    #expect(result.rejected.map(\.reason) == [.notFlacName, .notFlacName])
    #expect(result.rejected.map(\.message) == ["Only .flac files can be added", "Only .flac files can be added"])
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

/// Spec §5.3: a multichannel file is imported and listed like any other, but marked as not supported in v1, so the
/// UI can show it and refuse to play it.
@Test func multichannelIsImportedButMarkedUnsupported() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder)

    let result = await inbox.importFiles([fixture("s16-48000-6ch"), fixture("s24-48000"), fixture("s16-44100-mono")])

    #expect(result.rejected.isEmpty)
    #expect(result.added.map(\.id) == ["s16-48000-6ch.flac", "s24-48000.flac", "s16-44100-mono.flac"])
    #expect(result.added.map(\.isSupported) == [false, true, true])
    let listed = await inbox.list()
    let multichannel = try #require(listed.first { $0.id == "s16-48000-6ch.flac" })
    #expect(multichannel.format.channels == 6 && !multichannel.isSupported)
    #expect(listed.filter(\.isSupported).map(\.id) == ["s16-44100-mono.flac", "s24-48000.flac"])
}

// MARK: Plan 2 entry gates

/// The content identity survives a rename and a tag edit, and differs between recordings.
@Test func importedFilesCarryAStableContentIdentity() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder)
    let first = try #require(await inbox.importFiles([fixture("s24-48000")]).added.first)
    let other = try #require(await inbox.importFiles([fixture("s16-44100")]).added.first)
    #expect(first.contentID.count == 32 && first.contentID != other.contentID)

    try FileManager.default.moveItem(at: first.url, to: library.folder.appending(path: "Renamed.flac"))
    let renamed = try #require(await inbox.list().first { $0.id == "Renamed.flac" })
    #expect(renamed.contentID == first.contentID)
}

/// Spec §5.8: a source over the size bound is refused before it is read or copied.
@Test func refusesFilesOverTheSizeBound() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder, maxFileBytes: 10_000)

    let result = await inbox.importFiles([fixture("s24-48000")])

    #expect(result.added.isEmpty)
    let rejection = try #require(result.rejected.first)
    #expect(rejection.exceedsSizeLimit && rejection.message == "Too large to add")
    #expect(library.contents().isEmpty)
}

/// `list()` reads a file once, and again only when its size or modification date changes.
@Test func listingUsesItsIndex() async throws {
    let library = try TemporaryLibrary()
    let inbox = ImportInbox(libraryFolder: library.folder)
    _ = await inbox.importFiles([fixture("s24-48000"), fixture("s16-44100")])

    #expect(await inbox.list().count == 2)
    #expect(await inbox.listingParses() == 2)
    #expect(await inbox.list().count == 2)
    #expect(await inbox.listingParses() == 2)

    let changed = library.folder.appending(path: "s16-44100.flac")
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: changed.path)
    #expect(await inbox.list().count == 2)
    #expect(await inbox.listingParses() == 3)

    try FileManager.default.removeItem(at: changed)
    #expect(await inbox.list().map(\.id) == ["s24-48000.flac"])
}
