/// A transport command from outside the app: the lock screen, Control Center, headphone buttons, CarPlay.
public enum RemoteCommand: Sendable, Equatable {
    case play
    case pause
    case toggle
    case next
    case previous
    /// Jump to this time in the current track.
    case seek(Duration)
}

/// Where the player publishes what is playing, and where remote commands come from: `SystemNowPlaying` on iOS, a fake
/// in tests.
///
/// Main-actor bound. The player publishes from the main actor, and MediaPlayer delivers remote commands on the main
/// thread, so a conformer calls `onCommand` there and the player handles the command synchronously, in order with
/// everything else it does.
@MainActor
public protocol NowPlayingPublishing: AnyObject {
    /// Publishes `item`, `elapsed` into it, as playing or paused. The system extrapolates the elapsed time from the
    /// playback rate, so the player publishes on changes only (track start, pause, resume, seek, end), never on a timer.
    func show(_ item: QueueItem, elapsed: Duration, playing: Bool)
    /// Removes the Now Playing entry.
    func clear()
    /// Set by the player. Called on the main actor for each remote command.
    var onCommand: ((RemoteCommand) -> Void)? { get set }
}
