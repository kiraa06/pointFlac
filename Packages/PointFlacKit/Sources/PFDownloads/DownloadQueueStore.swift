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
    ///
    /// The file is untrusted input: its ids become staging folder names and `stagedFileName` a file name inside
    /// one. So items are decoded one at a time, and only those with a UUID id and a staged name that `SafeFileName`
    /// leaves unchanged are kept; one bad item never costs the rest of the queue. A file that cannot be read at all
    /// is moved aside, not overwritten, so it can still be inspected.
    public func load() -> [DownloadItem] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            return []
        }
        guard size <= Self.maxFileBytes else {
            Self.log.error("download queue file is \(size, privacy: .public) bytes; moving it aside")
            moveAside()
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(LossySnapshot.self, from: data).items
            let items = decoded.compactMap(\.value).filter(Self.isAcceptable)
            if items.count != decoded.count {
                Self.log.error("dropped \(decoded.count - items.count, privacy: .public) unreadable queue items")
            }
            return items
        } catch {
            Self.log.error("download queue file unreadable: \(String(describing: error), privacy: .public)")
            moveAside()
            return []
        }
    }

    /// Whether a loaded item is safe to turn into paths.
    static func isAcceptable(_ item: DownloadItem) -> Bool {
        guard UUID(uuidString: item.id) != nil else { return false }
        if let staged = item.stagedFileName { return SafeFileName.sanitize(staged) == staged }
        return true
    }

    /// Renames an unreadable queue file to `<name>.corrupt-<uuid>` beside it.
    private func moveAside() {
        let aside = url.deletingLastPathComponent().appending(
            path: url.lastPathComponent + ".corrupt-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    /// Writes atomically, so a crash mid-write leaves the previous queue rather than half a file. The queue says
    /// what the user downloads, so it is encrypted at rest and never leaves the device in a backup.
    ///
    /// Protection class: "until first user authentication", not "complete". pointFlac keeps playing and downloading
    /// with the screen locked, and a complete-protection file cannot be written then, so every state change while
    /// locked would fail. macOS (host tests) has no data-protection classes for this file, so none is requested there.
    public func save(_ items: [DownloadItem]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Snapshot(version: 1, items: items))
        #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: url, options: options)
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }

    /// Versioned so a later format can migrate instead of discarding the queue.
    private struct Snapshot: Codable {
        var version: Int
        var items: [DownloadItem]
    }

    private struct LossySnapshot: Decodable {
        var items: [Lossy<DownloadItem>]
    }

    /// Decodes one element, or `nil` instead of failing the whole array.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
