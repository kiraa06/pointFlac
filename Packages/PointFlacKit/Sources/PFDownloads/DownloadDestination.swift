import Darwin
import Foundation
import Synchronization

/// Files a validated download into a folder the user picked in Files (Settings → Downloads), so the song outlives
/// the app: deleting an iOS app deletes its container, and every download in it.
///
/// The layout is `<Album Artist or Artist>/<Album>/<file name>`, from the download's own metadata, each component
/// made safe by `SafeFileName`. A track missing either name goes to the folder's root rather than into a made-up
/// "Unknown" folder. The picked folder itself is never created: it must exist, and the artist and album folders are
/// made one level at a time below it, so a folder that has gone is reported, not quietly made again.
///
/// The folder is the user's, so nothing in it is ever overwritten. A name already taken by another file gets " (2)",
/// " (3)" and so on; a byte-identical file under the name counts as already saved, so downloading a song again
/// never makes a second copy (a same-size file whose bytes are still in iCloud is never downloaded to compare: it
/// counts as taken). The copy is written under a hidden temporary name beside its target and then renamed into place
/// with `RENAME_EXCL`, so neither a library scan nor the Files app ever sees half a file, and a save that races
/// another for a name cannot replace it. A temporary file left by a run that was killed is swept the next time a
/// download goes into that folder. The write is coordinated (`NSFileCoordinator`), as a file provider's folder
/// (iCloud Drive) expects, and gives up after `coordinationTimeout` if the provider never grants it.
///
/// Every failure says whether the folder itself is at fault (`Failure.folderUnreachable`: it is gone or not a folder,
/// refuses access, or its storage is not responding, so later downloads would fail too) or only this download is.
/// Only the picked folder itself decides that: a fault below it (in an artist or album folder, or writing the file)
/// is this download's, unless the folder then fails the same probe Settings uses to tell a folder that is back.
/// Running out of space is always this download's: an empty probe file would still fit, and flip the folder back.
///
/// There are no bookmarks or security scope here: the caller resolves the folder and holds access while this runs,
/// so tests can use a plain temporary directory. Every call does blocking file I/O: run it off Swift's cooperative
/// pool.
public struct DownloadDestination: Sendable {
    /// Where the file is in the folder, and whether this call wrote it (`false`: an identical file was already there).
    public struct Saved: Sendable, Equatable {
        public var url: URL
        public var isNew: Bool
        /// The file this call placed, as it was placed: what `takeBack` checks before deleting anything.
        public var identity: FileIdentity?

        public init(url: URL, isNew: Bool, identity: FileIdentity? = nil) {
            self.url = url
            self.isNew = isNew
            self.identity = identity
        }
    }

    /// One file on one volume, at one size: a file replaced by another of the same name is a different identity.
    public struct FileIdentity: Sendable, Hashable {
        public var device: Int64
        public var inode: UInt64
        public var size: Int64

        init(_ info: stat) {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
        }
    }

    /// Why the file is not in the folder, in a few plain words the Downloads list can show.
    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// The folder itself can't take files now (gone, not a folder, access refused, full, its storage not
        /// responding), so later downloads would fail too; otherwise only this download failed.
        public var folderUnreachable: Bool
        public var reason: String

        public static func unreachable(_ reason: String) -> Failure {
            Failure(folderUnreachable: true, reason: reason)
        }

        public static func fileOnly(_ reason: String) -> Failure {
            Failure(folderUnreachable: false, reason: reason)
        }

        public var description: String { reason }
    }

    /// The `RemoteTrack.detail` key a provider can fill with the album artist, which then names the artist folder.
    /// No provider knows it today; the track's artist stands in.
    public static let albumArtistDetail = "albumArtist"
    /// Hidden names this type writes: a copy on its way into place, and the reachability probe.
    static let partialPrefix = ".pointflac-saving-"
    static let probePrefix = ".pointflac-probe-"
    /// A temporary file of ours whose status last changed this long ago, that this process is not writing, was left
    /// by a run that was killed.
    public static let staleAfter: TimeInterval = 60
    /// The temporary names this process is writing right now: never swept.
    private static let inFlight = Mutex<Set<String>>([])

    /// Names tried for one file before giving up: "Song.flac", then "Song (2).flac" up to this number.
    let maxCopies: Int
    /// How long to wait for a file provider to grant the coordinated write before giving this download up.
    let coordinationTimeout: Duration
    /// Whether a file's bytes are on the device; injectable, since a test has no iCloud.
    let isDownloaded: @Sendable (URL) -> Bool
    /// The age past which a partial copy of ours is a killed run's (`staleAfter`); shorter in tests.
    let partialsStaleAfter: TimeInterval

    public init(
        maxCopies: Int = 999, coordinationTimeout: Duration = .seconds(120),
        isDownloaded: @escaping @Sendable (URL) -> Bool = DownloadDestination.bytesAreLocal,
        partialsStaleAfter: TimeInterval = DownloadDestination.staleAfter
    ) {
        self.maxCopies = max(1, maxCopies)
        self.coordinationTimeout = coordinationTimeout
        self.isDownloaded = isDownloaded
        self.partialsStaleAfter = partialsStaleAfter
    }

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
    public func save(_ staged: URL, track: RemoteTrack, into folder: URL) throws(Failure) -> Saved {
        try Self.requireFolder(folder)
        var source = stat()
        guard lstat(staged.path, &source) == 0, source.st_mode & S_IFMT == S_IFREG else {
            throw .fileOnly("the downloaded file is missing")
        }
        do {
            return try saveBelow(folder, staged: staged, size: source.st_size, track: track)
        } catch {
            // A fault below the folder is this download's, unless the folder itself no longer takes a file.
            do { try Self.probe(folder) } catch let root where root.folderUnreachable { throw root } catch {}
            throw error
        }
    }

    private func saveBelow(_ folder: URL, staged: URL, size: off_t, track: RemoteTrack) throws(Failure) -> Saved {
        let name =
            SafeFileName.sanitize(track.fileName) ?? SafeFileName.sanitize(staged.lastPathComponent) ?? "track.flac"
        let directory = try Self.makeFolders(Self.folders(for: track), under: folder)
        Self.sweepPartials(in: directory, olderThan: partialsStaleAfter)
        // `sanitize` always ends a name in a lower-case ".flac".
        let stem = String(name.dropLast(5))
        for copy in 1...maxCopies {
            let candidate = directory.appending(
                path: copy == 1 ? name : "\(stem) (\(copy)).flac", directoryHint: .notDirectory)
            switch try place(staged, size: size, at: candidate) {
            case .placed(let identity): return Saved(url: candidate, isNew: true, identity: identity)
            case .identical: return Saved(url: candidate, isNew: false)
            case .taken: continue
            }
        }
        throw .fileOnly("too many files already have its name")
    }

    /// Deletes a copy `save` placed, but only while it is still that very file (same volume, inode and size): never
    /// a file that was already there, nor one that has replaced it since. True when it was deleted.
    @discardableResult
    public func takeBack(_ saved: Saved) -> Bool {
        guard saved.isNew, let identity = saved.identity else { return false }
        let deleted = try? Self.coordinatedWrite(at: saved.url, options: .forDeleting, timeout: coordinationTimeout) {
            url throws(Failure) -> Bool in
            var info = stat()
            guard lstat(url.path, &info) == 0, FileIdentity(info) == identity else { return false }
            return unlink(url.path) == 0
        }
        return deleted ?? false
    }

    /// Whether `folder` can take a file now: creates a hidden empty file in it and removes it again. Throws as `save`
    /// would, so a folder that is back can be told from one still gone, refused or full.
    public static func probe(_ folder: URL) throws(Failure) {
        try requireFolder(folder)
        sweepPartials(in: folder, olderThan: staleAfter)
        let name = probePrefix + UUID().uuidString
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        inFlight.withLock { _ = $0.insert(name) }
        defer { inFlight.withLock { _ = $0.remove(name) } }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw rootFailure(errno) }
        close(descriptor)
        unlink(url.path)
    }

    /// Whether a file's bytes are on the device: false for a dataless file (an iCloud file evicted to free space),
    /// so it is never read, which would block on downloading it.
    public static func bytesAreLocal(_ url: URL) -> Bool {
        var info = stat()
        // SF_DATALESS: the file's contents live with its provider.
        if lstat(url.path, &info) == 0, info.st_flags & 0x4000_0000 != 0 { return false }
        guard
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
            values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus
        else { return true }
        return status == .current || status == .downloaded
    }

    // MARK: Folders

    /// The picked folder must be there and be a folder; it is never made here. Anything wrong with it is the
    /// folder's fault.
    private static func requireFolder(_ folder: URL) throws(Failure) {
        var info = stat()
        guard stat(folder.path, &info) == 0 else {
            let code = errno
            throw code == ENOENT
                ? .unreachable("the folder is not there")
                : .unreachable("the folder can't be opened (\(String(cString: strerror(code))))")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw .unreachable("the folder is not a folder any more") }
    }

    /// Makes each of `names` below `root`, one level at a time. Something that is not a folder (a file, a link) in the
    /// way fails this download only, and is left alone.
    private static func makeFolders(_ names: [String], under root: URL) throws(Failure) -> URL {
        var directory = root
        for name in names {
            directory.append(path: name, directoryHint: .isDirectory)
            var info = stat()
            if lstat(directory.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw .fileOnly("a file is in the way of its folder") }
                continue
            }
            guard errno == ENOENT else { throw classify(errno, doing: "couldn't look in the folder") }
            if mkdir(directory.path, 0o755) != 0 {
                let code = errno
                if code == EEXIST, lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { continue }
                throw classify(code, doing: "couldn't make its folder")
            }
        }
        return directory
    }

    /// Deletes our own temporary files in `directory` that a killed run left: not being written by this process, and
    /// whose status last changed (`st_ctime`) more than `age` ago. Not the modification date: a clone keeps its
    /// source's dates, so a copy made a moment ago can carry the date of a download from last week. Nothing else is
    /// touched.
    static func sweepPartials(in directory: URL, olderThan age: TimeInterval) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let mine = inFlight.withLock { $0 }
        let cutoff = Date().addingTimeInterval(-age).timeIntervalSince1970
        for name in names where name.hasPrefix(partialPrefix) || name.hasPrefix(probePrefix) {
            guard !mine.contains(name) else { continue }
            let path = directory.appending(path: name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let changed = TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1e9
            guard changed < cutoff else { continue }
            unlink(path)
        }
    }

    /// A fault below the picked folder: this download's (`save` then asks the folder itself, with `probe`).
    static func classify(_ code: Int32, doing: String) -> Failure {
        switch code {
        case ENOSPC, EDQUOT: .fileOnly("not enough space in the folder")
        default: .fileOnly("\(doing) (\(String(cString: strerror(code))))")
        }
    }

    /// A fault writing in the picked folder itself (the probe): the folder's, except running out of space.
    static func rootFailure(_ code: Int32) -> Failure {
        switch code {
        case ENOSPC, EDQUOT: .fileOnly("not enough space in the folder")
        case EACCES, EPERM, EROFS: .unreachable("pointFlac isn't allowed to write there")
        case ENOENT, ENOTDIR: .unreachable("the folder is not there")
        case EIO, ENXIO, ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH:
            .unreachable("the folder's storage isn't responding")
        default: .unreachable("the folder can't take files (\(String(cString: strerror(code))))")
        }
    }

    // MARK: Placing

    private enum Placement: Sendable {
        case placed(FileIdentity)
        case identical
        case taken
    }

    /// Puts the file at `target` unless something is there already, under one coordinated write.
    private func place(_ staged: URL, size: off_t, at target: URL) throws(Failure) -> Placement {
        let isDownloaded = isDownloaded
        return try Self.coordinatedWrite(at: target, options: [], timeout: coordinationTimeout) {
            url throws(Failure) -> Placement in
            try Self.placeLocked(staged, size: size, at: url, isDownloaded: isDownloaded)
        }
    }

    private static func placeLocked(
        _ staged: URL, size: off_t, at target: URL, isDownloaded: @Sendable (URL) -> Bool
    ) throws(Failure) -> Placement {
        if let found = occupant(at: target, staged: staged, size: size, isDownloaded: isDownloaded) { return found }
        // An iCloud file evicted from the device may show only as ".Name.flac.icloud". Its bytes cannot be compared
        // without downloading it, and writing beside it would make a conflict, so the name counts as taken.
        let placeholder = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) { return .taken }

        let name = partialPrefix + UUID().uuidString
        let temporary = target.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
        inFlight.withLock { _ = $0.insert(name) }
        defer {
            unlink(temporary.path)
            inFlight.withLock { _ = $0.remove(name) }
        }
        guard copyfile(staged.path, temporary.path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)) == 0
        else { throw classify(errno, doing: "couldn't write it") }
        // Taken before the rename, which keeps the file's volume, inode and size: once the copy has its name, nothing
        // can stop it being admitted, or taken back as ours.
        var copied = stat()
        guard lstat(temporary.path, &copied) == 0 else { throw classify(errno, doing: "couldn't write it") }
        if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 { return .placed(FileIdentity(copied)) }
        let failure = errno
        switch failure {
        case EEXIST:
            // Something took the name between the check and the rename: judged like any file found there.
            return occupant(at: target, staged: staged, size: size, isDownloaded: isDownloaded) ?? .taken
        case ENOTSUP, EINVAL:
            // The volume can't rename without replacing: never risk the user's file.
            throw .fileOnly("the folder can't take it safely")
        default:
            throw classify(failure, doing: "couldn't name it")
        }
    }

    /// What is at `target`: nothing (`nil`), the same bytes as `staged`, or anything else. Only a regular file of the
    /// same size, whose bytes are on the device, is read; a folder, a link or a special file is never opened.
    private static func occupant(
        at target: URL, staged: URL, size: off_t, isDownloaded: @Sendable (URL) -> Bool
    ) -> Placement? {
        var info = stat()
        guard lstat(target.path, &info) == 0 else { return errno == ENOENT ? nil : .taken }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size == size, isDownloaded(target),
            sameBytes(staged, target)
        else { return .taken }
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

    // MARK: Coordination

    /// Where one coordinated write is: waiting for the provider, under way, done, or given up.
    private enum Phase<T: Sendable>: Sendable {
        case waiting
        case working
        case finished(Result<T, Failure>)
        case abandoned
    }

    private final class PhaseBox<T: Sendable>: Sendable {
        let phase = Mutex<Phase<T>>(.waiting)
    }

    /// Runs `body` under a coordinated write of `target`, waiting at most `timeout` for the file provider to grant it.
    /// Not granted in time: given up, as this download's failure, not the folder's. Once `body` has started it is left
    /// to finish: a copy is never cut off half way. A provider that refuses outright fails this file (`save` then asks
    /// the folder itself).
    private static func coordinatedWrite<T: Sendable>(
        at target: URL, options: NSFileCoordinator.WritingOptions, timeout: Duration,
        _ body: @escaping @Sendable (URL) throws(Failure) -> T
    ) throws(Failure) -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.writingIntent(with: target, options: options)
        let box = PhaseBox<T>()
        let done = DispatchSemaphore(value: 0)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        coordinator.coordinate(with: [intent], queue: queue) { error in
            let proceed = box.phase.withLock { phase -> Bool in
                guard case .waiting = phase else { return false }
                if error != nil {
                    // The provider refused this file; whether the folder is at fault is `save`'s probe to tell.
                    phase = .finished(.failure(.fileOnly("the folder's storage refused it")))
                    return false
                }
                phase = .working
                return true
            }
            if proceed {
                let result: Result<T, Failure>
                do throws(Failure) { result = .success(try body(intent.url)) } catch { result = .failure(error) }
                box.phase.withLock { $0 = .finished(result) }
            }
            done.signal()
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if done.wait(timeout: .now() + seconds) == .timedOut {
            let gaveUp = box.phase.withLock { phase -> Bool in
                guard case .waiting = phase else { return false }
                phase = .abandoned
                return true
            }
            if gaveUp {
                coordinator.cancel()
                throw .fileOnly("the folder took too long to answer")
            }
            done.wait()
        }
        guard case .finished(let result) = box.phase.withLock({ $0 }) else {
            throw .fileOnly("the folder took too long to answer")
        }
        return try result.get()
    }
}
