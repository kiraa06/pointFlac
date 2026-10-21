import Synchronization
import os

/// pointFlac's audio signposts and log, for Instruments and the unified log. Never used on the render thread.
///
/// The render thread must not signpost or log: both can take locks and allocate. So "the first real frame" after a
/// play, resume or seek is observed from the decode thread, which compares `RenderSource.renderedFrames` with a mark
/// each time it polls (every 1–8 ms while it waits on the ring). An interval can therefore end up to about 8 ms after
/// the frame was rendered. That is good enough to check the 150 ms and 50 ms budgets on a device. RemoteIO's latency
/// timestamps, taken in the callback with a plain clock read, remain the precise figure for a single start.
///
/// Logging is for what changes rarely: plans, item failures, session events, player failures. Values that can name the
/// user's things (route names, which can be a device's name) are private.
enum Telemetry {
    static let subsystem = "io.github.kiraa06.pointflac"
    static let signposter = OSSignposter(subsystem: subsystem, category: "audio")
    static let logger = Logger(subsystem: subsystem, category: "audio")
}

/// A signpost interval from a request to the first real frame rendered after it: play → first frame, resume → first
/// frame, a restart after a route change → first frame, seek → first frame at the new position.
///
/// Begun by whoever makes the request; ended once, from the decode thread, by the pipeline that serves it. One that is
/// superseded or never gets a frame (the pipeline stopped first) ends as abandoned, so Instruments shows no interval
/// left open, and no abandoned one passes for a measurement.
final class FirstFrameInterval: Sendable {
    enum Kind: Sendable {
        case play
        case resume
        case restart
        case seek
    }

    enum Outcome: UInt8, Sendable {
        case rendered = 1
        case abandoned = 2
    }

    let kind: Kind
    private let state: OSSignpostIntervalState
    /// 0 while open, else an `Outcome`.
    private let ended = Atomic<UInt8>(0)

    init(_ kind: Kind) {
        self.kind = kind
        let signposter = Telemetry.signposter
        // Signpost names must be static strings, the same at the beginning and the end: hence the switches.
        state =
            switch kind {
            case .play: signposter.beginInterval("Play to first frame")
            case .resume: signposter.beginInterval("Resume to first frame")
            case .restart: signposter.beginInterval("Restart to first frame")
            case .seek: signposter.beginInterval("Seek to first frame")
            }
    }

    deinit {
        end(.abandoned)
    }

    /// How the interval ended; nil while it is open. For tests.
    var outcome: Outcome? {
        Outcome(rawValue: ended.load(ordering: .acquiring))
    }

    /// Ends the interval, the first time only; later calls do nothing.
    func end(_ outcome: Outcome) {
        guard ended.compareExchange(expected: 0, desired: outcome.rawValue, ordering: .acquiringAndReleasing).exchanged
        else { return }
        let signposter = Telemetry.signposter
        switch (kind, outcome) {
        case (.play, .rendered): signposter.endInterval("Play to first frame", state)
        case (.play, .abandoned): signposter.endInterval("Play to first frame", state, "abandoned")
        case (.resume, .rendered): signposter.endInterval("Resume to first frame", state)
        case (.resume, .abandoned): signposter.endInterval("Resume to first frame", state, "abandoned")
        case (.restart, .rendered): signposter.endInterval("Restart to first frame", state)
        case (.restart, .abandoned): signposter.endInterval("Restart to first frame", state, "abandoned")
        case (.seek, .rendered): signposter.endInterval("Seek to first frame", state)
        case (.seek, .abandoned): signposter.endInterval("Seek to first frame", state, "abandoned")
        }
    }
}
