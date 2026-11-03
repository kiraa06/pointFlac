import Foundation
import PFTestSupport
import Testing

@testable import PFDownloads

/// Kiran lost every download when the app was deleted, so a download can go to a folder he picked in Files instead.
/// `DownloadDestination` is the copy into that folder: a plain temporary directory stands in for it here, since the
/// type knows nothing of bookmarks or security scope.
@Suite("DownloadDestination")
struct DownloadDestinationTests {
    /// A validated download waiting in staging, as `Admission` leaves it: a real FLAC under its sanitised name.
    static func staged(_ folder: TempFolder, fixture: String = "s16-44100", name: String = "01 Fold.flac") throws
        -> URL
    {
        let staging = folder.sub("Staging/job")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let url = staging.appending(path: name)
        try FileManager.default.copyItem(at: Fixtures.url(Fixtures.named(fixture)), to: url)
        return url
    }

    static func track(
        artist: String? = "Ada Vale", album: String? = "Paper Moons", fileName: String = "01 Fold.flac",
        detail: [String: String] = [:]
    ) -> RemoteTrack {
        RemoteTrack(
            id: "t1", provider: "archive", title: "Fold", artist: artist, album: album, fileName: fileName,
            detail: detail)
    }

    static func picked(_ folder: TempFolder) throws -> URL {
        let url = folder.sub("Picked")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    @Test("a download is filed under artist and album, as a copy of the staged file")
    func albumFolderLayout() throws {
        let folder = try TempFolder()
        let staged = try Self.staged(folder)
        let root = try Self.picked(folder)

        let saved = try DownloadDestination().save(staged, track: Self.track(), into: root)

        #expect(saved.url.path == root.appending(path: "Ada Vale/Paper Moons/01 Fold.flac").path)
        #expect(saved.isNew)
        #expect(try Self.bytes(saved.url) == Self.bytes(staged))
        // The staged file is the caller's to delete, once the library has the copy.
        #expect(FileManager.default.fileExists(atPath: staged.path))
        // No half-written file is left behind under a temporary name.
        let album = root.appending(path: "Ada Vale/Paper Moons")
        #expect(try FileManager.default.contentsOfDirectory(atPath: album.path) == ["01 Fold.flac"])
    }

    @Test("an album artist, when the source names one, files the album rather than the track's artist")
    func albumArtistFirst() throws {
        let folder = try TempFolder()
        let saved = try DownloadDestination().save(
            try Self.staged(folder), track: Self.track(artist: "Guest", detail: ["albumArtist": "Ada Vale"]),
            into: try Self.picked(folder))
        #expect(saved.url.path.hasSuffix("/Picked/Ada Vale/Paper Moons/01 Fold.flac"))
    }

    @Test(
        "each folder name is sanitised: no separators, no hidden or parent folders, no bidi tricks",
        arguments: [
            ("../AC/DC", "Back: In Black", "ACDC/Back In Black"),
            ("..\\..\\Windows", "  Spaced  ", "Windows/Spaced"),
            (" . .x", "A\u{1}lbum", "x/Album"),
            ("Ev\u{202E}il", "na\u{0}me", "Evil/name"),
            ("Cafe\u{301}", ".Hidden", "Caf\u{E9}/Hidden"),
        ])
    func sanitises(artist: String, album: String, expected: String) throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let saved = try DownloadDestination().save(
            try Self.staged(folder), track: Self.track(artist: artist, album: album), into: root)
        #expect(saved.url.path == root.appending(path: expected).appending(path: "01 Fold.flac").path)
        // Whatever the names, the file lands inside the picked folder.
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        #expect(saved.url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath))
    }

    @Test("the file name is the track's, sanitised, whatever the staged file is called")
    func fileNameFromTrack() throws {
        let folder = try TempFolder()
        let saved = try DownloadDestination().save(
            try Self.staged(folder, name: "Song.flac"), track: Self.track(fileName: "..\\Disc 1\\02 Crease.flac"),
            into: try Self.picked(folder))
        #expect(saved.url.lastPathComponent == "02 Crease.flac")
    }

    @Test("a different file already there is never overwritten: the copy gets \" (2)\", then \" (3)\"")
    func collisions() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let album = root.appending(path: "Ada Vale/Paper Moons")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let theirs = Data("someone else's song".utf8)
        try theirs.write(to: album.appending(path: "01 Fold.flac"))
        let destination = DownloadDestination()

        let second = try destination.save(try Self.staged(folder), track: Self.track(), into: root)
        #expect(second.url.lastPathComponent == "01 Fold (2).flac")
        #expect(second.isNew)
        #expect(try Self.bytes(album.appending(path: "01 Fold.flac")) == theirs)

        let other = try Self.staged(folder, fixture: "s24-48000", name: "other.flac")
        let third = try destination.save(other, track: Self.track(), into: root)
        #expect(third.url.lastPathComponent == "01 Fold (3).flac")
        #expect(try Self.bytes(third.url) == Self.bytes(other))
    }

    @Test("a byte-identical file already there counts as saved: no second copy is made")
    func identicalIsAlreadySaved() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let staged = try Self.staged(folder)
        let destination = DownloadDestination()
        let first = try destination.save(staged, track: Self.track(), into: root)

        let again = try destination.save(staged, track: Self.track(), into: root)

        #expect(again.url == first.url)
        #expect(!again.isNew)
        let album = root.appending(path: "Ada Vale/Paper Moons")
        #expect(try FileManager.default.contentsOfDirectory(atPath: album.path) == ["01 Fold.flac"])
    }

    @Test("an identical copy under a numbered name counts as saved too")
    func identicalNumberedCopy() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let album = root.appending(path: "Ada Vale/Paper Moons")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: album.appending(path: "01 Fold.flac"))
        let staged = try Self.staged(folder)
        let destination = DownloadDestination()
        let first = try destination.save(staged, track: Self.track(), into: root)
        #expect(first.url.lastPathComponent == "01 Fold (2).flac")

        let again = try destination.save(staged, track: Self.track(), into: root)

        #expect(again.url == first.url)
        #expect(!again.isNew)
    }

    @Test(
        "without an artist or an album the file goes to the folder's root",
        arguments: [
            (String?.none, String?.some("Paper Moons")),
            (String?.some("Ada Vale"), String?.none),
            (String?.some("  "), String?.some("Paper Moons")),
            (String?.some("Ada Vale"), String?.some("..")),
            (String?.none, String?.none),
        ])
    func missingMetadataGoesToTheRoot(artist: String?, album: String?) throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let saved = try DownloadDestination().save(
            try Self.staged(folder), track: Self.track(artist: artist, album: album), into: root)
        #expect(saved.url.path == root.appending(path: "01 Fold.flac").path)
    }

    @Test("a folder that is gone throws, and is not created again")
    func missingFolderThrows() throws {
        let folder = try TempFolder()
        let gone = folder.sub("Gone")
        #expect(throws: DownloadDestination.Unreachable.self) {
            try DownloadDestination().save(try Self.staged(folder), track: Self.track(), into: gone)
        }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test("a file where the folder should be throws")
    func fileInsteadOfFolderThrows() throws {
        let folder = try TempFolder()
        let notAFolder = folder.url.appending(path: "Picked")
        try Data("x".utf8).write(to: notAFolder)
        #expect(throws: DownloadDestination.Unreachable.self) {
            try DownloadDestination().save(try Self.staged(folder), track: Self.track(), into: notAFolder)
        }
    }

    @Test("a folder that can't be written to throws, and nothing is left in it")
    func readOnlyFolderThrows() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        #expect(throws: DownloadDestination.Unreachable.self) {
            try DownloadDestination().save(try Self.staged(folder), track: Self.track(), into: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("a staged file that has gone throws rather than saving nothing")
    func missingStagedFileThrows() throws {
        let folder = try TempFolder()
        let staged = try Self.staged(folder)
        try FileManager.default.removeItem(at: staged)
        #expect(throws: DownloadDestination.Unreachable.self) {
            try DownloadDestination().save(staged, track: Self.track(), into: try Self.picked(folder))
        }
    }
}
