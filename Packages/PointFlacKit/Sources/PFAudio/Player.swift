import Foundation
import Observation
import PFCore

/// The object the UI binds to. It plays a queue through a `PlaybackPipeline`, follows the audio session (routes,
/// interruptions, volume, media-server resets), keeps an honest `SignalState`, and publishes Now Playing.
///
/// ## Pause and resume (ruling R15)
/// The pipeline has no pause, and its output must never be stopped behind its back: its seek acknowledgement and its
/// drain both wait on render callbacks. So `pause()` remembers where playback was, `(index, frame)` from the
/// pipeline's rendered position, and stops the pipeline. `resume()` starts a new one there. That re-opens the file and
/// re-negotiates the rate, ~20–100 ms, and so also keeps the client rate equal to the hardware rate after a route
/// change made while paused. A seek while paused only moves the remembered frame.
///
/// ## One pipeline per start, and stale events
/// Every start builds a fresh pipeline: play, resume, a track change, a restart after a route change, a restart after
/// the queue ended. Each pipeline lives in a `PlayerEngine` with its own output lease, its own event stream and the
/// task that reads it. Stopping one retires its engine: the pipeline stops, its lease is revoked and its event task is
/// cancelled. Events it emitted before stopping can still be waiting, unread, in its stream (a `queueEnded` while the
/// user picks a new album, say). So the event task drops any event whose engine is no longer the current one. A stale
/// event can never touch the new queue, and the revoked lease keeps the stopped pipeline off the output and the
/// session.
///
/// ## Reentrancy
/// State changes happen synchronously on the main actor. The awaits are the pipeline's `start` and `seek` and the
/// session activation before a start, and they run in order per engine (`PlayerEngine.enqueue`). Anything that
/// interleaves while one is in flight either queues behind it on the same engine, or retires that engine. A late call
/// into a retired engine is harmless: its pipeline cannot reach the output or the session any more.
///
/// ## Rate negotiation (ruling 6)
/// Every pipeline negotiates through one `SessionGate`, so `requestSampleRate` calls run one at a time, in order,
/// including a stopped pipeline's late one. The player itself never asks for a rate. Each pipeline stops its output
/// before negotiating, and a retired pipeline's request is refused at its turn.
@MainActor
@Observable
public final class Player {
    public enum Status: Equatable, Sendable {
        case idle
        /// A pipeline is starting: opening the file, negotiating the rate, filling the ring.
        case preparing
        case playing
        case paused
        /// The queue played out. The last track stays cued at its start, as Music leaves it, so play replays it.
        case ended
        /// Nothing in the queue could be played.
        case failed(String)
    }

    /// Runout's `RESTART_WINDOW_MS`: past this point in a track, previous restarts it rather than going back.
    static let restartWindow: Duration = .milliseconds(3000)

    public private(set) var status: Status = .idle
    public private(set) var queue: [QueueItem] = []
    public private(set) var currentIndex: Int?
    /// Time into the current track. Updated at 10 Hz while playing, and at once on start, pause, seek and track change.
    public private(set) var position: Duration = .zero
    /// The signal path, for the strip. The plan and source come from the pipeline as it configures and starts tracks,
    /// and the port and volume from the session. While paused on another track, it still shows the last one played.
    public private(set) var signal: SignalState

    private let session: AudioSessionControlling
    private let gate: SessionGate
    private let arbiter: OutputArbiter
    private let capabilities: OutputCapabilities
    private let nowPlaying: NowPlayingPublishing
    private let makeDecoder: @Sendable (PlaybackItem) throws -> PCMDecoding

    /// The pipeline playing now. Nil whenever nothing plays: idle, paused, ended or failed.
    @ObservationIgnored private var engine: PlayerEngine?
    /// Engines created so far; each takes the next number as its generation.
    @ObservationIgnored private var generations: UInt64 = 0
    /// Where the current engine started, or where playback will resume when paused or ended.
    @ObservationIgnored private var cue = Cue(index: 0, frame: 0)
    /// Whether the session has been activated since launch or since it was last lost (interruption, media reset).
    @ObservationIgnored private var sessionActive = false
    /// Times the session was lost. An activation that was in flight across a loss does not mark the session active.
    @ObservationIgnored private var sessionLosses = 0
    /// An interruption paused a playing track (ruling 4). Cleared by any user transport command.
    @ObservationIgnored private var resumeAfterInterruption = false
    /// Some item of the current queue has started; until one does, the queue ending means it failed.
    @ObservationIgnored private var anyItemStarted = false
    @ObservationIgnored private var lastFailure: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sessionEvents: Task<Void, Never>?

    /// - Parameters:
    ///   - output: shared by every pipeline the player starts, one at a time.
    ///   - makeDecoder: opens an item. Called on a pipeline's decode thread.
    public init(
        session: AudioSessionControlling, output: AudioOutput, capabilities: OutputCapabilities,
        nowPlaying: NowPlayingPublishing, makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding
    ) {
        self.session = session
        gate = SessionGate(session: session)
        arbiter = OutputArbiter(output: output)
        self.capabilities = capabilities
        self.nowPlaying = nowPlaying
        self.makeDecoder = makeDecoder
        // The volume KVO has no initial value, so read the volume now; `.volumeChanged` keeps it current.
        signal = SignalState(port: session.currentPort, systemVolume: session.outputVolume)
        nowPlaying.onCommand = { [weak self] command in self?.perform(command) }
        // Started once: the session's stream is single-consumer.
        let events = session.events
        sessionEvents = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    deinit {
        sessionEvents?.cancel()
        ticker?.cancel()
        // The engine goes with the player. Its pipeline's deinit stops playback and finishes the pipeline's event
        // stream, which ends the engine's event task.
    }

    // MARK: Transport

    /// Replaces the queue and plays `items` from `index` (clamped to the queue). Returns once the pipeline has the
    /// queue; `status` is `.playing` once the first track starts rendering.
    public func play(_ items: [QueueItem], startingAt index: Int) async {
        resumeAfterInterruption = false
        retireEngine()
        queue = items
        anyItemStarted = false
        lastFailure = nil
        guard !items.isEmpty else {
            status = .idle
            currentIndex = nil
            position = .zero
            nowPlaying.clear()
            return
        }
        await launch(at: min(max(index, 0), items.count - 1), frame: 0).value
    }

    /// Stops playback where it is (ruling R15). No effect unless playing or preparing.
    public func pause() {
        resumeAfterInterruption = false
        pauseNow()
    }

    /// Restarts playback where it was paused, or replays the cued last track after the queue ended.
    public func resume() {
        resumeAfterInterruption = false
        resumeNow()
    }

    public func togglePlayPause() {
        switch status {
        case .playing, .preparing: pause()
        case .paused, .ended: resume()
        case .idle, .failed: break
        }
    }

    /// Moves to `time` in the current track. While paused it only moves the remembered position. After the queue ended
    /// it plays from there, on a fresh pipeline (a pipeline seek after `queueEnded` would replay without a fresh
    /// `trackStarted`).
    public func seek(to time: Duration) async {
        guard let index = currentIndex, queue.indices.contains(index) else { return }
        let item = queue[index]
        let frame = item.frame(at: time)
        switch status {
        case .playing, .preparing:
            guard let engine else { return }
            cue = Cue(index: index, frame: frame)
            position = item.duration(ofFrames: frame)
            nowPlaying.show(item, elapsed: position, playing: true)
            engine.seeksInFlight += 1
            await engine.enqueue { pipeline in await pipeline.seek(toFrame: frame) }.value
            engine.seeksInFlight -= 1
        case .paused:
            cue = Cue(index: index, frame: frame)
            showCue(playing: false)
        case .ended:
            await launch(at: index, frame: frame).value
        case .idle, .failed:
            break
        }
    }

    /// The next track. Past the last one the queue ends.
    public func next() async {
        guard let index = currentIndex, status != .idle else { return }
        guard index + 1 < queue.count else {
            if status != .ended { endQueue() }
            return
        }
        await go(to: index + 1)
    }

    /// Restarts the current track when more than `restartWindow` into it, or when it is the first; otherwise goes back
    /// a track.
    public func previous() async {
        guard let index = currentIndex else { return }
        if position > Self.restartWindow || index == 0 {
            await seek(to: .zero)
        } else {
            await go(to: index - 1)
        }
    }

    /// The pipeline playing now, if any. For tests.
    var pipeline: PlaybackPipeline? {
        engine?.pipeline
    }

    /// The engine playing now, if any. For tests, which queue calls on it to hold later calls back.
    var currentEngine: PlayerEngine? {
        engine
    }

    // MARK: Starting and stopping engines

    /// Moves to the start of `queue[index]`: plays it if playing (or ended), cues it if paused.
    private func go(to index: Int) async {
        switch status {
        case .playing, .preparing, .ended:
            await launch(at: index, frame: 0).value
        case .paused:
            cue = Cue(index: index, frame: 0)
            showCue(playing: false)
        case .idle, .failed:
            break
        }
    }

    /// Retires whatever plays and starts a new engine at `frame` of `queue[index]`. The state changes happen now; the
    /// returned task finishes once the pipeline has the queue, or the start was abandoned.
    @discardableResult
    private func launch(at index: Int, frame: Int64) -> Task<Void, Never> {
        retireEngine()
        cue = Cue(index: index, frame: frame)
        currentIndex = index
        position = queue[index].duration(ofFrames: frame)
        status = .preparing
        let engine = makeEngine()
        self.engine = engine
        let items = queue.map(\.playbackItem)
        let needsActivation = !sessionActive
        return engine.enqueue { [weak self] pipeline in
            if needsActivation {
                guard let self else { return }
                do {
                    try await activateSession()
                } catch {
                    if self.engine === engine { fail("Audio session unavailable: \(error)") }
                    return
                }
            }
            guard !engine.isRetired else { return }
            await pipeline.start(items, at: index, fromFrame: frame)
            engine.hasStarted = true
        }
    }

    private func makeEngine() -> PlayerEngine {
        generations += 1
        let generation = generations
        let lease = arbiter.lease()
        let gate = self.gate
        let pipeline = PlaybackPipeline(
            output: lease, capabilities: capabilities,
            negotiateRate: { rate in await gate.requestSampleRate(rate, for: lease) }, makeDecoder: makeDecoder)
        let engine = PlayerEngine(pipeline: pipeline, lease: lease, generation: generation)
        // Captures the generation, not the engine, so the task never keeps a pipeline alive.
        let events = pipeline.events
        engine.events = Task { [weak self] in
            for await event in events {
                // The stale-event guard. Cancelling a retired engine's task is not enough: AsyncStream still hands
                // out what was buffered before the cancel, and an event already handed to this task resumes it.
                guard let self, self.engine?.generation == generation else { return }
                self.handle(event)
            }
        }
        return engine
    }

    /// Stops the current engine's pipeline and makes sure nothing it emitted from now on is handled.
    private func retireEngine() {
        stopTicker()
        guard let engine else { return }
        self.engine = nil
        engine.retire()
    }

    /// Configures and activates the session, in turn with the negotiations, then reads the route again: the port and
    /// volume read before activation may be stale.
    private func activateSession() async throws {
        let losses = sessionLosses
        try await gate.activate()
        // If the session was lost again meanwhile (an interruption), the next start activates it again.
        if sessionLosses == losses { sessionActive = true }
        signal.port = session.currentPort
        signal.systemVolume = session.outputVolume
    }

    /// The system deactivated the session, or the media server took it down.
    private func loseSession() {
        sessionActive = false
        sessionLosses += 1
    }

    /// Where playback is now: the pipeline's rendered position once it has the queue, the cue before that. While a seek
    /// is on its way to the pipeline, the pipeline still reports the old point and the cue already holds the target,
    /// so a pause, restart or interruption then keeps the seek.
    private func currentPoint() -> Cue {
        guard let engine, engine.hasStarted, engine.seeksInFlight == 0 else { return cue }
        let reported = engine.pipeline.position
        return queue.indices.contains(reported.index) ? Cue(index: reported.index, frame: reported.frame) : cue
    }

    private func pauseNow() {
        guard status == .playing || status == .preparing else { return }
        cue = currentPoint()
        retireEngine()
        status = .paused
        showCue(playing: false)
    }

    private func resumeNow() {
        guard status == .paused || status == .ended, queue.indices.contains(cue.index) else { return }
        // Now Playing switches to playing once the new pipeline's `trackStarted` arrives.
        launch(at: cue.index, frame: cue.frame)
    }

    /// Ends the queue: the last track cued at its start. Now Playing keeps showing it, paused at 0, so the lock screen
    /// can replay it (rather than `clear()`, which would drop the controls with it).
    private func endQueue() {
        retireEngine()
        guard let last = currentIndex ?? queue.indices.last else { return }
        cue = Cue(index: last, frame: 0)
        status = .ended
        showCue(playing: false)
    }

    private func fail(_ message: String) {
        retireEngine()
        status = .failed(message)
        currentIndex = nil
        position = .zero
        nowPlaying.clear()
    }

    /// Points the current index and position at the cue, and publishes it.
    private func showCue(playing: Bool) {
        let item = queue[cue.index]
        currentIndex = cue.index
        position = item.duration(ofFrames: cue.frame)
        nowPlaying.show(item, elapsed: position, playing: playing)
    }

    // MARK: Events

    /// An event from the current engine's pipeline.
    private func handle(_ event: PipelineEvent) {
        // An event proves the pipeline has the queue, even if `start` has not been seen to return yet.
        engine?.hasStarted = true
        switch event {
        case .planChanged(let plan):
            // Together, from the same negotiation (T7). The hardware side, when the output can see it, is the honest
            // rate: on the simulator it can stay at 48 kHz under a 44.1 kHz client (ruling R17).
            signal.plan = plan
            signal.hardwareRate = arbiter.hardwareSideSampleRate ?? plan.clientSampleRate
        case .trackStarted(let index):
            guard queue.indices.contains(index) else { return }
            anyItemStarted = true
            signal.source = queue[index].format
            status = .playing
            // A resumed track starts mid-way: the pipeline reports the frame it started from.
            let reported = engine?.pipeline.position
            cue = Cue(index: index, frame: reported?.index == index ? reported?.frame ?? 0 : 0)
            showCue(playing: true)
            startTicker()
        case .trackEnded:
            // The next `trackStarted` or `queueEnded` follows.
            break
        case .itemFailed(_, let message):
            // The pipeline moves on to the next item by itself.
            lastFailure = message
        case .queueEnded:
            if anyItemStarted {
                endQueue()
            } else {
                fail(lastFailure ?? "Nothing in the queue could be played")
            }
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .routeChanged(let reason, let port):
            let previous = signal.port
            signal.port = port
            if reason == .oldDeviceUnavailable {
                // Headphones or DAC pulled: never carry on through the speaker, including when an interruption that
                // paused playback ends with "should resume".
                resumeAfterInterruption = false
            }
            switch status {
            case .playing, .preparing:
                if reason == .oldDeviceUnavailable {
                    pauseNow()
                } else if reason == .newDeviceAvailable || port != previous || hardwareRateMoved {
                    // The hardware may run at another rate now. Restart at the same point, so the client rate matches
                    // it again, rather than let iOS resample silently.
                    let point = currentPoint()
                    launch(at: point.index, frame: point.frame)
                }
            case .paused:
                // Resume re-negotiates. Until then the strip shows the rate the hardware runs at now.
                let rate = session.sampleRate
                if rate > 0 { signal.hardwareRate = rate }
            case .idle, .ended, .failed:
                break
            }
        case .interruptionBegan:
            // The system has deactivated the session; the next start re-activates it.
            loseSession()
            guard status == .playing || status == .preparing else { return }
            pauseNow()
            resumeAfterInterruption = true
        case .interruptionEnded(let shouldResume):
            let resume = shouldResume && resumeAfterInterruption
            resumeAfterInterruption = false
            if resume { resumeNow() }
        case .volumeChanged(let volume):
            signal.systemVolume = volume
        case .mediaServicesReset:
            resetMediaServices()
        }
    }

    /// Whether the hardware has moved off the rate the last negotiation read back, with nothing negotiating now.
    ///
    /// A same-port route change (a category or configuration change) can move the hardware rate mid-track. It is also
    /// what the session's own activation and negotiation post, so the comparison must not set off a restart loop. It
    /// cannot: a notification a negotiation causes arrives while that negotiation holds the session's turn (no settled
    /// rate, ignored) or after it, when the read-back equals the live rate. `signal.plan` would not do here, because
    /// the new plan's `.planChanged` can arrive after the notification its own negotiation caused.
    private var hardwareRateMoved: Bool {
        guard let settled = gate.settledRate else { return false }
        let live = session.sampleRate
        return live > 0 && live != settled
    }

    /// The media server died, and the session's configuration with it (ruling 5). Stops the pipeline, pauses at the
    /// current position and re-activates the session; the user resumes.
    ///
    /// Out of scope: an output whose underlying unit died with the server (a stale RemoteIO instance) is not rebuilt.
    /// The player does not construct its output; the app model that does (Task 14) has to replace it.
    private func resetMediaServices() {
        resumeAfterInterruption = false
        loseSession()
        pauseNow()
        retireEngine()
        // If this fails, the next start tries again.
        Task { [weak self] in try? await self?.activateSession() }
    }

    /// A remote command, on the main actor.
    private func perform(_ command: RemoteCommand) {
        switch command {
        case .play: resume()
        case .pause: pause()
        case .toggle: togglePlayPause()
        case .next: Task { await next() }
        case .previous: Task { await previous() }
        case .seek(let time): Task { await seek(to: time) }
        }
    }

    // MARK: Position

    /// 10 Hz while playing. Cancelled whenever the engine is retired, and on failure.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self else { return }
                updatePosition()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// Maps the pipeline's position (source frames, derived from rendered audio) to time in the current track.
    private func updatePosition() {
        guard status == .playing, let engine, engine.seeksInFlight == 0, let index = currentIndex else { return }
        let reported = engine.pipeline.position
        // Across a gapless join the pipeline renders the next track a moment before its `trackStarted` is handled.
        guard reported.index == index else { return }
        let elapsed = queue[index].duration(ofFrames: reported.frame)
        if elapsed != position { position = elapsed }
    }
}

/// A point in the queue: an item and a source frame in it.
private struct Cue {
    var index: Int
    var frame: Int64
}
