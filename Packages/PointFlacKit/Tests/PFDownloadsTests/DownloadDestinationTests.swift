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

    @Test("a partial copy left by an earlier run that was killed is swept; a fresh one, and other files, are not")
    func sweepsStalePartials() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let album = root.appending(path: "Ada Vale/Paper Moons")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let stale = album.appending(path: ".pointflac-saving-\(UUID().uuidString)")
        let fresh = album.appending(path: ".pointflac-saving-\(UUID().uuidString)")
        let theirs = album.appending(path: ".notes")
        for url in [stale, fresh, theirs] { try Data("partial".utf8).write(to: url) }
        let old = Date().addingTimeInterval(-120)
        for url in [stale, theirs] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        _ = try DownloadDestination().save(try Self.staged(folder), track: Self.track(), into: root)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: theirs.path))
    }

    @Test("an artist or album named like an app or a bundle gets a folder a library scan still reads")
    func appLikeNames() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let saved = try DownloadDestination().save(
            try Self.staged(folder), track: Self.track(artist: "Tools.app", album: "Kit.Bundle"), into: root)
        #expect(saved.url.path == root.appending(path: "Tools.app_/Kit.Bundle_/01 Fold.flac").path)
    }

    /// The failure `body` throws, or a recorded issue when it throws nothing (or something else).
    static func failure(_ body: () throws -> Void) -> DownloadDestination.Failure? {
        do {
            try body()
            Issue.record("nothing was thrown")
        } catch let failure as DownloadDestination.Failure {
            return failure
        } catch {
            Issue.record("unexpected error \(error)")
        }
        return nil
    }

    @Test("a folder that is gone is unreachable, and is not created again")
    func missingFolderThrows() throws {
        let folder = try TempFolder()
        let gone = folder.sub("Gone")
        let failure = Self.failure {
            _ = try DownloadDestination().save(try Self.staged(folder), track: Self.track(), into: gone)
        }
        #expect(failure?.folderUnreachable == true)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test("a file where the folder should be is unreachable")
    func fileInsteadOfFolderThrows() throws {
        let folder = try TempFolder()
        let notAFolder = folder.url.appending(path: "Picked")
        try Data("x".utf8).write(to: notAFolder)
        let failure = Self.failure {
            _ = try DownloadDestination().save(try Self.staged(folder), track: Self.track(), into: notAFolder)
        }
        #expect(failure?.folderUnreachable == true)
    }

    @Test("a folder that can't be written to is unreachable, and nothing is left in it")
    func readOnlyFolderThrows() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let failure = Self.failure {
            _ = try DownloadDestination().save(try Self.staged(folder), track: Self.track(), into: root)
        }
        #expect(failure?.folderUnreachable == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("a staged file that has gone fails this download only: the folder is fine")
    func missingStagedFileThrows() throws {
        let folder = try TempFolder()
        let staged = try Self.staged(folder)
        try FileManager.default.removeItem(at: staged)
        let failure = Self.failure {
            _ = try DownloadDestination().save(staged, track: Self.track(), into: try Self.picked(folder))
        }
        #expect(failure?.folderUnreachable == false)
    }

    @Test("a file standing where the artist folder should be fails this download only, and is left alone")
    func fileInTheWay() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let inTheWay = root.appending(path: "Ada Vale")
        try Data("not a folder".utf8).write(to: inTheWay)
        let failure = Self.failure {
            _ = try DownloadDestination().save(try Self.staged(folder), track: Self.track(), into: root)
        }
        #expect(failure?.folderUnreachable == false)
        #expect(try Data(contentsOf: inTheWay) == Data("not a folder".utf8))
    }

    @Test("running out of numbered names fails this download only")
    func tooManyCopies() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let album = root.appending(path: "Ada Vale/Paper Moons")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        for name in ["01 Fold.flac", "01 Fold (2).flac", "01 Fold (3).flac"] {
            try Data("theirs \(name)".utf8).write(to: album.appending(path: name))
        }
        let failure = Self.failure {
            _ = try DownloadDestination(maxCopies: 3).save(try Self.staged(folder), track: Self.track(), into: root)
        }
        #expect(failure?.folderUnreachable == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: album.path).count == 3)
    }

    @Test("a file provider that holds the name too long fails this download only, and writes nothing")
    func coordinationTimesOut() async throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let album = root.appending(path: "Ada Vale/Paper Moons")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let target = album.appending(path: "01 Fold.flac")
        let staged = try Self.staged(folder)
        // Another writer holds the name, as a provider busy with it would, on a thread of its own until the save has
        // given up: a fixed hold could end first on a loaded machine, and the save would then succeed. (Thirty seconds
        // at most, so a save that never gives up fails the test rather than hangs it.) The test awaits the gates
        // rather than blocking on semaphores, so its cooperative-pool thread is free meanwhile.
        let holding = Gate()
        let released = Gate()
        let letGo = DispatchSemaphore(value: 0)
        let holder = Thread {
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: [], error: nil) { _ in
                Task { await holding.open() }
                _ = letGo.wait(timeout: .now() + 30)
            }
            Task { await released.open() }
        }
        holder.start()
        await holding.wait()

        let failure = Self.failure {
            _ = try DownloadDestination(coordinationTimeout: .milliseconds(200)).save(
                staged, track: Self.track(), into: root)
        }
        letGo.signal()

        #expect(failure?.folderUnreachable == false)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        await released.wait()
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("a same-size file whose bytes are not on the device is a collision, never downloaded to compare")
    func notDownloadedIsACollision() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let staged = try Self.staged(folder)
        let first = try DownloadDestination().save(staged, track: Self.track(), into: root)
        // As if iCloud had evicted the first copy: same name, same size, bytes elsewhere.
        let evicted = DownloadDestination(isDownloaded: { $0.lastPathComponent != first.url.lastPathComponent })

        let again = try evicted.save(staged, track: Self.track(), into: root)

        #expect(again.url.lastPathComponent == "01 Fold (2).flac")
        #expect(again.isNew)
    }

    @Test("taking a copy back deletes it only while it is still the very file this save placed")
    func takeBackOnlyOurOwn() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        let staged = try Self.staged(folder)
        let destination = DownloadDestination()

        let ours = try destination.save(staged, track: Self.track(), into: root)
        #expect(destination.takeBack(ours))
        #expect(!FileManager.default.fileExists(atPath: ours.url.path))

        // Replaced meanwhile by another file of the same name and bytes (a new inode): left alone.
        let placed = try destination.save(staged, track: Self.track(), into: root)
        try FileManager.default.removeItem(at: placed.url)
        try FileManager.default.copyItem(at: staged, to: placed.url)
        #expect(!destination.takeBack(placed))
        #expect(FileManager.default.fileExists(atPath: placed.url.path))

        // A file that was already there is never ours to take back.
        let adopted = try destination.save(staged, track: Self.track(), into: root)
        #expect(!adopted.isNew)
        #expect(!destination.takeBack(adopted))
        #expect(FileManager.default.fileExists(atPath: adopted.url.path))
    }

    @Test("the reachability probe writes and removes a hidden file, and fails for a folder that can't take one")
    func probe() throws {
        let folder = try TempFolder()
        let root = try Self.picked(folder)
        try DownloadDestination.probe(root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let gone = Self.failure { try DownloadDestination.probe(folder.sub("Gone")) }
        #expect(gone?.folderUnreachable == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let readOnly = Self.failure { try DownloadDestination.probe(root) }
        #expect(readOnly?.folderUnreachable == true)
    }
}
