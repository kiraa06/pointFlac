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
enum Admission {
    /// Checks `file` and moves it to its sanitised name in `staging`, returning the admitted file.
    static func admit(_ file: URL, staging: URL, track: RemoteTrack, maxBytes: Int64) throws(DownloadFailure) -> URL {
        let fileManager = FileManager.default
        let folder = staging.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = file.standardizedFileURL
        guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == folder else {
            throw DownloadFailure("the provider wrote outside its staging folder")
        }
        // `attributesOfItem` does not follow a final symlink, so a link to a file elsewhere is caught here.
        guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
            let type = attributes[.type] as? FileAttributeType
        else { throw DownloadFailure("the downloaded file is missing", retryable: true) }
        guard type == .typeRegular else { throw DownloadFailure("the download is not a plain file") }

        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw DownloadFailure("the downloaded file is empty") }
        guard size <= maxBytes else { throw DownloadFailure("the file is larger than \(maxBytes) bytes") }
        if let expected = track.sizeBytes, expected != size {
            let reason = size < expected ? "the download is incomplete" : "the download is larger than listed"
            throw DownloadFailure("\(reason) (\(size) of \(expected) bytes)")
        }

        guard let name = SafeFileName.sanitize(track.fileName) else {
            throw DownloadFailure("only .flac files are accepted")
        }
        let target = staging.appending(path: name, directoryHint: .notDirectory)
        do {
            if target.standardizedFileURL.path != candidate.path {
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.moveItem(at: candidate, to: target)
            }
            // Owner read/write only: a downloaded file is never executable.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            throw DownloadFailure("could not prepare the file: \(error.localizedDescription)", retryable: true)
        }

        do {
            _ = try FlacValidator.validate(fileAt: target)
        } catch {
            try? fileManager.removeItem(at: target)
            throw DownloadFailure("not a valid FLAC file (\(Self.reason(error)))")
        }
        return target
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
    /// Bytes available for user-initiated downloads, or `nil` when the volume does not say.
    public static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
