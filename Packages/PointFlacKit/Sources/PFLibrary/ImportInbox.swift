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

    public init(
        id: String, url: URL, title: String, artist: String, album: String, format: AudioFormat, totalFrames: Int64
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.format = format
        self.totalFrames = totalFrames
    }
}

/// A picked file the inbox refused, and why.
public struct ImportRejection: Sendable, Hashable {
    /// The name of the file as the user picked it.
    public var fileName: String
    public var reason: FlacRejection

    public init(fileName: String, reason: FlacRejection) {
        self.fileName = fileName
        self.reason = reason
    }

    /// What the UI tells the user. Only the two cases a user can act on get their own words; every other reason means
    /// the file is FLAC but broken, and the precise fault is of no use to them.
    public var message: String {
        switch reason {
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
/// leaves the temporary file behind; the next inbox over the folder removes it when it is created.
///
/// Sources from the document picker are security scoped. Access is started before the inbox touches a source and
/// stopped as soon as that source is done, whatever the outcome. URLs that are not security scoped (the app's own
/// bundle, a temporary folder) do not need it, and work the same.
///
/// A source with the same name and byte size as a file already in the library is a duplicate, and is skipped: it is
/// neither added nor rejected. A source with the same name and another size is a different file. It is added under
/// the first free numbered name ("Song 2.flac"), and the numbered names count for the duplicate rule too.
///
/// Names starting with "." are refused like names without ".flac": a hidden file would be copied in and never listed.
///
/// The actor runs one import or listing at a time. Neither suspends while it works, so they never interleave. Use one
/// inbox per folder: a second one would sweep away the first one's temporary files.
public actor ImportInbox {
    /// Temporary files are named `.import-<UUID>.flac`. Hidden, so neither `list()` nor the Files app shows them, and
    /// no library file can have the name, since hidden names are refused. The `.flac` ending is for the validator,
    /// which refuses any other name.
    static let temporaryPrefix = ".import-"
    static let temporarySuffix = ".flac"

    private let libraryFolder: URL
    private let fileManager = FileManager.default
    /// Copies a source to a path in the library folder. Injectable so tests can fail a copy part-way through.
    private let copy: @Sendable (URL, URL) throws -> Void

    /// - Parameter libraryFolder: where imported files are kept. Created by the first import if missing.
    public init(libraryFolder: URL) {
        self.init(libraryFolder: libraryFolder, copy: { try FileManager.default.copyItem(at: $0, to: $1) })
    }

    /// For tests: `copy` stands in for `FileManager.copyItem(at:to:)`.
    init(libraryFolder: URL, copy: @escaping @Sendable (URL, URL) throws -> Void) {
        self.libraryFolder = libraryFolder
        self.copy = copy
        Self.removeTemporaryFiles(in: libraryFolder)
    }

    /// Validates `urls` in order and copies the valid ones into the library folder.
    ///
    /// - Returns: the files added, in the order given, and the files refused. Duplicates appear in neither.
    public func importFiles(_ urls: [URL]) async -> (added: [ImportedFile], rejected: [ImportRejection]) {
        var added: [ImportedFile] = []
        var rejected: [ImportRejection] = []
        for source in urls {
            switch importFile(source) {
            case .added(let file): added.append(file)
            case .duplicate: break
            case .rejected(let reason):
                rejected.append(ImportRejection(fileName: source.lastPathComponent, reason: reason))
            }
        }
        return (added, rejected)
    }

    /// The library's FLAC files, ordered by name as the Files app orders them. Files that no longer read as FLAC are
    /// left out.
    public func list() async -> [ImportedFile] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: libraryFolder.path) else { return [] }
        let files = names.filter { $0.lowercased().hasSuffix(".flac") && !$0.hasPrefix(".") }.compactMap { name in
            let url = libraryFolder.appending(path: name)
            return (try? FlacMetadataReader.read(fileAt: url, includePictures: false)).map {
                Self.record(name: name, url: url, metadata: $0)
            }
        }
        return files.sorted { a, b in
            let order = Self.stem(a.id).localizedStandardCompare(Self.stem(b.id))
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    private enum Outcome {
        case added(ImportedFile)
        case duplicate
        case rejected(FlacRejection)
    }

    private func importFile(_ source: URL) -> Outcome {
        // Before the source is opened, like the validator's own name rule.
        guard !source.lastPathComponent.hasPrefix(".") else { return .rejected(.notFlacName) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
        do throws(FlacRejection) {
            _ = try FlacValidator.validate(fileAt: source)
        } catch {
            return .rejected(error)
        }
        guard let size = Self.size(of: source) else { return .rejected(.unreadable) }
        guard let destination = destination(for: source.lastPathComponent, size: size) else { return .duplicate }

        let temporary = libraryFolder.appending(path: Self.temporaryPrefix + UUID().uuidString + Self.temporarySuffix)
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
        do {
            // A rename within the folder: atomic, and it never replaces a file that took the name meanwhile.
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            return .rejected(.unreadable)
        }
        return .added(Self.record(name: destination.lastPathComponent, url: destination, metadata: metadata))
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
    private static func record(name: String, url: URL, metadata: FlacMetadata) -> ImportedFile {
        ImportedFile(
            id: name, url: url, title: metadata.title ?? stem(name), artist: metadata.artist ?? "",
            album: metadata.album ?? "", format: metadata.streamInfo.format,
            totalFrames: metadata.streamInfo.totalFrames)
    }

    /// Removes what imports that never finished left behind: the app was killed mid-copy. Runs when an inbox is
    /// created, before it can import anything, so with one inbox per folder no copy is in flight.
    private static func removeTemporaryFiles(in folder: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(temporaryPrefix) && name.hasSuffix(temporarySuffix) {
            try? manager.removeItem(at: folder.appending(path: name))
        }
    }

    private static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    /// The size in bytes of the regular file at `url`; nil when there is none.
    private static func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true, let size = values.fileSize
        else { return nil }
        return Int64(size)
    }
}
