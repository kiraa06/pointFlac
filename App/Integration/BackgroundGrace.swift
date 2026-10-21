import UIKit

/// Asks iOS for its short background grace period while downloads are running, so a quick switch to another app does
/// not cut every Soulseek connection. When the grace runs out iOS suspends the app (unless music is playing: the audio
/// background mode keeps the app, and its downloads, running) and the downloads resume when it comes back.
@MainActor
final class BackgroundGrace {
    private var task: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
