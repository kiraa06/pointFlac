import Foundation
import Observation
import PFAudio
import PFCore

/// Counts listens while the player plays (`ListenRule`), and tells `record` which track each one was.
///
/// It polls the player twice a second, but only while a track is playing or starting: it watches `Player.status` and
/// sleeps through pauses and idle, so a paused app wakes nothing. The rule needs polls no more than a second and a
/// half apart (`ListenRule.maxStep`); 0.5 s leaves room for a late one. Everything runs on the main actor, where the
/// player lives, and `record` is the only call that leaves it.
@MainActor
final class ListenTracker {
    private let player: Player
    private let record: @MainActor (String, Date) async -> Void
    private var session = ListenSession()
    private var polling: Task<Void, Never>?

    /// `record` is handed the library track's ID, and when it counted.
    init(player: Player, record: @escaping @MainActor (String, Date) async -> Void) {
        self.player = player
        self.record = record
    }

    /// Starts following the player. Call once.
    func start() { follow() }

    private var isActive: Bool { player.status == .playing || player.status == .preparing }

    /// Re-arms itself after every change of `Player.status`: polling runs while the player is active.
    private func follow() {
        let active = withObservationTracking {
            isActive
        } onChange: { [weak self] in
            // Called before the new value lands, so read it a turn later.
            Task { @MainActor [weak self] in self?.follow() }
        }
        if active, polling == nil {
            polling = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.poll()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        } else if !active {
            polling?.cancel()
            polling = nil
        }
    }

    private func poll() {
        let index = player.currentIndex
        let item = index.flatMap { player.queue.indices.contains($0) ? player.queue[$0] : nil }
        let sampleRate = item?.format.sampleRate ?? 0
        let duration = sampleRate > 0 ? Double(item?.totalFrames ?? 0) / Double(sampleRate) : 0
        guard
            let counted = session.observe(
                index: index, trackID: item?.id, durationSeconds: duration, positionSeconds: player.position.seconds,
                playing: player.status == .playing, scrubbing: player.isScrubbing)
        else { return }
        let now = Date()
        Task { @MainActor [record] in await record(counted, now) }
    }
}
