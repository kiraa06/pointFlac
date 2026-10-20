import Foundation
import PFCore
import PFFlac

/// A FLAC file in the library folder, with what the import read from it.
public struct ImportedFile: Sendable, Hashable, Identifiable {
    /// The file's name in the library folder, which makes it unique there.
    public var id: String
    /// The copy in the library folder, never the file the user picked.
    public var url: URL
    /// The TITLE tag, or the file name without its extension when the file has none.
    public var title: String
    /// The ARTIST tag, or empty.
    public var artist: String
    /// The ALBUM tag, or empty.
    public var album: String
    public var format: AudioFormat
    /// Total frames from STREAMINFO, or 0 when the encoder did not record them.
    public var totalFrames: Int64
    /// The file's content identity (`ContentIdentity`): unlike `id`, it survives renames, moves and tag edits, so the
    /// library keys play history and the like on it (spec §5.4).
    public var contentID: String

    /// Whether v1 can play the file. A multichannel file is imported, per spec §5.3, but marked "not supported in v1"
    /// and never played (`ChannelPolicy`). Derived from `format`, so it can never disagree with it.
    public var isSupported: Bool { ChannelPolicy.isPlayable(format) }

    public init(
        id: String, url: URL, title: String, artist: String, album: String, format: AudioFormat, totalFrames: Int64,
        contentID: String
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.format = format
        self.totalFrames = totalFrames
        self.contentID = contentID
    }
}

/// A picked file the inbox refused, and why.
public struct ImportRejection: Sendable, Hashable {
    /// The name of the file as the user picked it.
    public var fileName: String
    /// `.unreadable` when the file is over the size bound; `exceedsSizeLimit` says so.
    public var reason: FlacRejection
    /// The file is larger than the inbox admits (spec §5.8). Kept beside `reason` rather than as a new
    /// `FlacRejection` case, which is the validator's vocabulary and is switched over exhaustively elsewhere.
    public var exceedsSizeLimit: Bool

    public init(fileName: String, reason: FlacRejection, exceedsSizeLimit: Bool = false) {
        self.fileName = fileName
        self.reason = reason
        self.exceedsSizeLimit = exceedsSizeLimit
    }

    /// What the UI tells the user. Only the two cases a user can act on get their own words; every other reason means
    /// the file is FLAC but broken, and the precise fault is of no use to them.
    public var message: String {
        if exceedsSizeLimit { return "Too large to add" }
        return switch reason {
        case .badMagic: "Not a FLAC file"
        case .notFlacName: "Only .flac files can be added"
        default: "Damaged or incomplete FLAC"
        }
    }
}

/// Brings picked files into the app's library folder.
///
/// Each source is validated where it is, before anything is copied, so a file that is not real FLAC never reaches the
/// library folder. Files that pass are copied in, because a picked URL is only lent to the app: its security scope
/// ends, and the provider may move or evict the file.
///
/// The copy goes to a hidden temporary file in the library folder first, and takes its real name only once it is
/// complete and has passed again: it is read for its tags, which re-checks it, and then renamed, which is atomic. So
/// a copy that fails part-way (a full disk, a provider file evicted mid-read) or that no longer passes (the source
/// changed after the check) never occupies a library name, and its temporary file is removed. An app killed mid-copy
/// leaves the temporary file behind; the next inbox over the folder removes it before its first import.
///
/// Sources from the document picker are security scoped. Access is started before the inbox touches a source and
/// stopped as soon as that source is done, whatever the outcome. URLs that are not security scoped (the app's own
/// bundle, a temporary folder) do not need it, and work the same. Each source is read under an `NSFileCoordinator`
/// read, so a file provider (iCloud Drive) can fetch an evicted file first and nobody writes it mid-copy.
///
/// A source over `maxFileBytes` is refused before it is read (spec §5.8: untrusted input has explicit limits).
///
/// A source with the same name and byte size as a file already in the library is a duplicate, and is skipped: it is
/// neither added nor rejected. A source with the same name and another size is a different file. It is added under
/// the first free numbered name ("Song 2.flac"), and the numbered names count for the duplicate rule too.
///
/// Names starting with "." are refused like names without ".flac": a hidden file would be copied in and never listed.
///
/// All file work runs on one private serial queue, never on Swift's cooperative pool, whose few threads must not
/// block on a slow provider or a large copy (Plan 1 hand-off, entry gate). The queue also runs one import or listing at
/// a time, so they never interleave. Use one inbox per folder: a second one would sweep away the first one's temporary
/// files.
///
/// `list()` keeps an index of what it read, keyed by name with size and modification date, so a listing re-reads only
/// files that are new or changed since the last one.
public actor ImportInbox {
    /// Temporary files are named `.import-<UUID>.flac`. Hidden, so neither `list()` nor the Files app shows them, and
    /// no library file can have the name, since hidden names are refused. The `.flac` ending is for the validator,
    /// which refuses any other name.
    static let temporaryPrefix = ".import-"
    static let temporarySuffix = ".flac"

    /// 8 GiB: above any real album image (a 24/192 stereo hour is about 2.5 GB as FLAC), far below a full device.
    public static let defaultMaxFileBytes: Int64 = 8 << 30

    private let worker: InboxWorker

    /// - Parameters:
    ///   - libraryFolder: where imported files are kept. Created by the first import if missing.
    ///   - maxFileBytes: sources larger than this are refused.
    public init(libraryFolder: URL, maxFileBytes: Int64 = ImportInbox.defaultMaxFileBytes) {
        self.init(
            libraryFolder: libraryFolder, maxFileBytes: maxFileBytes,
            copy: { try FileManager.default.copyItem(at: $0, to: $1) })
    }

    /// For tests: `copy` stands in for `FileManager.copyItem(at:to:)`.
    init(
        libraryFolder: URL, maxFileBytes: Int64 = ImportInbox.defaultMaxFileBytes,
        copy: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        worker = InboxWorker(libraryFolder: libraryFolder, maxFileBytes: maxFileBytes, copy: copy)
    }

    /// Validates `urls` in order and copies the valid ones into the library folder.
    ///
    /// - Returns: the files added, in the order given, and the files refused. Duplicates appear in neither.
    public func importFiles(_ urls: [URL]) async -> (added: [ImportedFile], rejected: [ImportRejection]) {
        let result = await worker.run { $0.importFiles(urls) }
        return (result.added, result.rejected)
    }

    /// The library's FLAC files, ordered by name as the Files app orders them. Files that no longer read as FLAC are
    /// left out.
    public func list() async -> [ImportedFile] {
        await worker.run { $0.list() }
    }

    /// For tests: how many files the inbox has parsed for its listings.
    func listingParses() async -> Int {
        await worker.run { $0.listingParses }
    }
}

/// The inbox's state and file work, confined to `queue`.
///
/// `@unchecked Sendable` because every member is touched only from inside `run`, on the serial `queue`; the actor
/// in front holds it only to hand work to that queue.
final class InboxWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.kiraa06.pointflac.import-inbox", qos: .utility)
    private let libraryFolder: URL
    private let maxFileBytes: Int64
    private let fileManager = FileManager.default
    /// Copies a source to a path in the library folder. Injectable so tests can fail a copy part-way through.
    private let copy: @Sendable (URL, URL) throws -> Void
    /// What `list()` last read, by file name.
    private var index: [String: (size: Int64, modified: Date, file: ImportedFile?)] = [:]
    private(set) var listingParses = 0

    init(libraryFolder: URL, maxFileBytes: Int64, copy: @escaping @Sendable (URL, URL) throws -> Void) {
        self.libraryFolder = libraryFolder
        self.maxFileBytes = maxFileBytes
        self.copy = copy
        // First on the serial queue, so it finishes before any import can start.
        queue.async { Self.removeTemporaryFiles(in: libraryFolder) }
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (InboxWorker) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body(self)) }
        }
    }

    struct ImportResult: Sendable {
        var added: [ImportedFile] = []
        var rejected: [ImportRejection] = []
    }

    func importFiles(_ urls: [URL]) -> ImportResult {
        var result = ImportResult()
        for source in urls {
            switch importFile(source) {
            case .added(let file): result.added.append(file)
            case .duplicate: break
            case .rejected(let reason, let tooLarge):
                result.rejected.append(
                    ImportRejection(fileName: source.lastPathComponent, reason: reason, exceedsSizeLimit: tooLarge))
            }
        }
        return result
    }

    func list() -> [ImportedFile] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: libraryFolder.path) else {
            index = [:]
            return []
        }
        var seen: [String: (size: Int64, modified: Date, file: ImportedFile?)] = [:]
        for name in names where name.lowercased().hasSuffix(".flac") && !name.hasPrefix(".") {
            let url = libraryFolder.appending(path: name)
            guard let stamp = Self.stamp(of: url) else { continue }
            if let known = index[name], known.size == stamp.size, known.modified == stamp.modified {
                seen[name] = known
                continue
            }
            listingParses += 1
            let file = (try? FlacMetadataReader.read(fileAt: url, includePictures: false)).flatMap { metadata in
                ContentIdentity.compute(fileAt: url).map {
                    Self.record(name: name, url: url, metadata: metadata, contentID: $0)
                }
            }
            seen[name] = (stamp.size, stamp.modified, file)
        }
        index = seen
        return seen.values.compactMap(\.file).sorted { a, b in
            let order = Self.stem(a.id).localizedStandardCompare(Self.stem(b.id))
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    private enum Outcome {
        case added(ImportedFile)
        case duplicate
        case rejected(FlacRejection, tooLarge: Bool = false)
    }

    private func importFile(_ source: URL) -> Outcome {
        // Before the source is opened, like the validator's own name rule.
        guard !source.lastPathComponent.hasPrefix(".") else { return .rejected(.notFlacName) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
        var outcome = Outcome.rejected(.unreadable)
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source, options: [.withoutChanges], error: &coordinationError
        ) { readable in
            outcome = importCoordinated(readable, name: source.lastPathComponent)
        }
        // A provider that could not fetch the file (offline iCloud, say) fails the coordination itself.
        return coordinationError == nil ? outcome : .rejected(.unreadable)
    }

    /// The import of one source, inside its coordinated read. `name` is the name the user picked, which the
    /// coordinator's URL keeps.
    private func importCoordinated(_ source: URL, name: String) -> Outcome {
        guard name.lowercased().hasSuffix(".flac") else { return .rejected(.notFlacName) }
        guard let size = Self.size(of: source) else { return .rejected(.unreadable) }
        guard size <= maxFileBytes else { return .rejected(.unreadable, tooLarge: true) }
        do throws(FlacRejection) {
            _ = try FlacValidator.validate(fileAt: source)
        } catch {
            return .rejected(error)
        }
        guard let destination = destination(for: name, size: size) else { return .duplicate }

        let temporary = libraryFolder.appending(
            path: ImportInbox.temporaryPrefix + UUID().uuidString + ImportInbox.temporarySuffix)
        // After the rename there is nothing left to remove. On every other path this removes what the copy wrote.
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
            try copy(source, temporary)
        } catch {
            // A failed copy (no space left, say) has no rejection of its own, and is reported as unreadable.
            return .rejected(.unreadable)
        }
        let metadata: FlacMetadata
        do throws(FlacRejection) {
            metadata = try FlacMetadataReader.read(fileAt: temporary, includePictures: false)
        } catch {
            return .rejected(error)
        }
        guard let contentID = ContentIdentity.compute(fileAt: temporary) else { return .rejected(.unreadable) }
        do {
            // A rename within the folder: atomic, and it never replaces a file that took the name meanwhile.
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            return .rejected(.unreadable)
        }
        return .added(
            Self.record(
                name: destination.lastPathComponent, url: destination, metadata: metadata, contentID: contentID))
    }

    /// Where a source called `name` of `size` bytes goes: `name`, or else the first free "stem N.ext". Nil when the
    /// library already has it, under `name` or one of those numbered names, at the same size. A name taken by anything
    /// else, a folder say, is never free.
    private func destination(for name: String, size: Int64) -> URL? {
        let stem = Self.stem(name)
        let pathExtension = (name as NSString).pathExtension
        for number in 1... {
            let candidate = number == 1 ? name : "\(stem) \(number).\(pathExtension)"
            let url = libraryFolder.appending(path: candidate)
            guard fileManager.fileExists(atPath: url.path) else { return url }
            if Self.size(of: url) == size { return nil }
        }
        return nil
    }

    /// The library file `name` at `url`, described by `metadata`.
    private static func record(name: String, url: URL, metadata: FlacMetadata, contentID: String) -> ImportedFile {
        ImportedFile(
            id: name, url: url, title: TagText.clean(metadata.title) ?? stem(name),
            artist: TagText.clean(metadata.artist) ?? "", album: TagText.clean(metadata.album) ?? "",
            format: metadata.streamInfo.format, totalFrames: metadata.streamInfo.totalFrames, contentID: contentID)
    }

    /// Removes what imports that never finished left behind: the app was killed mid-copy. Runs first on the inbox's
    /// queue, before it can import anything, so with one inbox per folder no copy is in flight.
    private static func removeTemporaryFiles(in folder: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names
        where name.hasPrefix(ImportInbox.temporaryPrefix) && name.hasSuffix(ImportInbox.temporarySuffix) {
            try? manager.removeItem(at: folder.appending(path: name))
        }
    }

    private static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    /// The size in bytes of the regular file at `url`; nil when there is none.
    private static func size(of url: URL) -> Int64? {
        stamp(of: url)?.size
    }

    /// Size and modification date of the regular file at `url`: what decides whether a listing re-reads it.
    private static func stamp(of url: URL) -> (size: Int64, modified: Date)? {
        guard
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .contentModificationDateKey,
            ]),
            values.isRegularFile == true, let size = values.fileSize
        else { return nil }
        return (Int64(size), values.contentModificationDate ?? .distantPast)
    }
}
