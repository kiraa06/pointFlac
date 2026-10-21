import Foundation
import Observation

/// A main-actor mirror of the download queue that SwiftUI can observe directly.
///
/// The manager is an actor so its work never touches the main actor; this class only copies its snapshots across,
/// which keeps view updates cheap and the UI free of `await`.
@MainActor
@Observable
public final class DownloadsObserver {
    public private(set) var items: [DownloadItem] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    public init(manager: DownloadManager) {
        task = Task { [weak self] in
            for await snapshot in await manager.updates() {
                guard let self else { return }
                self.items = snapshot
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }
}
