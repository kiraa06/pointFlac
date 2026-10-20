import Foundation
import os

/// Keeps the download queue across launches as one small JSON file.
///
/// The queue is a list of intentions plus history, not library data, so plain JSON is enough; the library database
/// (spec §5.4) stays the source of truth for music.
public struct DownloadQueueStore: Sendable {
    /// A queue file larger than this is treated as damaged rather than read into memory.
    public static let maxFileBytes = 16 * 1024 * 1024

    public let url: URL
    private static let log = Logger(subsystem: "io.github.kiraa06.pointflac", category: "downloads")

    public init(url: URL) {
        self.url = url
    }

    /// The saved queue, or an empty one when there is none or it cannot be read.
    public func load() -> [DownloadItem] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            return []
        }
        guard size <= Self.maxFileBytes else {
            Self.log.error("download queue file is \(size, privacy: .public) bytes; ignoring it")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Snapshot.self, from: data).items
        } catch {
            Self.log.error("download queue file unreadable: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Writes atomically, so a crash mid-write leaves the previous queue rather than half a file.
    public func save(_ items: [DownloadItem]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Snapshot(version: 1, items: items))
        try data.write(to: url, options: [.atomic])
    }

    /// Versioned so a later format can migrate instead of discarding the queue.
    private struct Snapshot: Codable {
        var version: Int
        var items: [DownloadItem]
    }
}
