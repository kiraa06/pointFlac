import Foundation
import PFDownloads
import PFLibrary

/// `DownloadManager`'s publish step for the app: `FolderPublisher`'s decisions (tested in PFDownloads), wired to the
/// real folder choice, the library and the file system.
///
/// In short: with no folder chosen, the library imports the download into its own folder. With one chosen, the song
/// is filed at `<Artist>/<Album>/` in it, admitted by the library from there and checked in the catalog before the
/// staged file goes. Whatever goes wrong there, the download falls back to the import, so it still finishes; only
/// the folder's own faults mark it unavailable for Settings, and each fallback's Downloads row says why.
///
/// Folder work (resolving, copying, taking back) runs on the folder queue (`DownloadFolderStore.perform`), the
/// library's on its own queue: never blocking file I/O on Swift's cooperative pool.
final class DownloadPublisher: Sendable {
    private let publisher: FolderPublisher

    init(
        library: Library, store: DownloadFolderStore,
        folderChanged: @escaping @Sendable () async -> Void = {}
    ) {
        let destination = DownloadDestination()
        publisher = FolderPublisher(
            steps: FolderPublisher.Steps(
                target: { store.target },
                markUnavailable: { id in
                    DownloadFolderStore.log.error("download folder unreachable; downloads go to the app")
                    store.markUnavailable(id)
                    await folderChanged()
                },
                open: { try await DownloadFolderStore.perform { try store.open() } },
                libraryReads: { url in await library.folder(containing: url) != nil },
                reattach: { url in
                    do {
                        return try await library.reattachFolder(url) ? .reattached : .removed
                    } catch {
                        return .failed
                    }
                },
                folderRemoved: { id in
                    DownloadFolderStore.log.info("download folder removed from the library; downloads go to the app")
                    store.forget(id)
                    await folderChanged()
                },
                save: { staged, track, folder in
                    try await DownloadFolderStore.perform { try destination.save(staged, track: track, into: folder) }
                },
                admit: { url in try await library.admitFile(url) },
                inCatalog: { id in library.current.tracks[id] != nil },
                takeBack: { saved in _ = try? await DownloadFolderStore.perform { destination.takeBack(saved) } },
                importIntoApp: { staged in try await Self.importIntoApp(staged, library: library) },
                deleteStaged: { staged in try? FileManager.default.removeItem(at: staged) }))
    }

    /// Publishes `staged` (the validated download, `track`'s file), returning the row's note, or nil for "Done".
    func publish(_ staged: URL, track: RemoteTrack) async throws -> String? {
        try await publisher.publish(staged, track: track)
    }

    /// The import into the app's own library folder, as before download folders: the default, and the fallback. A
    /// refusal throws, so the job shows as failed instead of done, with its staged file kept.
    private static func importIntoApp(_ staged: URL, library: Library) async throws {
        let result = await library.importFiles([staged])
        if let rejection = result.rejected.first {
            throw PublishError(message: "\(rejection.fileName): \(rejection.message)")
        }
        if let error = result.error { throw PublishError(message: error) }
        guard !result.added.isEmpty || result.duplicates > 0 else {
            throw PublishError(message: "the library did not take the file")
        }
    }

    struct PublishError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
