import Foundation
import Observation
import PFLibrary
import Synchronization
import os

/// Why the picked download folder can't be used right now. Never shown word for word: Settings says "Unavailable".
struct DownloadFolderUnreachable: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The folder the user picked for downloads (Settings → Downloads → Save downloads to), readable from any thread: the
/// download publisher reads it off the main actor, and Settings changes it.
///
/// The choice is a bookmark, so the folder is found again after a relaunch, or after iOS moves it. A bookmark is
/// data, not a preference, so it lives in a small property list in Application Support (`DownloadFolder.plist`),
/// never in UserDefaults. Choosing "In pointFlac" again deletes the file and nothing else: the folder stays in the
/// library, and its songs with it.
///
/// `unavailable` is sticky. Once the folder could not be reached, new downloads are saved in the app until the user
/// chooses the folder again, so where a song goes never flips back and forth unannounced as iCloud comes and goes.
final class DownloadFolderStore: Sendable {
    struct Choice: Codable, Equatable, Sendable {
        /// The folder's bookmark. Nil only for DEBUG's `-PFDownloadFolder`, which gives a plain path instead.
        var bookmark: Data?
        /// DEBUG's `-PFDownloadFolder <absolute path>`: a plain folder, used without a bookmark or security scope, so
        /// a UI test on the simulator can choose one. Never saved.
        var path: String?
        /// The folder's name when it was picked, shown even when the folder can't be reached.
        var name: String
        var unavailable = false
    }

    /// Counts and kinds only, never names or paths (spec §5.8).
    static let log = Logger(subsystem: "app.pointflac", category: "download-folder")
    /// The default place for the choice, beside the library database.
    static var defaultFile: URL { URL.applicationSupportDirectory.appending(path: "DownloadFolder.plist") }
    /// One serial queue for blocking folder work (bookmarks, the copy into the folder), so none of it runs on Swift's
    /// cooperative pool or the main actor.
    private static let queue = DispatchQueue(label: "io.github.kiraa06.pointflac.download-folder", qos: .utility)

    private let state: Mutex<Choice?>
    /// Where the choice is saved; nil keeps it for this launch only (DEBUG's `-PFDownloadFolder`).
    private let file: URL?

    /// Reads the saved choice from `file`; a missing or unreadable file means "In pointFlac".
    init(file: URL) {
        self.file = file
        let saved = (try? Data(contentsOf: file)).flatMap { try? PropertyListDecoder().decode(Choice.self, from: $0) }
        state = Mutex(saved)
    }

    #if DEBUG
        /// DEBUG's `-PFDownloadFolder <absolute path>`: that folder for this launch, with no bookmark and nothing saved.
        init(debugPath: String) {
            file = nil
            let url = URL(filePath: debugPath, directoryHint: .isDirectory)
            state = Mutex(Choice(bookmark: nil, path: url.path, name: url.lastPathComponent))
        }
    #endif

    var choice: Choice? { state.withLock { $0 } }

    /// Replaces the choice and saves it; nil goes back to "In pointFlac" and deletes the saved file.
    func choose(_ choice: Choice?) throws {
        state.withLock { $0 = choice }
        try save(choice)
    }

    /// Marks `choice` unreachable, unless the user has chosen another folder since it was read.
    func markUnavailable(_ choice: Choice) {
        let marked = state.withLock { current -> Choice? in
            guard var now = current, now.bookmark == choice.bookmark, now.path == choice.path, !now.unavailable else {
                return nil
            }
            now.unavailable = true
            current = now
            return now
        }
        guard let marked else { return }
        do { try save(marked) } catch { Self.log.error("could not save the download folder's state") }
    }

    /// Resolves the chosen folder and opens its security scope, refreshing a stale bookmark. Blocking: call it on
    /// `perform`'s queue. Throws when no folder is chosen or it can't be found.
    func open() throws -> FolderAccess {
        guard let choice else { throw DownloadFolderUnreachable("no folder is chosen") }
        if let path = choice.path {
            return FolderAccess(url: URL(filePath: path, directoryHint: .isDirectory), scoped: false)
        }
        guard let bookmark = choice.bookmark else { throw DownloadFolderUnreachable("the choice has no bookmark") }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw DownloadFolderUnreachable("the bookmark no longer resolves: \(error.localizedDescription)")
        }
        // False when the URL needs no scope; a folder that does need one and refuses fails at the copy instead.
        let scoped = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            refresh(bookmark, to: fresh)
        }
        return FolderAccess(url: url, scoped: scoped)
    }

    /// Runs blocking folder work on the folder queue.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Swaps a stale bookmark for a fresh one, if the choice is still the same folder.
    private func refresh(_ old: Data, to fresh: Data) {
        let updated = state.withLock { current -> Choice? in
            guard var now = current, now.bookmark == old else { return nil }
            now.bookmark = fresh
            current = now
            return now
        }
        guard let updated else { return }
        do { try save(updated) } catch { Self.log.error("could not save the refreshed download folder bookmark") }
    }

    /// Written atomically, readable while the phone is locked after its first unlock: a download that finds the
    /// folder gone may need to say so with the screen off.
    private func save(_ choice: Choice?) throws {
        guard let file else { return }
        guard let choice else {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(choice).write(
            to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The picked folder, resolved, with its security scope held until `close()`, which is called exactly once.
final class FolderAccess: Sendable {
    let url: URL
    private let scoped: Bool

    init(url: URL, scoped: Bool) {
        self.url = url
        self.scoped = scoped
    }

    func close() {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

/// Settings' view of where downloads go: "In pointFlac" (the default), the folder the user picked in Files, or that
/// folder while it can't be reached. Picking a folder adds it to the library as a folder read in place, so the songs
/// already in it appear on the shelf, and the delete rules for such folders apply to them: deleting removes a song
/// from pointFlac, never the file.
@MainActor
@Observable
final class DownloadFolder {
    enum Status: Equatable {
        case app
        case folder(name: String)
        case unavailable(name: String)
    }

    private(set) var status: Status = .app
    /// Why the latest pick was refused, for the destination screen; cleared by the next pick or by "In pointFlac".
    private(set) var pickError: String?
    /// True while a picked folder is being added to the library: its first scan reads every song in it.
    private(set) var isAdding = false

    @ObservationIgnored let store: DownloadFolderStore
    @ObservationIgnored private let library: RealLibrary

    init(store: DownloadFolderStore, library: RealLibrary) {
        self.store = store
        self.library = library
        refresh()
    }

    /// The Settings row's value: "pointFlac", the folder's name, or "Unavailable".
    var summary: String {
        switch status {
        case .app: "pointFlac"
        case .folder(let name): name
        case .unavailable: "Unavailable"
        }
    }

    /// Reads the store again, after the publisher marked the folder unavailable.
    func refresh() {
        let next: Status =
            switch store.choice {
            case nil: .app
            case let choice? where choice.unavailable: .unavailable(name: choice.name)
            case let choice?: .folder(name: choice.name)
            }
        if next != status { status = next }
    }

    /// At launch, before any download is published: a folder whose bookmark no longer resolves (deleted, its volume
    /// gone) is marked unavailable now, so Settings says so before a download has to find out. DEBUG's plain folder is
    /// added to the library here, as a pick would add it.
    func start() async {
        guard let choice = store.choice, !choice.unavailable else { return }
        if let path = choice.path {
            do {
                try await addToLibrary(URL(filePath: path, directoryHint: .isDirectory))
            } catch {
                store.markUnavailable(choice)
            }
        } else {
            let store = store
            let reachable =
                (try? await DownloadFolderStore.perform {
                    let access = try store.open()
                    defer { access.close() }
                    return FileManager.default.fileExists(atPath: access.url.path)
                }) ?? false
            if !reachable { store.markUnavailable(choice) }
        }
        refresh()
    }

    /// The user picked `url` in the folder picker: remember it and read it in place. Refused for a folder inside the
    /// app's own container, which deleting the app would take with it, defeating the point.
    func choose(_ url: URL) async {
        pickError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard !Self.isInsideApp(url) else {
            pickError =
                "That folder is inside pointFlac, so deleting the app would delete it too. "
                + "Choose one in iCloud Drive or On My iPhone, outside pointFlac."
            return
        }
        isAdding = true
        defer { isAdding = false }
        do {
            let bookmark = try await DownloadFolderStore.perform {
                try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            try await addToLibrary(url)
            try store.choose(.init(bookmark: bookmark, path: nil, name: url.lastPathComponent))
            DownloadFolderStore.log.info("download folder chosen")
        } catch LibraryError.overlappingFolder {
            pickError =
                "pointFlac already reads a folder inside “\(url.lastPathComponent)”. Choose that folder, or another one."
        } catch {
            pickError = "Couldn't use “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
        refresh()
        await library.sync()
    }

    /// The folder picker itself failed (not a cancel, which reports nothing).
    func pickerFailed(_ error: any Error) {
        pickError = "The picker failed: \(error.localizedDescription)"
    }

    /// Back to the default. Only new downloads are affected: the folder stays in the library, its files untouched.
    func useApp() {
        pickError = nil
        do { try store.choose(nil) } catch { DownloadFolderStore.log.error("could not forget the download folder") }
        refresh()
    }

    /// Adds `url` to the library as a folder read in place, through the library's own `addFolder` (which reuses the
    /// record of a folder added before). A folder inside one the library already reads is read already: it is
    /// reused, not refused as overlapping.
    private func addToLibrary(_ url: URL) async throws {
        do {
            try await library.library.addFolder(url)
        } catch LibraryError.overlappingFolder(let name) {
            guard await library.library.folder(containing: url) != nil else {
                throw LibraryError.overlappingFolder(name)
            }
        }
    }

    /// Whether `url` is in the app's own container (its Documents folder shows in Files as On My iPhone → pointFlac).
    private static func isInsideApp(_ url: URL) -> Bool {
        func comparable(_ url: URL) -> String {
            var path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
            return path.hasSuffix("/") ? path : path + "/"
        }
        return comparable(url).hasPrefix(comparable(URL.homeDirectory))
    }
}
