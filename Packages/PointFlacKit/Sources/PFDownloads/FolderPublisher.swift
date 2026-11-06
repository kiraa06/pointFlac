import Foundation

/// Where Settings → Downloads says downloads go, as the publish step reads it at the start of each download.
public enum DownloadTarget: Sendable, Equatable {
    /// "In pointFlac": the app's own library folder.
    case app
    /// The folder the user picked, by the identity of that choice, which outlives a refreshed bookmark.
    case folder(UUID)
    /// The picked folder, known unreachable: downloads go to the app until it is back or chosen again.
    case unavailable
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
/// - A folder: it is opened (bookmark resolved, scope opened); a folder the library does not read yet is added to
///   it; the file is copied in (`DownloadDestination`); the library admits that copy and the catalog is checked for
///   it. Only then is the staged file deleted, and the folder closed.
/// - Anything in that failing falls back to the app's import, so a download still finishes. A copy this download made
///   in the folder is taken back first, so the song is not in the library twice. The staged file is deleted only once
///   the import has the song; should the import fail too, the job fails with the file kept for a retry.
/// - Only the folder's own faults (it can't be found or is in the trash, access is refused, it is gone or not a
///   folder, it is full, its storage is not responding: `DownloadDestination.Failure.folderUnreachable`) mark it
///   unavailable, and only the choice that failed. Anything else (one file the library refuses, a file in the way,
///   too many copies of a name, a provider that took too long) falls back for that download alone, and its row says
///   why, while the folder stays chosen.
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
        public var addToLibrary: @Sendable (URL) async throws -> Void
        /// Copies the staged file for the track into the folder; throws `DownloadDestination.Failure`.
        public var save: @Sendable (URL, RemoteTrack, URL) async throws -> DownloadDestination.Saved
        /// Has the library read the saved copy; returns its track ID, or nil when refused.
        public var admit: @Sendable (URL) async throws -> String?
        public var inCatalog: @Sendable (String) -> Bool
        /// Deletes a copy this download placed, if it is still the very file placed.
        public var takeBack: @Sendable (DownloadDestination.Saved) async -> Void
        /// The import into the app's own library folder; throws when the library did not keep the file. Returns the
        /// library track it became (added, or already there), or nil when the library can't say.
        public var importIntoApp: @Sendable (URL) async throws -> String?
        public var deleteStaged: @Sendable (URL) -> Void

        public init(
            target: @escaping @Sendable () -> DownloadTarget,
            markUnavailable: @escaping @Sendable (UUID) async -> Void,
            open: @escaping @Sendable () async throws -> OpenedFolder,
            libraryReads: @escaping @Sendable (URL) async -> Bool,
            addToLibrary: @escaping @Sendable (URL) async throws -> Void,
            save: @escaping @Sendable (URL, RemoteTrack, URL) async throws -> DownloadDestination.Saved,
            admit: @escaping @Sendable (URL) async throws -> String?,
            inCatalog: @escaping @Sendable (String) -> Bool,
            takeBack: @escaping @Sendable (DownloadDestination.Saved) async -> Void,
            importIntoApp: @escaping @Sendable (URL) async throws -> String?,
            deleteStaged: @escaping @Sendable (URL) -> Void
        ) {
            self.target = target
            self.markUnavailable = markUnavailable
            self.open = open
            self.libraryReads = libraryReads
            self.addToLibrary = addToLibrary
            self.save = save
            self.admit = admit
            self.inCatalog = inCatalog
            self.takeBack = takeBack
            self.importIntoApp = importIntoApp
            self.deleteStaged = deleteStaged
        }
    }

    /// The Downloads row's line for a song saved in the app because the folder could not be reached.
    public static let unavailableNote = "Saved in pointFlac (folder unavailable)"
    /// The folder is fine but the library could not be made to read it, so the song would never reach the shelf.
    public static let notReadNote = "Saved in pointFlac (the library can't read the folder)"
    /// The copy went into the folder, but the library could not read it there.
    public static let notAdmittedNote = "Saved in pointFlac (the copy in the folder couldn't be read)"

    private let steps: Steps
    private let gate = SerialGate()

    public init(steps: Steps) {
        self.steps = steps
    }

    /// Publishes `staged` (`track`'s validated file) and returns the Downloads row's note (nil for a plain "Done")
    /// with the library track the song became: the one admitted from the folder, or the one the app's import added or
    /// already had. Throws only when the song is safe nowhere, so the job fails with its staged file kept for a retry.
    public func publish(_ staged: URL, track: RemoteTrack) async throws -> Publication {
        let note: String?
        switch steps.target() {
        case .app:
            note = nil
        case .unavailable:
            note = Self.unavailableNote
        case .folder(let choice):
            switch await gate.run({ await self.saveToFolder(staged, track: track) }) {
            case .saved(let trackID):
                return Publication(note: nil, trackID: trackID)
            case .fellBack(let why, let unreachable):
                if unreachable { await steps.markUnavailable(choice) }
                note = why
            }
        }
        let trackID = try await steps.importIntoApp(staged)
        steps.deleteStaged(staged)
        return Publication(note: note, trackID: trackID)
    }

    private enum FolderOutcome: Sendable {
        case saved(trackID: String)
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
            try? await steps.addToLibrary(folder.url)
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
        return .saved(trackID: id)
    }
}

/// Runs one body at a time, in the order they arrive.
actor SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
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
