#if os(iOS)
    import Foundation
    import MediaPlayer
    import UIKit

    /// Now Playing on iOS. The lock screen, Control Center and the Dynamic Island show what `show` publishes. Their
    /// controls, headphone buttons and CarPlay come back through `onCommand`.
    ///
    /// ## Swift 6 isolation
    /// The class is main-actor bound, like the player. MediaPlayer calls the command handlers on the main thread, but
    /// it is Objective-C and promises nothing to the compiler. A handler formed in main-actor code would be inferred
    /// main-actor isolated, and Swift 6 traps if such a closure is ever entered off the main actor. So each handler is
    /// built in a nonisolated static function, as a `@Sendable` closure, and hops to the main actor itself:
    /// `MainActor.assumeIsolated` when already on the main thread (the documented case, handled synchronously), a task
    /// otherwise. The artwork provider is built the same way. MediaPlayer asks it for images off the main thread, where
    /// a main-actor closure would trap.
    @MainActor
    public final class SystemNowPlaying: NowPlayingPublishing {
        public var onCommand: ((RemoteCommand) -> Void)?
        /// Every handler added to `MPRemoteCommandCenter`, removed again in `deinit`.
        private var targets: [(command: MPRemoteCommand, token: Any)] = []

        public init() {
            let center = MPRemoteCommandCenter.shared()
            let deliver: @Sendable @MainActor (RemoteCommand) -> Void = { [weak self] command in
                self?.onCommand?(command)
            }
            register(center.playCommand, Self.handler(deliver) { _ in .play })
            register(center.pauseCommand, Self.handler(deliver) { _ in .pause })
            register(center.togglePlayPauseCommand, Self.handler(deliver) { _ in .toggle })
            register(center.nextTrackCommand, Self.handler(deliver) { _ in .next })
            register(center.previousTrackCommand, Self.handler(deliver) { _ in .previous })
            register(
                center.changePlaybackPositionCommand,
                Self.handler(deliver) { event in
                    (event as? MPChangePlaybackPositionCommandEvent).map { .seek(.seconds($0.positionTime)) }
                })
        }

        isolated deinit {
            for target in targets {
                target.command.removeTarget(target.token)
            }
        }

        public func show(_ item: QueueItem, elapsed: Duration, playing: Bool) {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: item.title,
                MPMediaItemPropertyArtist: item.artist,
                MPMediaItemPropertyAlbumTitle: item.album,
                MPMediaItemPropertyPlaybackDuration: Self.seconds(item.duration),
                MPNowPlayingInfoPropertyElapsedPlaybackTime: Self.seconds(elapsed),
                // The system extrapolates the elapsed time at this rate until the next `show`.
                MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            ]
            if let data = item.artwork, let image = UIImage(data: data) {
                info[MPMediaItemPropertyArtwork] = Self.artwork(image)
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        public func clear() {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }

        private func register(
            _ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
        ) {
            command.isEnabled = true
            targets.append((command, command.addTarget(handler: handler)))
        }

        /// A command handler that maps the event with `command` and hands the result to `deliver` on the main actor.
        nonisolated private static func handler(
            _ deliver: @escaping @Sendable @MainActor (RemoteCommand) -> Void,
            _ command: @escaping @Sendable (MPRemoteCommandEvent) -> RemoteCommand?
        ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { event in
                guard let remote = command(event) else { return .commandFailed }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { deliver(remote) }
                } else {
                    Task { @MainActor in deliver(remote) }
                }
                return .success
            }
        }

        nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
            MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
        }

        private static func seconds(_ duration: Duration) -> Double {
            let (seconds, attoseconds) = duration.components
            return Double(seconds) + Double(attoseconds) / 1e18
        }
    }
#endif
