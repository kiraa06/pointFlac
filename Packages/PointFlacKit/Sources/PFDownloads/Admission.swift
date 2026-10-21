import Darwin
import Foundation
import PFFlac

/// Why a download stopped, in words the Downloads list can show.
public struct DownloadFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// Whether trying the same download again could help (a dropped connection) or not (a file that isn't FLAC).
    public var retryable: Bool

    public init(_ message: String, retryable: Bool = false) {
        self.message = message
        self.retryable = retryable
    }

    public var description: String { message }
}

/// The gate between a provider's staging folder and the library (spec §5.4 steps 2–3).
///
/// Everything a provider produced is untrusted. A file gets through only if it sits directly in its own staging
/// folder, is a regular file (never a symlink), has the size the provider promised, and passes the FLAC admission
/// rule (spec §5.3). The file is only ever opened by `FlacValidator`; it is never executed or opened as anything else.
///
/// A provider may run in-process (the Soulseek adapter writes peer bytes itself) and could, by mistake or design,
/// keep writing after it reported `.finished`. So admission works on a private snapshot: the file is cloned into a
/// fresh inode that only the manager knows (`COPYFILE_CLONE`, a copy where the volume cannot clone), the original is
/// removed, and the snapshot is checked through one open descriptor before and after validation. If its inode,
/// size, modification time or link count changes while it is checked, it is refused.
enum Admission {
    /// Checks `file` and leaves an admitted snapshot under its sanitised name in `staging`, returning it.
    static func admit(_ file: URL, staging: URL, track: RemoteTrack, maxBytes: Int64) throws(DownloadFailure) -> URL {
        let fileManager = FileManager.default
        let folder = staging.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = file.standardizedFileURL
        guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == folder else {
            throw DownloadFailure("the provider wrote outside its staging folder")
        }
        // lstat does not follow a final symlink, so a link to a file elsewhere is caught here.
        var info = stat()
        guard lstat(candidate.path, &info) == 0 else {
            throw DownloadFailure("the downloaded file is missing", retryable: true)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw DownloadFailure("the download is not a plain file") }
        guard let name = SafeFileName.sanitize(track.fileName) else {
            throw DownloadFailure("only .flac files are accepted")
        }
        let target = staging.appending(path: name, directoryHint: .notDirectory)

        // Snapshot into a hidden, unguessable name, then drop the provider's file.
        let snapshot = staging.appending(path: ".admitting-\(UUID().uuidString)", directoryHint: .notDirectory)
        guard
            copyfile(candidate.path, snapshot.path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)) == 0
        else { throw DownloadFailure("could not prepare the file (error \(errno))", retryable: true) }
        try? fileManager.removeItem(at: candidate)

        let descriptor = open(snapshot.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? fileManager.removeItem(at: snapshot)
            throw DownloadFailure("could not open the file (error \(errno))", retryable: true)
        }
        defer { close(descriptor) }
        func discard(_ failure: DownloadFailure) -> DownloadFailure {
            try? fileManager.removeItem(at: snapshot)
            try? fileManager.removeItem(at: target)
            return failure
        }

        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw discard(DownloadFailure("the download is not a plain file"))
        }
        let size = Int64(before.st_size)
        guard size > 0 else { throw discard(DownloadFailure("the downloaded file is empty")) }
        guard size <= maxBytes else { throw discard(DownloadFailure("the file is larger than \(maxBytes) bytes")) }
        if let expected = track.sizeBytes, expected != size {
            let reason = size < expected ? "the download is incomplete" : "the download is larger than listed"
            throw discard(DownloadFailure("\(reason) (\(size) of \(expected) bytes)"))
        }
        // Owner read/write only: a downloaded file is never executable.
        guard fchmod(descriptor, 0o600) == 0, rename(snapshot.path, target.path) == 0 else {
            throw discard(DownloadFailure("could not prepare the file (error \(errno))", retryable: true))
        }

        do {
            _ = try FlacValidator.validate(fileAt: target)
        } catch {
            throw discard(DownloadFailure("not a valid FLAC file (\(Self.reason(error)))"))
        }

        // The descriptor and the name must still be the same, unchanged file.
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0, lstat(target.path, &named) == 0,
            Self.sameFile(before, after), Self.sameFile(before, named), after.st_nlink == 1
        else { throw discard(DownloadFailure("the file changed while it was being checked")) }
        return target
    }

    /// Same inode on the same device, with the same size and modification time.
    static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }

    static func reason(_ rejection: FlacRejection) -> String {
        switch rejection {
        case .notFlacName: "not named .flac"
        case .badMagic: "wrong file signature"
        case .badID3: "damaged ID3 tag"
        case .missingStreamInfo: "no stream information"
        case .invalidStreamInfo(let detail): "bad stream information: \(detail)"
        case .tooManyBlocks: "too many metadata blocks"
        case .blockTooLarge: "oversized metadata block"
        case .badFrameHeader: "bad first audio frame"
        case .frameCRCMismatch: "first audio frame fails its checksum"
        case .truncated: "file ends early"
        case .unreadable: "file unreadable"
        }
    }
}

/// Free space on the volume that holds a folder.
public enum DiskSpace {
    /// Bytes available for user-initiated downloads, or `nil` when the volume does not say. A folder that does not
    /// exist yet is measured at its nearest existing parent, which is on the same volume.
    public static func available(at url: URL) -> Int64? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
