import Foundation
import Observation
import PFDownloads
import PFLibrary
import Synchronization
import os

/// The folder the user picked for downloads (Settings → Downloads → Save downloads to), readable from any thread: the
/// download publisher reads it off the main actor, and Settings changes it.
///
/// The choice is a bookmark, so the folder is found again after a relaunch, or after iOS moves it. A bookmark is
/// data, not a preference, so it lives in a small property list in Application Support (`DownloadFolder.plist`),
/// never in UserDefaults. Choosing "In pointFlac" again deletes the file and nothing else: the folder stays in the
/// library, and its songs with it.
///
/// A choice has an identity (`id`) of its own, so marking it unavailable or refreshing its bookmark never touches a
/// choice the user has made since, and a refreshed bookmark is still the same choice. `unavailable` is set only when
/// the folder itself can't take files (it can't be found or is in the trash, access is refused, it is gone or full),
/// and cleared when a later check finds it reachable again, or when it is chosen again. Every change is saved before
/// it takes effect, so what Settings shows is what the next launch finds.
final class DownloadFolderStore: Sendable {
    struct Choice: Codable, Equatable, Sendable {
        var id = UUID()
        /// The folder's bookmark. Nil only for DEBUG's `-PFDownloadFolder`, which gives a plain path instead.
        var bookmark: Data?
        /// DEBUG's `-PFDownloadFolder <absolute path>`: a plain folder, used without a bookmark or security scope, so
        /// a UI test on the simulator can choose one. Never saved.
        var path: String?
        /// The folder's name as Files showed it when it was picked ("iCloud Drive", not "com~apple~CloudDocs"),
        /// shown even when the folder can't be reached.
        var name: String
        var unavailable = false

        init(bookmark: Data?, path: String?, name: String) {
            self.bookmark = bookmark
            self.path = path
            self.name = name
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
            path = try values.decodeIfPresent(String.self, forKey: .path)
            name = try values.decode(String.self, forKey: .name)
            unavailable = try values.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        }
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

    /// Where the publish step sends the next download.
    var target: DownloadTarget {
        switch choice {
        case nil: .app
        case let choice? where choice.unavailable: .unavailable
        case let choice?: .folder(choice.id)
        }
    }

    /// Saves `choice` (nil: "In pointFlac", deleting the saved file), then makes it current. A failed save changes
    /// nothing.
    func choose(_ choice: Choice?) throws {
        try save(choice)
        state.withLock { $0 = choice }
    }

    /// Marks the choice `id` unreachable, unless the user has chosen again since.
    func markUnavailable(_ id: UUID) { setUnavailable(true, id) }

    /// Clears the mark on the choice `id`: its folder takes files again.
    func markAvailable(_ id: UUID) { setUnavailable(false, id) }

    private func setUnavailable(_ unavailable: Bool, _ id: UUID) {
        guard var changed = choice, changed.id == id, changed.unavailable != unavailable else { return }
        changed.unavailable = unavailable
        do { try save(changed) } catch { Self.log.error("could not save the download folder's state") }
        // Kept for this launch even if the save failed: the folder's state is a fact, not a preference.
        state.withLock { current in
            if current?.id == id { current?.unavailable = unavailable }
        }
    }

    /// Resolves the chosen folder and opens its security scope, refreshing a stale bookmark. Blocking: call it on
    /// `perform`'s queue. Throws `DownloadDestination.Failure`, unreachable, when no folder is chosen, its bookmark
    /// no longer resolves, or it resolves into a trash (a bookmark follows a folder deleted in Files into Recently
    /// Deleted, where downloads must not keep landing).
    func open() throws(DownloadDestination.Failure) -> OpenedFolder {
        guard let choice else { throw .unreachable("no folder is chosen") }
        if let path = choice.path {
            let url = URL(filePath: path, directoryHint: .isDirectory)
            guard !FolderLocation.isInTrash(url) else { throw .unreachable("the folder is in the trash") }
            return OpenedFolder(url: url) {}
        }
        guard let bookmark = choice.bookmark else { throw .unreachable("the choice has no bookmark") }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw .unreachable("the folder can't be found")
        }
        guard !FolderLocation.isInTrash(url) else { throw .unreachable("the folder is in the trash") }
        // False when the URL needs no scope; a folder that does need one and refuses fails at the copy instead.
        let scoped = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            refreshBookmark(of: choice.id, to: fresh)
        }
        return OpenedFolder(url: url) {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Runs blocking folder work on the folder queue.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Swaps a stale bookmark for a fresh one, if the choice is still `id`.
    private func refreshBookmark(of id: UUID, to fresh: Data) {
        guard var changed = choice, changed.id == id else { return }
        changed.bookmark = fresh
        do { try save(changed) } catch { Self.log.error("could not save the refreshed download folder bookmark") }
        state.withLock { current in
            if current?.id == id { current?.bookmark = fresh }
        }
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
    /// True while any picked folder is being added to the library: its first scan reads every song in it.
    var isAdding: Bool { addsRunning > 0 }
    private var addsRunning = 0

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

    /// Reads the store again, after the publisher or a check changed it.
    func refresh() {
        let next: Status =
            switch store.choice {
            case nil: .app
            case let choice? where choice.unavailable: .unavailable(name: choice.name)
            case let choice?: .folder(name: choice.name)
            }
        if next != status { status = next }
    }

    /// At launch, before any download is published. DEBUG's plain folder is added to the library here, as a pick would
    /// add it; then the folder is checked (`recheck`).
    func start() async {
        #if DEBUG
            if let path = store.choice?.path {
                try? await addToLibrary(URL(filePath: path, directoryHint: .isDirectory))
            }
        #endif
        await recheck()
    }

    /// Whether the chosen folder takes files now: its bookmark is resolved (a folder in the trash does not count) and
    /// a hidden file is written in it and removed. Run at launch and whenever the app returns to the foreground. A
    /// folder that fails for its own reasons is marked unavailable, so Settings says so before a download has to find
    /// out; one that is back clears the mark, and is added to the library again if the library had lost it.
    func recheck() async {
        guard let choice = store.choice else { return }
        let store = store
        let outcome: Result<Void, DownloadDestination.Failure>
        do {
            outcome = try await DownloadFolderStore.perform { () -> Result<Void, DownloadDestination.Failure> in
                do throws(DownloadDestination.Failure) {
                    let folder = try store.open()
                    defer { folder.close() }
                    try DownloadDestination.probe(folder.url)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        } catch {
            return  // The folder queue itself never throws: nothing was learnt.
        }
        switch outcome {
        case .success:
            store.markAvailable(choice.id)
            await readInLibrary()
        case .failure(let failure):
            if failure.folderUnreachable { store.markUnavailable(choice.id) }
        }
        refresh()
    }

    /// The user picked `url` in the folder picker: remember it and read it in place. Refused for a folder inside the
    /// app's own container, which deleting the app would take with it, and for one in the trash.
    func choose(_ url: URL) async {
        pickError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard !FolderLocation.isInside(url, container: URL.homeDirectory) else {
            pickError =
                "That folder is inside pointFlac, so deleting the app would delete it too. "
                + "Choose one in iCloud Drive or On My iPhone, outside pointFlac."
            return
        }
        guard !FolderLocation.isInTrash(url) else {
            pickError = "That folder is in Recently Deleted. Choose another one."
            return
        }
        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? url.lastPathComponent
        addsRunning += 1
        defer { addsRunning -= 1 }
        do {
            let bookmark = try await DownloadFolderStore.perform {
                try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            try await addToLibrary(url)
            try store.choose(.init(bookmark: bookmark, path: nil, name: name))
            DownloadFolderStore.log.info("download folder chosen")
        } catch LibraryError.overlappingFolder {
            pickError = "pointFlac already reads a folder inside “\(name)”. Choose that folder, or another one."
        } catch {
            pickError = "Couldn't use “\(name)”: \(error.localizedDescription)"
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

    /// Adds the chosen folder to the library when the library does not read it (its bookmark failed at launch, say).
    private func readInLibrary() async {
        let store = store
        guard let folder = try? await DownloadFolderStore.perform({ try store.open() }) else { return }
        defer { folder.close() }
        if await library.library.folder(containing: folder.url) == nil { try? await addToLibrary(folder.url) }
    }

    /// Adds `url` to the library as a folder read in place, through the library's own `addFolder` (which reuses the
    /// record of a folder added before, found at this launch or not). A folder inside one the library already reads is
    /// read already: it is reused, not refused as overlapping.
    private func addToLibrary(_ url: URL) async throws {
        do {
            try await library.library.addFolder(url)
        } catch LibraryError.overlappingFolder(let name) {
            guard await library.library.folder(containing: url) != nil else {
                throw LibraryError.overlappingFolder(name)
            }
        }
    }
}
