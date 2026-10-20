import Foundation

/// One peer's folder from a search: the unit §4.7 asks the UI to show ("grouped by peer and complete folder").
public struct SearchResultFolder: Sendable, Hashable, Identifiable {
    public var id: String { "\(peer)\u{0}\(folder)" }
    public var peer: String
    /// The remote folder path, as `browseFolder(_:of:)` expects it.
    public var folder: String
    /// The files the search matched, in track order. `browseFolder` lists the whole folder.
    public var files: [SearchResultFile]
    public var totalBytes: Int64
    public var freeSlot: Bool
    public var uploadSpeed: Int
    public var queueLength: Int
    public var bestBitsPerSample: Int?
    public var bestSampleRate: Int?

    /// Groups results by peer and folder. Folders whose peer has a free slot come first, then folders with more
    /// matching files, then faster peers: the order in which a download is most likely to start soon and be complete.
    public static func group(_ files: [SearchResultFile]) -> [SearchResultFolder] {
        let grouped = Dictionary(grouping: files) { "\($0.peer)\u{0}\($0.folder)" }
        return grouped.values.compactMap { members -> SearchResultFolder? in
            guard let first = members.first else { return nil }
            let sorted = members.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return SearchResultFolder(
                peer: first.peer, folder: first.folder, files: sorted,
                totalBytes: members.reduce(0) { $0 + $1.sizeBytes }, freeSlot: first.freeSlot,
                uploadSpeed: first.uploadSpeed, queueLength: first.queueLength,
                bestBitsPerSample: members.compactMap(\.bitsPerSample).max(),
                bestSampleRate: members.compactMap(\.sampleRate).max())
        }
        .sorted { lhs, rhs in
            if lhs.freeSlot != rhs.freeSlot { return lhs.freeSlot }
            if lhs.files.count != rhs.files.count { return lhs.files.count > rhs.files.count }
            if lhs.uploadSpeed != rhs.uploadSpeed { return lhs.uploadSpeed > rhs.uploadSpeed }
            return lhs.id < rhs.id
        }
    }

    /// The last folder component, usually "Album" or "Artist - Album".
    public var name: String { PathSanitizer.components(of: folder).last ?? folder }
}

extension SearchResultFile {
    /// The file name without its extension, for a title when no tags are known yet.
    public var displayTitle: String {
        (fileName as NSString).deletingPathExtension
    }

    /// The parent folder's name, which is usually the album.
    public var albumGuess: String? { PathSanitizer.components(of: folder).last }

    /// The grandparent folder's name, which is often the artist in `Artist\Album\track.flac` layouts.
    public var artistGuess: String? {
        let parts = PathSanitizer.components(of: folder)
        return parts.count >= 2 ? parts[parts.count - 2] : nil
    }

    /// Provider-specific fields for contract 1's `RemoteTrack.detail`.
    public var detail: [String: String] {
        [
            "peer": peer, "path": path, "folder": folder, "freeSlot": freeSlot ? "1" : "0",
            "speed": String(uploadSpeed), "queue": String(queueLength),
        ]
    }
}

extension SoulseekTransferEvent {
    /// The fraction for contract 1's `DownloadEvent.progress`; `nil` for every other event.
    public var fraction: Double? {
        switch self {
        case .progress(let received, let size) where size > 0: Double(received) / Double(size)
        case .started(let offset, let size) where size > 0: Double(offset) / Double(size)
        default: nil
        }
    }
}

extension SoulseekTransferFailure {
    /// A short reason for the downloads list (contract 1's `DownloadEvent.failed(String)`). Never includes a path.
    public var reason: String {
        switch self {
        case .notLoggedIn: "Not signed in to Soulseek"
        case .notFLAC: "Not a FLAC file"
        case .peerOffline: "The peer is offline"
        case .peerUnreachable: "Could not reach the peer"
        case .denied(let why): "The peer refused: \(why)"
        case .uploadFailed: "The peer's upload failed"
        case .sizeMismatch: "The peer offered a different file size"
        case .timeout: "Timed out"
        case .incomplete: "The transfer stopped early; it will resume from where it stopped"
        case .cancelled: "Cancelled"
        case .alreadyInProgress: "Already downloading"
        case .io(let what): "Could not save the file (\(what))"
        case .protocolViolation: "The peer broke the protocol"
        }
    }
}

extension PathSanitizer {
    /// Non-empty components of a backslash- or slash-separated remote path.
    static func components(of path: String) -> [String] {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
    }
}
