import Foundation
import PFDownloads
import PFLibrary

/// `DownloadManager`'s publish step: puts each validated download where Settings → Downloads says, and never loses one.
///
/// - "In pointFlac" (the default): the library imports the file into its own folder (`Library.importFiles`, a copy
///   into `Documents/Library`), then the staged file is deleted, so a download is moved, not duplicated, and
///   publishing the same file twice is harmless. A refusal throws, so the job shows as failed instead of done.
/// - A folder picked in Files: the bookmark is resolved (and refreshed when stale) and its security scope opened; the
///   file is copied in at `<Artist>/<Album>/` by `DownloadDestination`, which never overwrites; the library, which
///   reads that folder in place, admits the file, and the catalog is checked for it. Only then is the staged file
///   deleted, and the scope closed.
/// - Should any of that fail (the folder deleted, access refused, no space, iCloud unavailable, the library not
///   reading the folder), the download falls back to the import above, so it still finishes. A copy this call made in
///   the folder is taken back first, so the song is not in the library twice. The folder is marked unavailable for
///   Settings, and the job's row says "Saved in pointFlac (folder unavailable)". Later downloads go straight to the
///   app, saying the same, until the user chooses the folder again.
///
/// The copy runs on the folder queue (`DownloadFolderStore.perform`), the library's work on its own queue: never
/// blocking file I/O on Swift's cooperative pool.
final class DownloadPublisher: Sendable {
    /// The Downloads row's state line for a song saved in the app because the folder could not be reached.
    static let fallbackNote = "Saved in pointFlac (folder unavailable)"

    private let library: Library
    private let store: DownloadFolderStore
    /// Tells Settings the folder went unavailable.
    private let folderWentUnavailable: @Sendable () async -> Void

    init(
        library: Library, store: DownloadFolderStore,
        folderWentUnavailable: @escaping @Sendable () async -> Void = {}
    ) {
        self.library = library
        self.store = store
        self.folderWentUnavailable = folderWentUnavailable
    }

    /// Publishes `staged` (the validated download, `track`'s file), returning the row's note, or nil for "Done".
    func publish(_ staged: URL, track: RemoteTrack) async throws -> String? {
        guard let choice = store.choice else {
            try await importIntoApp(staged)
            return nil
        }
        if !choice.unavailable {
            do {
                try await saveToFolder(staged, track: track)
                return nil
            } catch {
                DownloadFolderStore.log.error(
                    "download folder unreachable, saving in the app: \(String(describing: error), privacy: .private)")
                store.markUnavailable(choice)
                await folderWentUnavailable()
            }
        }
        try await importIntoApp(staged)
        return Self.fallbackNote
    }

    private func saveToFolder(_ staged: URL, track: RemoteTrack) async throws {
        let store = store
        let access = try await DownloadFolderStore.perform { try store.open() }
        defer { access.close() }
        // A folder the library does not read would hold the song where the shelf never shows it.
        guard await library.folder(containing: access.url) != nil else {
            throw DownloadFolderUnreachable("the library does not read the folder")
        }
        let saved = try await DownloadFolderStore.perform {
            try DownloadDestination().save(staged, track: track, into: access.url)
        }
        do {
            guard let id = try await library.admitFile(saved.url), library.current.tracks[id] != nil else {
                throw DownloadFolderUnreachable("the library could not read the saved file")
            }
        } catch {
            if saved.isNew { try? await DownloadFolderStore.perform { Self.takeBack(saved.url) } }
            throw error
        }
        try? FileManager.default.removeItem(at: staged)
    }

    /// The import into the app's own library folder, as before download folders: the fallback, and the default.
    private func importIntoApp(_ staged: URL) async throws {
        let result = await library.importFiles([staged])
        if let rejection = result.rejected.first {
            throw PublishError(message: "\(rejection.fileName): \(rejection.message)")
        }
        if let error = result.error { throw PublishError(message: error) }
        guard !result.added.isEmpty || result.duplicates > 0 else {
            throw PublishError(message: "the library did not take the file")
        }
        try? FileManager.default.removeItem(at: staged)
    }

    /// Deletes a copy this publish wrote into the folder, under a coordinated write, as the folder's provider expects.
    private static func takeBack(_ url: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) {
            try? FileManager.default.removeItem(at: $0)
        }
    }

    struct PublishError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
