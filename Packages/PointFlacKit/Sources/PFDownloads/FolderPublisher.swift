import Foundation

/// Where Settings → Downloads says downloads go, as the publish step reads it at the start of each download.
public enum DownloadTarget: Sendable, Equatable {
    /// "In pointFlac": the app's own library folder.
    case app
    /// The folder the user picked, by the identity of that choice, which outlives a refreshed bookmark.
    case folder(UUID)
    /// The picked folder, known unreachable: downloads go to the app until it is back or chosen again.
    case unavailable(UUID)

    /// Whether this target is the choice `id`, reachable or not.
    func isChoice(_ id: UUID) -> Bool {
        switch self {
        case .folder(let chosen), .unavailable(let chosen): chosen == id
        case .app: false
        }
    }
}

/// What finding a picked folder in the library again did (`Library.reattachFolder`).
public enum FolderReattachment: Sendable {
    /// The library's record of the folder points at it again (it had moved, or was not found at launch).
    case reattached
    /// The library has no record of it: the user removed the folder from the library.
    case removed
    /// The library could not tell (a database error, a folder now overlapping another).
    case failed
}

/// A picked folder, resolved, with its security scope open until `close` (called exactly once).
public struct OpenedFolder: Sendable {
    public let url: URL
    public let close: @Sendable () -> Void

    public init(url: URL, close: @escaping @Sendable () -> Void) {
        self.url = url
        self.close = close
    }
}

/// `DownloadManager`'s publish step when the user can pick a folder for downloads: the decisions, with every outside
/// step (the folder, the library, the app's import) handed in as `Steps`, so each path is tested on its own.
///
/// - "In pointFlac": the app imports the file into its own library folder; then the staged file is deleted.
/// - A folder: it is opened (bookmark resolved, scope opened); a folder the library has lost track of (moved, renamed,
///   not found at launch) is found again; the file is copied in (`DownloadDestination`); the library admits that copy
///   and the catalog is checked for it. Only then is the staged file deleted, and the folder closed.
/// - A folder the user removed from the library is never added back: downloads go to the app from then on
///   (`folderRemoved`), rather than bringing back songs the user removed.
/// - Anything in that failing falls back to the app's import, so a download still finishes. A copy this download made
///   in the folder is taken back first, so the song is not in the library twice. The staged file is deleted only once
///   the import has the song; should the import fail too, the job fails with the file kept for a retry.
/// - Only the folder's own faults (it can't be found or is in the trash, access is refused, it is gone or not a
///   folder, its storage is not responding: `DownloadDestination.Failure.folderUnreachable`) mark it unavailable,
///   and only while it is still the choice. Anything else (one file the library refuses, a file in the way, too many
///   copies of a name, no space, a provider that took too long) falls back for that download alone, and its row says
///   why, while the folder stays chosen. A download whose folder the user switched away from meanwhile just says
///   "Saved in pointFlac".
///
/// Downloads go into the folder one at a time. Two jobs for the same song could otherwise both find one copy: one
/// adopting it as already saved while the other, failing, takes it back.
public final class FolderPublisher: Sendable {
    public struct Steps: Sendable {
        public var target: @Sendable () -> DownloadTarget
        public var markUnavailable: @Sendable (UUID) async -> Void
        /// Resolves and opens the picked folder; throws `DownloadDestination.Failure` (anything else counts as
        /// unreachable: a folder that can't even be found).
        public var open: @Sendable () async throws -> OpenedFolder
        public var libraryReads: @Sendable (URL) async -> Bool
        /// Finds the folder's record in the library again, never adding one (`Library.reattachFolder`).
        public var reattach: @Sendable (URL) async -> FolderReattachment
        /// The user removed the chosen folder `UUID` from the library: downloads go to the app from now on.
        public var folderRemoved: @Sendable (UUID) async -> Void
        /// Copies the staged file for the track into the folder; throws `DownloadDestination.Failure`.
        public var save: @Sendable (URL, RemoteTrack, URL) async throws -> DownloadDestination.Saved
        /// Has the library read the saved copy; returns its track ID, or nil when refused.
        public var admit: @Sendable (URL) async throws -> String?
        public var inCatalog: @Sendable (String) -> Bool
        /// Deletes a copy this download placed, if it is still the very file placed.
        public var takeBack: @Sendable (DownloadDestination.Saved) async -> Void
        /// The import into the app's own library folder; throws when the library did not keep the file.
        public var importIntoApp: @Sendable (URL) async throws -> Void
        public var deleteStaged: @Sendable (URL) -> Void

        public init(
            target: @escaping @Sendable () -> DownloadTarget,
            markUnavailable: @escaping @Sendable (UUID) async -> Void,
            open: @escaping @Sendable () async throws -> OpenedFolder,
            libraryReads: @escaping @Sendable (URL) async -> Bool,
            reattach: @escaping @Sendable (URL) async -> FolderReattachment,
            folderRemoved: @escaping @Sendable (UUID) async -> Void,
            save: @escaping @Sendable (URL, RemoteTrack, URL) async throws -> DownloadDestination.Saved,
            admit: @escaping @Sendable (URL) async throws -> String?,
            inCatalog: @escaping @Sendable (String) -> Bool,
            takeBack: @escaping @Sendable (DownloadDestination.Saved) async -> Void,
            importIntoApp: @escaping @Sendable (URL) async throws -> Void,
            deleteStaged: @escaping @Sendable (URL) -> Void
        ) {
            self.target = target
            self.markUnavailable = markUnavailable
            self.open = open
            self.libraryReads = libraryReads
            self.reattach = reattach
            self.folderRemoved = folderRemoved
            self.save = save
            self.admit = admit
            self.inCatalog = inCatalog
            self.takeBack = takeBack
            self.importIntoApp = importIntoApp
            self.deleteStaged = deleteStaged
        }
    }

    /// The Downloads row's line for a song saved in the app though a folder was chosen when it began: the user
    /// switched back to "In pointFlac" meanwhile, or removed the folder from the library.
    public static let inAppNote = "Saved in pointFlac"
    /// The Downloads row's line for a song saved in the app because the folder could not be reached.
    public static let unavailableNote = "Saved in pointFlac (folder unavailable)"
    /// The folder is fine but the library could not be made to read it, so the song would never reach the shelf.
    public static let notReadNote = "Saved in pointFlac (the library can't read the folder)"
    /// The copy went into the folder, but the library could not read it there.
    public static let notAdmittedNote = "Saved in pointFlac (the copy in the folder couldn't be read)"

    private let steps: Steps
    /// Internal for tests, which wait on its queue.
    let gate = SerialGate()

    public init(steps: Steps) {
        self.steps = steps
    }

    /// Publishes `staged` (`track`'s validated file) and returns the Downloads row's note, nil for a plain "Done".
    /// Throws only when the song is safe nowhere, so the job fails with its staged file kept for a retry.
    public func publish(_ staged: URL, track: RemoteTrack) async throws -> String? {
        let note: String?
        switch steps.target() {
        case .app:
            note = nil
        case .unavailable:
            note = Self.unavailableNote
        case .folder(let choice):
            let outcome = await gate.run { await self.saveToFolder(staged, track: track) }
            // The user may have chosen differently while this download was on its way.
            let stillChosen = steps.target().isChoice(choice)
            switch outcome {
            case .saved:
                return nil
            case .removedFromLibrary:
                await steps.folderRemoved(choice)
                note = Self.inAppNote
            case .fellBack(let why, let unreachable):
                if unreachable, stillChosen { await steps.markUnavailable(choice) }
                note = stillChosen ? why : Self.inAppNote
            }
        }
        try await steps.importIntoApp(staged)
        steps.deleteStaged(staged)
        return note
    }

    private enum FolderOutcome: Sendable {
        case saved
        case removedFromLibrary
        case fellBack(note: String, unreachable: Bool)

        static func failed(_ failure: DownloadDestination.Failure) -> FolderOutcome {
            failure.folderUnreachable
                ? .fellBack(note: FolderPublisher.unavailableNote, unreachable: true)
                : .fellBack(note: "Saved in pointFlac (\(failure.reason))", unreachable: false)
        }
    }

    private func saveToFolder(_ staged: URL, track: RemoteTrack) async -> FolderOutcome {
        let folder: OpenedFolder
        do {
            folder = try await steps.open()
        } catch let failure as DownloadDestination.Failure {
            return .failed(failure)
        } catch {
            return .failed(.unreachable("the folder can't be found"))
        }
        defer { folder.close() }
        // A folder the library does not read would hold the song where the shelf never shows it.
        if await !steps.libraryReads(folder.url) {
            switch await steps.reattach(folder.url) {
            case .removed: return .removedFromLibrary
            case .failed: return .fellBack(note: Self.notReadNote, unreachable: false)
            case .reattached: break
            }
            guard await steps.libraryReads(folder.url) else {
                return .fellBack(note: Self.notReadNote, unreachable: false)
            }
        }
        let saved: DownloadDestination.Saved
        do {
            saved = try await steps.save(staged, track, folder.url)
        } catch let failure as DownloadDestination.Failure {
            return .failed(failure)
        } catch {
            return .failed(.fileOnly("couldn't save it in the folder"))
        }
        let admitted = (try? await steps.admit(saved.url)) ?? nil
        guard let id = admitted, steps.inCatalog(id) else {
            if saved.isNew { await steps.takeBack(saved) }
            return .fellBack(note: Self.notAdmittedNote, unreachable: false)
        }
        steps.deleteStaged(staged)
        return .saved
    }
}

/// Runs one body at a time, in the order they arrive.
actor SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// For tests: returns once `count` callers are waiting their turn.
    func untilQueued(_ count: Int) async {
        if waiting.count >= count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    private func queue(_ continuation: CheckedContinuation<Void, Never>) {
        waiting.append(continuation)
        let ready = watchers.filter { $0.count <= waiting.count }
        watchers.removeAll { $0.count <= waiting.count }
        for watcher in ready { watcher.continuation.resume() }
    }

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { queue($0) }
        } else {
            busy = true
        }
        let result = await body()
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
        return result
    }
}
