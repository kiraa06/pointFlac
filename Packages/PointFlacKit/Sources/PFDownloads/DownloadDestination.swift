import Darwin
import Foundation

/// Files a validated download into a folder the user picked in Files (Settings → Downloads), so the song outlives
/// the app: deleting an iOS app deletes its container, and every download in it.
///
/// The layout is `<Album Artist or Artist>/<Album>/<file name>`, from the download's own metadata, each component
/// made safe by `SafeFileName`. A track missing either name goes to the folder's root rather than into a made-up
/// "Unknown" folder.
///
/// The folder is the user's, so nothing in it is ever overwritten. A name already taken by another file gets " (2)",
/// " (3)" and so on; a byte-identical file under the name counts as already saved, so downloading a song again
/// never makes a second copy. The copy is written under a hidden temporary name beside its target and then renamed
/// into place with `RENAME_EXCL`, so neither a library scan nor the Files app ever sees half a file, and a save that
/// races another for a name cannot replace it. The write is coordinated (`NSFileCoordinator`), as a file provider's
/// folder (iCloud Drive) expects.
///
/// There are no bookmarks or security scope here: the caller resolves the folder and holds access while this runs,
/// so tests can use a plain temporary directory. Every call does blocking file I/O: run it off Swift's cooperative
/// pool.
public struct DownloadDestination: Sendable {
    /// Where the file is in the folder, and whether this call wrote it (`false`: an identical file was already there).
    public struct Saved: Sendable, Equatable {
        public var url: URL
        public var isNew: Bool

        public init(url: URL, isNew: Bool) {
            self.url = url
            self.isNew = isNew
        }
    }

    /// The folder could not take the file: it is gone, not a folder, not writable or full, or its provider failed.
    /// A staged file that vanished is reported the same way: either way, the song is not in the folder.
    public struct Unreachable: Error, Sendable, Equatable, CustomStringConvertible {
        public var reason: String

        public init(_ reason: String) {
            self.reason = reason
        }

        public var description: String { reason }
    }

    /// The `RemoteTrack.detail` key a provider can fill with the album artist, which then names the artist folder.
    /// No provider knows it today; the track's artist stands in.
    public static let albumArtistDetail = "albumArtist"
    /// Names tried for one file before giving up: "Song.flac", then "Song (2).flac" up to this number.
    static let maxCopies = 999

    public init() {}

    /// The folders below the picked one that `track` is filed in: its album artist (or artist), then its album; none
    /// when either name is missing or nothing of it survives sanitising.
    public static func folders(for track: RemoteTrack) -> [String] {
        let artist = [track.detail[albumArtistDetail], track.artist].lazy
            .compactMap { $0.flatMap(SafeFileName.folderName) }.first
        guard let artist, let album = track.album.flatMap(SafeFileName.folderName) else { return [] }
        return [artist, album]
    }

    /// Copies `staged` into `folder` (which must exist) under the track's artist and album, and returns where it is.
    /// The staged file is left for the caller to delete once the library has the copy.
    public func save(_ staged: URL, track: RemoteTrack, into folder: URL) throws(Unreachable) -> Saved {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            // Never created again: a folder that has gone (deleted, or its volume or provider not there) is the
            // user's to choose again, and a path recreated inside the app's sandbox would only be lost with the app.
            throw Unreachable("the folder is not there")
        }
        var source = stat()
        guard lstat(staged.path, &source) == 0, source.st_mode & S_IFMT == S_IFREG else {
            throw Unreachable("the downloaded file is missing")
        }
        let name =
            SafeFileName.sanitize(track.fileName) ?? SafeFileName.sanitize(staged.lastPathComponent) ?? "track.flac"
        var directory = folder
        for component in Self.folders(for: track) { directory.append(path: component, directoryHint: .isDirectory) }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Unreachable("could not make the album folder: \(Self.describe(error))")
        }
        // `sanitize` always ends a name in a lower-case ".flac".
        let stem = String(name.dropLast(5))
        for copy in 1...Self.maxCopies {
            let candidate = directory.appending(
                path: copy == 1 ? name : "\(stem) (\(copy)).flac", directoryHint: .notDirectory)
            switch try place(staged, size: source.st_size, at: candidate) {
            case .placed: return Saved(url: candidate, isNew: true)
            case .identical: return Saved(url: candidate, isNew: false)
            case .taken: continue
            }
        }
        throw Unreachable("too many files are already named \(name)")
    }

    private enum Placement {
        case placed
        case identical
        case taken
    }

    /// Puts the file at `target` unless something is there already, under one coordinated write.
    private func place(_ staged: URL, size: off_t, at target: URL) throws(Unreachable) -> Placement {
        var outcome: Result<Placement, Unreachable> = .failure(Unreachable("the folder's provider did not respond"))
        var coordination: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: target, options: [], error: &coordination) { url in
            do throws(Unreachable) {
                outcome = .success(try Self.placeLocked(staged, size: size, at: url))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordination { throw Unreachable("the folder's provider refused: \(Self.describe(coordination))") }
        return try outcome.get()
    }

    private static func placeLocked(_ staged: URL, size: off_t, at target: URL) throws(Unreachable) -> Placement {
        if let taken = occupant(at: target, staged: staged, size: size) { return taken }
        // An iCloud file evicted from the device shows only as ".Name.flac.icloud". Its bytes cannot be compared
        // without downloading it, and writing beside it would make a conflict, so the name counts as taken.
        let placeholder = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) { return .taken }

        let temporary = target.deletingLastPathComponent().appending(
            path: ".pointflac-saving-\(UUID().uuidString)", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard copyfile(staged.path, temporary.path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)) == 0
        else { throw Unreachable("could not write the file (\(String(cString: strerror(errno))))") }
        if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 { return .placed }
        let failure = errno
        if failure == EEXIST {
            // Something took the name between the check and the rename: judged like any file found there.
            return occupant(at: target, staged: staged, size: size) ?? .taken
        }
        throw Unreachable("could not name the file (\(String(cString: strerror(failure))))")
    }

    /// What is at `target`: nothing (`nil`), the same bytes as `staged`, or anything else. Only a regular file of the
    /// same size is read; a folder, a link or a special file under the name is never opened.
    private static func occupant(at target: URL, staged: URL, size: off_t) -> Placement? {
        var info = stat()
        guard lstat(target.path, &info) == 0 else { return errno == ENOENT ? nil : .taken }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size == size, sameBytes(staged, target) else { return .taken }
        return .identical
    }

    /// Compares two files a megabyte at a time.
    static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? FileHandle(forReadingFrom: a), let second = try? FileHandle(forReadingFrom: b) else {
            return false
        }
        defer {
            try? first.close()
            try? second.close()
        }
        while true {
            guard let x = try? first.read(upToCount: 1 << 20) ?? Data(),
                let y = try? second.read(upToCount: 1 << 20) ?? Data()
            else { return false }
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as NSError).localizedDescription
    }
}
