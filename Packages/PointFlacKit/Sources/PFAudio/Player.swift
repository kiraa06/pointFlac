import Foundation
import Observation
import PFCore
import PFDSP

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
///
/// ## ReplayGain (Plan 4 Task 12)
/// Each queue item's gain is worked out from its `loudness` and `sound.replayGain` (`replayGainDb(for:sound:)`, 0 in
/// Pure) and handed to the pipeline with the item, which applies it on the decode thread. A settings change
/// recomputes the queue's gains (`PlaybackPipeline.setGains`); they apply from the next item the pipeline enters,
/// and on any seek, never to the item playing mid-stream. The exception (ruling R4-T12a): switching Pure on or off,
/// or ReplayGain on or off, is heard at once, through a re-cue of the item playing at where it is, whenever that
/// changes its gain. The strip lists ReplayGain exactly while a non-zero gain applies to the item playing.
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
    /// and the port and volume from the session.
    ///
    /// "Pure" has to be earned by each start (final review I3). Every start shows its track as pending (no plan) until
    /// the new pipeline's plan arrives with that track. A paused track change shows the cued track as pending too.
    /// A failure, or `play([])`, clears the path altogether. Pause and the end of the queue keep the last track's path
    /// on show, refreshed only when the hardware really moves (`refreshIdleHardwareRate`).
    public private(set) var signal: SignalState
    /// The Sound settings every pipeline plays with, clamped. Pure (the default) is bit-exact.
    public private(set) var sound = SoundSettings()

    private let session: AudioSessionControlling
    private let gate: SessionGate
    private let arbiter: OutputArbiter
    private let capabilities: OutputCapabilities
    private let nowPlaying: NowPlayingPublishing
    private let makeDecoder: @Sendable (PlaybackItem) throws -> PCMDecoding
    /// Builds the output, under the arbiter, when a start finds none.
    @ObservationIgnored private let makeOutput: () throws -> AudioOutput

    /// The pipeline playing now. Nil whenever nothing plays: idle, paused, ended or failed.
    @ObservationIgnored private var engine: PlayerEngine?
    /// The negotiated path `signal` shows; nil whenever `signal.plan` is. Kept so the idle refresh can return to the
    /// negotiated hardware-side rate once the hardware comes back to the negotiated rate.
    @ObservationIgnored private var shownPath: SignalPath?
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
    /// The finger on the record, from `beginScrub()` until its let-go has settled.
    @ObservationIgnored private var scrubRun: ScrubRun?
    @ObservationIgnored private var sessionEvents: Task<Void, Never>?
    /// Clips counted by the pipelines retired so far, so `soundMeters.clipCount` runs on across them.
    @ObservationIgnored private var retiredClips = 0

    /// - Parameters:
    ///   - makeOutput: builds the output every pipeline the player starts renders through, one at a time. Called on
    ///     the main actor by the first start, and again by the first start after a media-services reset, which takes
    ///     the old output's audio unit down with the server. It is the only source of outputs: the player never keeps
    ///     one it did not get from here. If it throws, that start fails with "Audio output unavailable: …".
    ///   - makeDecoder: opens an item. Called on a pipeline's decode thread.
    public init(
        session: AudioSessionControlling, makeOutput: @escaping () throws -> AudioOutput,
        capabilities: OutputCapabilities, nowPlaying: NowPlayingPublishing,
        makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding
    ) {
        self.session = session
        gate = SessionGate(session: session)
        arbiter = OutputArbiter()
        self.makeOutput = makeOutput
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
        scrubRun?.filler.stop()
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
            clearSignal()
            nowPlaying.clear()
            return
        }
        await launch(at: min(max(index, 0), items.count - 1), frame: 0, for: .play).value
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
            // From the request, through the main actor's queue on the engine, to the first frame at the target.
            let interval = FirstFrameInterval(.seek)
            cue = Cue(index: index, frame: frame)
            position = item.duration(ofFrames: frame)
            nowPlaying.show(item, elapsed: position, playing: true)
            engine.seeksInFlight += 1
            await engine.enqueue { pipeline in await pipeline.seek(toFrame: frame, firstFrame: interval) }.value
            engine.seeksInFlight -= 1
            // The new gain shows once the decode thread has taken the seek (the position updates catch it).
            refreshProcessing()
        case .paused:
            endPausedScrub()
            cue = Cue(index: index, frame: frame)
            showCue(playing: false)
        case .ended:
            await launch(at: index, frame: frame, for: .play).value
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

    // MARK: Sound

    /// Plays `settings`, clamped, from the next render call (cross-faded in over 10 ms, after the chain's few
    /// milliseconds of look-ahead; a change made while the last one is still fading waits for it), and shows the
    /// blocks at work on the strip (`signal.activeProcessing`). Compiled here, on the main actor, for the playing plan.
    /// While nothing plays it is only kept, and the next start compiles it for its plan.
    ///
    /// A ReplayGain change, or a switch to or from Pure, recomputes every queue item's gain.
    /// - Switching Pure on or off, or ReplayGain on or off (`.off` to a mode or back), is heard at once (ruling
    ///   R4-T12a): when it changes the gain of the item playing, that item is re-cued where it is
    ///   (`recueForNewGain`), a short gap with a fade-in. When it does not (Pure toggled with ReplayGain off, or an item
    ///   that gets 0 dB either way), nothing is re-cued.
    /// - Any other ReplayGain change (mode, preamp, clipping prevention, reference) applies from the next item the
    ///   pipeline enters, and on any seek: the item playing keeps its level, and the strip keeps listing ReplayGain
    ///   while its gain is still on.
    public func setSound(_ settings: SoundSettings) {
        let settings = settings.clamped()
        let gainsChanged = settings.pure != sound.pure || settings.replayGain != sound.replayGain
        let switched =
            settings.pure != sound.pure || (settings.replayGain.mode == .off) != (sound.replayGain.mode == .off)
        sound = settings
        if let engine {
            engine.pipeline.setSound(settings)
            if gainsChanged { engine.pipeline.setGains(queueGains) }
            if switched { recueForNewGain(engine) }
        }
        refreshProcessing()
    }

    /// Re-cues the item rendering where it is, through the pipeline's seek path (`PlaybackPipeline.recue`), when its
    /// gain under the current settings differs from the gain it is playing at, so the new gain is heard at once.
    ///
    /// Nothing to do, and so no gap, when the gains agree; while a seek is still on its way (it is entered at the new
    /// gains anyway); before the pipeline has entered an item (it enters it at the new gains); and while a finger is on
    /// the record, whose let-go seeks the pipeline, at the new gains, itself.
    private func recueForNewGain(_ engine: PlayerEngine) {
        guard status == .playing || status == .preparing, scrubRun == nil, engine.seeksInFlight == 0,
            let rendering = engine.pipeline.renderingGain, queue.indices.contains(rendering.index),
            Self.replayGainDb(for: queue[rendering.index], sound: sound) != rendering.gainDb
        else { return }
        let point = currentPoint()
        cue = point
        let frame = point.frame
        engine.seeksInFlight += 1
        let interval = FirstFrameInterval(.seek)
        _ = engine.enqueue { [weak engine] pipeline in
            await pipeline.recue(toFrame: frame, firstFrame: interval)
            engine?.seeksInFlight -= 1
        }
    }

    // MARK: ReplayGain

    /// The ReplayGain, in dB, for `item` under `settings`, worked out from what the library knows of its loudness
    /// (`QueueItem.loudness`). Pure is not part of `settings`: `replayGainDb(for:sound:)` is this, and 0 in Pure.
    ///
    /// 1. `.off`: 0, and nothing below applies.
    /// 2. The gain, in order of preference:
    ///    - the tag gain for the mode (`REPLAYGAIN_TRACK_GAIN`, or `REPLAYGAIN_ALBUM_GAIN` in album mode), used as it
    ///      is: tags are RG 2.0 values, never re-referenced to `referenceLufs`;
    ///    - else the measured value, `referenceLufs − LUFS` (RG 2.0's −18 by default, ruling R4-7): the track's R128
    ///      loudness, or the album's, measured as a whole, in album mode. A measurement with no usable loudness
    ///      (silent, or under one 400 ms gating block: `measuredLufs` nil, `measuredPeak` set) gives none;
    ///    - else 0.
    ///
    ///    Album mode with no album value at all (no album tag, and no album measurement, which the library only keeps
    ///    while the album's tracks are those it was measured over) falls back to the track's tag, then its
    ///    measurement.
    /// 3. `preampDb` is added, to whichever gain was found, 0 included.
    /// 4. With `preventClipping`, the result is capped at `−20·log10(peak)`, so the peak lands at full scale at most:
    ///    the tag peak, else the measured true peak (both linear); in album mode the album's, falling back to the
    ///    track's when the album has none. A cap only ever lowers a gain. With no peak known there is no cap (the
    ///    limiter, in the chain whenever ReplayGain is on, still catches an over), nor with a peak of 0 (silence).
    ///
    /// A value that is not finite (a NaN setting) counts as absent; the result is always finite.
    public nonisolated static func replayGainDb(for item: QueueItem, settings: ReplayGainSettings) -> Double {
        guard settings.mode != .off else { return 0 }
        let loudness = item.loudness ?? TrackLoudness()
        let reference = settings.referenceLufs.isFinite ? settings.referenceLufs : ReplayGainSettings().referenceLufs
        /// `reference − lufs` for a usable measurement. Integrated loudness is gated at −70 LUFS, so a real one is
        /// above it.
        func measured(_ lufs: Double?) -> Double? {
            guard let lufs, lufs.isFinite, lufs > -70 else { return nil }
            return reference - lufs
        }
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let trackGain = finite(loudness.trackGainDb) ?? measured(loudness.measuredLufs)
        let trackPeak = finite(loudness.trackPeak) ?? finite(loudness.measuredPeak)
        var gain: Double
        var peak: Double?
        if settings.mode == .album,
            let albumGain = finite(loudness.albumGainDb) ?? measured(loudness.albumMeasuredLufs)
        {
            gain = albumGain
            peak = finite(loudness.albumPeak) ?? finite(loudness.albumMeasuredPeak) ?? trackPeak
        } else {
            gain = trackGain ?? 0
            peak = trackPeak
        }
        if settings.preampDb.isFinite { gain += settings.preampDb }
        if settings.preventClipping, let peak, peak > 0 {
            gain = min(gain, -20 * log10(peak))
        }
        return gain.isFinite ? gain : 0
    }

    /// `replayGainDb(for:settings:)` under the whole of `sound`: 0 in Pure, which ignores ReplayGain.
    public nonisolated static func replayGainDb(for item: QueueItem, sound: SoundSettings) -> Double {
        sound.pure ? 0 : replayGainDb(for: item, settings: sound.replayGain)
    }

    /// The gain of every queue item under the current settings, by ID, for `PlaybackPipeline.setGains`. Items with
    /// the same ID are the same track, with the same loudness.
    private var queueGains: [String: Double] {
        var gains: [String: Double] = [:]
        for item in queue { gains[item.id] = Self.replayGainDb(for: item, sound: sound) }
        return gains
    }

    /// The queue as a pipeline starts it: each item with its gain under the current settings.
    private var playbackItems: [PlaybackItem] {
        queue.map { item in
            var playback = item.playbackItem
            playback.gainDb = Self.replayGainDb(for: item, sound: sound)
            return playback
        }
    }

    /// The gain `queue[index]` plays at now: what the pipeline applied to it while it renders, else what it gets
    /// under the current settings, which is what the next start gives it.
    private func gainDb(at index: Int) -> Double {
        if let engine, engine.hasStarted, let rendering = engine.pipeline.renderingGain, rendering.index == index {
            return rendering.gainDb
        }
        return Self.replayGainDb(for: queue[index], sound: sound)
    }

    /// Shows the blocks at work on what plays now (`signal.activeProcessing`): the Sound settings' blocks, with
    /// ReplayGain listed exactly while a non-zero gain applies to the current item. An item that gets 0 dB is not
    /// processed by it, though the limiter ReplayGain brings into the chain still runs; an item still playing at the
    /// gain it started with, after a switch to Pure or to off, still is, and the strip says Processing until it ends
    /// or a seek takes the new settings. Called whenever the settings, the item or the engine change, and with each
    /// position update, which catches a seek or a gapless join taking effect.
    private func refreshProcessing() {
        var names = sound.activeBlockNames.filter { $0 != "ReplayGain" }
        if let index = currentIndex, queue.indices.contains(index), gainDb(at: index) != 0 {
            names.insert("ReplayGain", at: 0)
        }
        if signal.activeProcessing != names { signal.activeProcessing = names }
    }

    /// The Sound chain's meters: the peak since the last read, the clips since the player was made, and the latest
    /// gain reduction. Reading starts a new peak interval, so keep to one reader. The floor, with nothing playing.
    public var soundMeters: SoundMeters {
        guard let engine else { return SoundMeters(peakDbFS: -120, clipCount: retiredClips, gainReductionDb: 0) }
        var meters = engine.pipeline.soundMeters
        meters.clipCount += retiredClips
        return meters
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
            await launch(at: index, frame: 0, for: .play).value
        case .paused:
            endPausedScrub()
            cue = Cue(index: index, frame: 0)
            showPending(for: index)
            showCue(playing: false)
        case .idle, .failed:
            break
        }
    }

    /// Retires whatever plays and starts a new engine at `frame` of `queue[index]`. The state changes happen now; the
    /// returned task finishes once the pipeline has the queue, or the start was abandoned.
    ///
    /// `kind` names the signpost interval that runs from here, before the session activation, to the first real
    /// frame; an abandoned start ends it as abandoned.
    @discardableResult
    private func launch(at index: Int, frame: Int64, for kind: FirstFrameInterval.Kind) -> Task<Void, Never> {
        let interval = FirstFrameInterval(kind)
        retireEngine()
        cue = Cue(index: index, frame: frame)
        currentIndex = index
        position = queue[index].duration(ofFrames: frame)
        status = .preparing
        // The new pipeline negotiates afresh, so nothing the last one established holds any more.
        showPending(for: index)
        let engine: PlayerEngine
        do {
            engine = try makeEngine()
        } catch {
            fail("Audio output unavailable: \(error)")
            return Task {}
        }
        self.engine = engine
        let items = playbackItems
        let needsActivation = !sessionActive
        // The item's rate as imported: the negotiation that follows asks for the decoder's, normally the same.
        let preferredRate = queue[index].format.sampleRate
        return engine.enqueue { [weak self] pipeline in
            if needsActivation {
                guard let self else { return }
                do {
                    try await activateSession(preferredRate: preferredRate)
                } catch {
                    if self.engine === engine { fail("Audio session unavailable: \(error)") }
                    return
                }
            }
            guard !engine.isRetired else { return }
            await pipeline.start(items, at: index, fromFrame: frame, firstFrame: interval)
            engine.hasStarted = true
        }
    }

    /// Throws when there is no output and `makeOutput` cannot build one.
    private func makeEngine() throws -> PlayerEngine {
        let lease = try arbiter.lease(building: makeOutput)
        generations += 1
        let generation = generations
        let gate = self.gate
        let pipeline = PlaybackPipeline(
            output: lease, capabilities: capabilities,
            negotiateRate: { rate in await gate.requestSampleRate(rate, for: lease) }, makeDecoder: makeDecoder)
        // Before it starts, so its first configure compiles the chain.
        pipeline.setSound(sound)
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
        if let engine {
            self.engine = nil
            engine.retire()
            retiredClips += engine.pipeline.soundMeters.clipCount
        }
        // After the output stopped: ending the scrub first would let a render call play the ring in between.
        abandonScrub()
    }

    /// Configures and activates the session, in turn with the negotiations, then reads the route again: the port and
    /// volume read before activation may be stale. With `preferredRate`, the session comes up at that rate if the
    /// hardware takes it, so the start's own negotiation finds nothing to change (final review I6).
    private func activateSession(preferredRate: Int?) async throws {
        let losses = sessionLosses
        try await gate.activate(preferredRate: preferredRate)
        // If the session was lost again meanwhile (an interruption), the next start activates it again.
        if sessionLosses == losses { sessionActive = true }
        signal.port = session.currentPort
        signal.systemVolume = session.outputVolume
    }

    /// The system deactivated the session, or the media server took it down.
    // MARK: Scrubbing

    /// Whether a finger is on the record (or its let-go is still settling).
    public var isScrubbing: Bool { scrubRun != nil }

    /// A finger took hold of the record (spec §4.3). From now until `endScrub`, the music follows the hand: the
    /// render thread plays it where the hand puts it, at the hand's speed and direction, through a band-limited
    /// resampler. A playing record brakes to a stop under the finger; a paused one stays silent until it is turned.
    ///
    /// Returns whether the record is now held: false when nothing is playing or paused, or while a start or a seek is
    /// still on its way (the caller then treats the turn as a plain jog, applied on release).
    @discardableResult
    public func beginScrub() -> Bool {
        if let run = scrubRun {
            guard run.settling != nil else { return true }
            // Touched again while the last let-go was still settling (a scratch): carry on from where the needle is.
            run.settling?.cancel()
            run.settling = nil
            guard engine === run.engine, !run.engine.isRetired else {
                abandonScrub()
                return beginScrub()
            }
            let anchor = run.engine.pipeline.scrubAnchor
            let tap = run.tap
            let generation = tap.generation.load(ordering: .acquiring)
            let handedOver = tap.handedOver.load(ordering: .acquiring) == generation
            let frame = handedOver ? anchor.frame : Int64(tap.voicePosition.rounded(.down))
            let speed = handedOver ? 1 : tap.voiceSpeed
            run.anchorFrame = frame
            run.offsetFrames = 0
            tap.begin(
                window: run.window, anchorFrame: frame, anchorRendered: anchor.rendered, startSpeed: speed,
                ringAllowed: run.wasPlaying)
            signal.scrubbing = true
            return true
        }
        guard let index = currentIndex, queue.indices.contains(index) else { return false }
        let playing = status == .playing
        guard playing || status == .paused else { return false }
        let item = queue[index]
        let runEngine: PlayerEngine
        let anchorFrame: Int64
        let anchorRendered: Int64
        if playing {
            guard let current = engine, current.hasStarted, current.seeksInFlight == 0 else { return false }
            let anchor = current.pipeline.scrubAnchor
            guard anchor.index == index else { return false }
            runEngine = current
            anchorFrame = anchor.frame
            anchorRendered = anchor.rendered
        } else {
            // Nothing runs while paused (ruling R15): start a pipeline at the cue whose render thread plays only the
            // voice. The status stays paused, and the pipeline goes again when the hand lets go.
            guard cue.index == index, let started = startForScrub(at: index, frame: cue.frame) else { return false }
            runEngine = started
            anchorFrame = cue.frame
            anchorRendered = 0
        }
        let window = ScrubWindow(format: item.format, totalFrames: item.totalFrames, at: anchorFrame)
        // At the gain the ring plays the item at, so the voice and the ring meet at one level.
        var voiceItem = item.playbackItem
        voiceItem.gainDb = gainDb(at: index)
        let filler = ScrubFiller(item: voiceItem, window: window, makeDecoder: makeDecoder)
        let tap = runEngine.pipeline.scrubTap
        // Before the paused pipeline's first render: its render thread starts with the voice.
        tap.begin(
            window: window, anchorFrame: anchorFrame, anchorRendered: anchorRendered, startSpeed: playing ? 1 : 0,
            ringAllowed: playing)
        filler.start()
        scrubRun = ScrubRun(
            index: index, engine: runEngine, tap: tap, window: window, filler: filler, wasPlaying: playing,
            anchorFrame: anchorFrame)
        signal.scrubbing = true
        return true
    }

    /// The hand is `offsetSeconds` of music from where it took hold (one turn of the record is 1.8 s, forward
    /// clockwise) and turns the record at platter speed `speed` (1 is normal play, negative backwards).
    public func scrub(offsetSeconds: Double, speed: Double) {
        guard let run = scrubRun, run.settling == nil else { return }
        let frames = offsetSeconds * Double(run.window.sourceRate)
        run.offsetFrames = frames
        run.tap.setHand(offsetFrames: frames, speed: min(max(speed, -Self.fastestHand), Self.fastestHand))
    }

    /// The fastest a hand turns the record, in platter speeds: faster readings are touch noise.
    static let fastestHand = 8.0

    /// The hand let go. A playing record catches the platter turning under it, back to speed over `spinUpSeconds`
    /// from rest (a slipmat's fraction of a second by default), and the pipeline takes over exactly where the needle
    /// is, with a short cross-fade. A paused record stays paused where the hand left it. The returned task finishes
    /// once that has settled.
    @discardableResult
    public func endScrub(spinUpSeconds: Double = 0.15) -> Task<Void, Never> {
        guard let run = scrubRun, run.settling == nil else { return Task {} }
        let task = Task { [weak self] in
            guard let self else { return }
            await settle(run, spinUpSeconds: spinUpSeconds)
        }
        run.settling = task
        return task
    }

    private func settle(_ run: ScrubRun, spinUpSeconds: Double) async {
        let tap = run.tap
        let rate = Double(run.window.sourceRate)
        let generation = tap.generation.load(ordering: .acquiring)
        let voiceStarted = tap.voiceStarted.load(ordering: .acquiring) == generation
        if run.wasPlaying {
            // No voice ever started (its music was not decoded in time, or could not be): the ring played on all
            // along, so there is nothing to hand back.
            guard voiceStarted else {
                finishScrub(run)
                return
            }
            tap.motorSecondsBits.store(max(spinUpSeconds, 0.01).bitPattern, ordering: .relaxed)
            tap.phase.store(ScrubTap.Phase.motor.rawValue, ordering: .releasing)
            // The motor first: the ring can only take over once the record turns at exactly normal speed.
            try? await Task.sleep(for: .seconds(spinUpSeconds))
            let deadline = ContinuousClock.now + .seconds(4)
            while tap.voiceSpeed < 0.9999, ContinuousClock.now < deadline {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard !Task.isCancelled else { return }
            guard engine === run.engine, !run.engine.isRetired, queue.indices.contains(run.index) else {
                finishScrub(run)
                return
            }
            // Line the ring up a little ahead of the needle, so its audio is buffered by the time the needle gets
            // there; the render thread switches over at that exact frame (or skips the ring forward if the seek was
            // slower than the lead).
            var target = Int64(tap.voicePosition.rounded(.down)) + Int64(Self.handoverLead * rate)
            if run.window.totalFrames > 0 { target = min(target, run.window.totalFrames) }
            target = max(target, 0)
            let item = queue[run.index]
            cue = Cue(index: run.index, frame: target)
            position = item.duration(ofFrames: target)
            nowPlaying.show(item, elapsed: position, playing: true)
            run.engine.seeksInFlight += 1
            await run.engine.enqueue { pipeline in
                await pipeline.seek(toFrame: target, firstFrame: FirstFrameInterval(.seek))
            }.value
            run.engine.seeksInFlight -= 1
            // Only now, with the seek's hold in place: before it, the ring still holds the audio from before the
            // hand took hold, which must not be faded into.
            tap.handoverFrame.store(target, ordering: .releasing)
            let handoverDeadline = ContinuousClock.now + .seconds(1.5)
            while tap.handedOver.load(ordering: .acquiring) != generation, ContinuousClock.now < handoverDeadline {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard !Task.isCancelled else { return }
        } else {
            tap.phase.store(ScrubTap.Phase.fade.rawValue, ordering: .releasing)
            try? await Task.sleep(for: .seconds(RenderSource.fadeOutSeconds * 2))
            guard !Task.isCancelled else { return }
            var frame = run.anchorFrame + Int64(run.offsetFrames.rounded())
            if run.window.totalFrames > 0 { frame = min(frame, run.window.totalFrames) }
            frame = max(frame, 0)
            // The output stops first (retireEngine also ends the run), so nothing renders after the fade.
            if engine === run.engine { retireEngine() }
            finishScrub(run)
            // A transport command while the hand was down already moved the cue: it wins.
            if queue.indices.contains(run.index), cue == Cue(index: run.index, frame: run.cueAtBegin) {
                cue = Cue(index: run.index, frame: frame)
                position = queue[run.index].duration(ofFrames: frame)
                showCue(playing: false)
            }
        }
        finishScrub(run)
    }

    /// A transport command while a paused record is held: the command wins, and the scrub's pipeline goes.
    private func endPausedScrub() {
        guard let run = scrubRun, !run.wasPlaying else { return }
        if engine === run.engine { retireEngine() }
        abandonScrub()
    }

    /// How far ahead of the needle the ring is lined up at the handover.
    static let handoverLead = 0.15

    /// Ends the current scrub at once: a transport command, a route change or a new queue took over. Callers stop
    /// the output first where it is theirs to stop (see `retireEngine`).
    private func abandonScrub() {
        guard let run = scrubRun else { return }
        run.settling?.cancel()
        finishScrub(run)
    }

    private func finishScrub(_ run: ScrubRun) {
        if scrubRun === run { scrubRun = nil }
        guard !run.finished else { return }
        run.finished = true
        run.tap.retireWindow()
        run.filler.stop()
        signal.scrubbing = false
    }

    /// Where the needle is during a playing record's scrub, once its voice has started and until the ring has taken
    /// over again: the rendered position stands still meanwhile.
    private var scrubNeedle: Cue? {
        guard let run = scrubRun, run.wasPlaying, run.engine === engine else { return nil }
        let tap = run.tap
        let generation = tap.generation.load(ordering: .acquiring)
        guard tap.voiceStarted.load(ordering: .acquiring) == generation,
            tap.handedOver.load(ordering: .acquiring) != generation
        else { return nil }
        return Cue(index: run.index, frame: max(0, Int64(tap.voicePosition.rounded(.down))))
    }

    /// A pipeline at `frame` of `queue[index]` for a paused record's scrub: like `launch`, but the status stays
    /// paused, and until the hand lets go its render thread plays only the voice.
    private func startForScrub(at index: Int, frame: Int64) -> PlayerEngine? {
        let interval = FirstFrameInterval(.resume)
        retireEngine()
        let engine: PlayerEngine
        do {
            engine = try makeEngine()
        } catch {
            return nil
        }
        self.engine = engine
        let items = playbackItems
        let needsActivation = !sessionActive
        let preferredRate = queue[index].format.sampleRate
        _ = engine.enqueue { [weak self] pipeline in
            if needsActivation {
                guard let self else { return }
                do {
                    try await activateSession(preferredRate: preferredRate)
                } catch {
                    return
                }
            }
            guard !engine.isRetired else { return }
            await pipeline.start(items, at: index, fromFrame: frame, firstFrame: interval)
            engine.hasStarted = true
        }
        return engine
    }

    private func loseSession() {
        sessionActive = false
        sessionLosses += 1
    }

    /// Where playback is now: the pipeline's rendered position once it has the queue, the cue before that. While a seek
    /// is on its way to the pipeline, the pipeline still reports the old point and the cue already holds the target,
    /// so a pause, restart or interruption then keeps the seek.
    private func currentPoint() -> Cue {
        if let needle = scrubNeedle { return needle }
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
        launch(at: cue.index, frame: cue.frame, for: .resume)
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
        Telemetry.logger.error("Player failed: \(message, privacy: .public)")
        retireEngine()
        status = .failed(message)
        currentIndex = nil
        position = .zero
        clearSignal()
        nowPlaying.clear()
    }

    /// Points the current index and position at the cue, and publishes it.
    private func showCue(playing: Bool) {
        let item = queue[cue.index]
        currentIndex = cue.index
        position = item.duration(ofFrames: cue.frame)
        nowPlaying.show(item, elapsed: position, playing: playing)
        refreshProcessing()
    }

    // MARK: Events

    /// An event from the current engine's pipeline.
    private func handle(_ event: PipelineEvent) {
        // An event proves the pipeline has the queue, even if `start` has not been seen to return yet.
        engine?.hasStarted = true
        switch event {
        case .planChanged(let plan):
            Telemetry.logger.info("Plan changed: \(String(describing: plan), privacy: .public)")
            // Read the hardware side now, right after the pipeline configured the output for this plan: when the
            // output can see it, it is the honest rate (on the simulator it can stay at 48 kHz under a 44.1 kHz
            // client, ruling R17), and its channel count shows a downmix. The plan is for the track about to start,
            // so it waits for that track's `trackStarted` and is shown with it (T7: plan and rates together). Until
            // then the strip still describes what played last, or "Starting…".
            engine?.negotiated = SignalPath(
                plan: plan, hardwareRate: arbiter.hardwareSideSampleRate ?? plan.clientSampleRate,
                hardwareChannels: arbiter.hardwareSideChannels)
        case .trackStarted(let index, let format, let totalFrames):
            guard queue.indices.contains(index) else { return }
            anyItemStarted = true
            // The decoder's format and length are authoritative (the file may have changed since import). The queue
            // entry takes them, so the strip, positions, seeks and the track's duration all follow what plays.
            if queue[index].format != format { queue[index].format = format }
            if queue[index].totalFrames != totalFrames { queue[index].totalFrames = totalFrames }
            signal.source = format
            // A gapless join keeps the running plan: it has no `planChanged` of its own.
            if let path = engine?.negotiated {
                engine?.negotiated = nil
                show(path)
            }
            // A paused record's scrub pipeline starts its track at once (nothing renders from the ring to hold the
            // marker back), but it plays only the hand's voice: the record stays paused.
            if let run = scrubRun, !run.wasPlaying, run.engine === engine { return }
            status = .playing
            // A resumed track starts mid-way: the pipeline reports the frame it started from.
            let reported = engine?.pipeline.position
            cue = Cue(index: index, frame: reported?.index == index ? reported?.frame ?? 0 : 0)
            showCue(playing: true)
            startTicker()
        case .trackEnded:
            // The next `trackStarted` or `queueEnded` follows.
            break
        case .itemFailed(let index, let message):
            Telemetry.logger.error("Item \(index, privacy: .public) failed: \(message, privacy: .public)")
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
        log(event)
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
                    refreshIdleHardwareRate()
                } else if reason == .newDeviceAvailable || port != previous || hardwareRateMoved {
                    // The hardware may run at another rate now. Restart at the same point, so the client rate matches
                    // it again, rather than let iOS resample silently.
                    let point = currentPoint()
                    launch(at: point.index, frame: point.frame, for: .restart)
                }
            case .paused, .ended:
                refreshIdleHardwareRate()
            case .idle, .failed:
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

    /// Session events in the unified log. A route's name can be the user's device name, so it is private; volume
    /// changes, which come in bursts while the user drags the slider, only at debug level.
    private func log(_ event: SessionEvent) {
        let logger = Telemetry.logger
        switch event {
        case .routeChanged(let reason, let port):
            let why = String(describing: reason)
            let to = String(describing: port)
            logger.info("Route changed (\(why, privacy: .public)): \(to, privacy: .private)")
        case .volumeChanged(let volume):
            logger.debug("Volume \(volume, privacy: .public)")
        case .interruptionBegan, .interruptionEnded, .mediaServicesReset:
            logger.info("Session: \(String(describing: event), privacy: .public)")
        }
    }

    /// While nothing plays (paused, or ended with the last track cued), the next start re-negotiates; until then the
    /// strip follows the hardware, but only a real move. A notification that leaves the hardware at the rate the last
    /// negotiation read back (a category change, the session's own activation) changes nothing: overwriting the
    /// hardware-side rate with the session's rate then would flip the simulator's "Resampled 44.1→48" to "Pure" (R17).
    /// When the hardware has moved, the strip shows the rate it runs at now. When it comes back to the negotiated rate,
    /// the negotiated hardware-side rate is shown again. A pending track (no plan) has nothing to refresh.
    private func refreshIdleHardwareRate() {
        guard let path = shownPath, let settled = gate.settledRate else { return }
        let live = session.sampleRate
        guard live > 0 else { return }
        signal.hardwareRate = live != settled ? live : path.hardwareRate
    }

    /// Whether the hardware has moved off the rate the last negotiation read back, with nothing negotiating now.
    ///
    /// A same-port route change (a category or configuration change) can move the hardware rate mid-track. It is also
    /// what the session's own activation and negotiation post, so the comparison must not set off a restart loop. It
    /// cannot: a notification a negotiation or an activation causes arrives while that call holds the session's turn
    /// (no settled rate, ignored) or after it, when the rate it recorded equals the live rate. An activation records
    /// its rate for exactly this reason (ledger T13): otherwise the settled rate would be the previous negotiation's,
    /// and a notification between a start's activation and its negotiation would restart the start for nothing.
    /// `signal.plan` would not do here, because the new plan's `.planChanged` can arrive after the notification its own
    /// negotiation caused.
    private var hardwareRateMoved: Bool {
        guard let settled = gate.settledRate else { return false }
        let live = session.sampleRate
        return live > 0 && live != settled
    }

    /// The media server died, and the session's configuration with it (ruling 5). Stops the pipeline, pauses at the
    /// current position and re-activates the session; the user resumes.
    ///
    /// The output's audio unit died with the server (final review I4), so the output is stopped and dropped here, and
    /// the next start builds a fresh one through `makeOutput`.
    private func resetMediaServices() {
        resumeAfterInterruption = false
        loseSession()
        pauseNow()
        retireEngine()
        arbiter.discardOutput()
        // If this fails, the next start tries again.
        Task { [weak self] in try? await self?.activateSession(preferredRate: nil) }
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

    // MARK: Signal path

    /// Shows `path`, from the negotiation for the track that has just started.
    private func show(_ path: SignalPath) {
        shownPath = path
        signal.plan = path.plan
        signal.hardwareRate = path.hardwareRate
        signal.hardwareChannels = path.hardwareChannels
    }

    /// Shows `queue[index]` as on its way: its format as recorded at import, and no path until its pipeline has one.
    private func showPending(for index: Int) {
        signal.source = queue[index].format
        forgetPath()
        refreshProcessing()
    }

    /// Nothing to describe: no track, no path. The port and volume stay, as the session reports them.
    private func clearSignal() {
        signal.source = nil
        forgetPath()
    }

    private func forgetPath() {
        shownPath = nil
        signal.plan = nil
        signal.hardwareRate = nil
        signal.hardwareChannels = nil
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
        refreshProcessing()
    }
}

/// What one negotiation established about the path: the plan, and what the output reports for its hardware side.
struct SignalPath: Equatable {
    var plan: OutputPlan
    /// The output's hardware-side rate, or the plan's client rate when the output cannot tell.
    var hardwareRate: Int
    var hardwareChannels: Int?
}

/// A point in the queue: an item and a source frame in it.
private struct Cue: Equatable {
    var index: Int
    var frame: Int64
}

/// One finger on the record: what it brought up, and the pipeline it plays through.
@MainActor
private final class ScrubRun {
    let index: Int
    let engine: PlayerEngine
    let tap: ScrubTap
    let window: ScrubWindow
    let filler: ScrubFiller
    let wasPlaying: Bool
    /// The source frame the hand's offsets count from.
    var anchorFrame: Int64
    /// The cue when the hand took hold (a paused record's): a let-go leaves a cue moved meanwhile alone.
    let cueAtBegin: Int64
    var offsetFrames = 0.0
    /// The let-go settling (spin-up and handover, or fade), while it runs.
    var settling: Task<Void, Never>?
    var finished = false

    init(
        index: Int, engine: PlayerEngine, tap: ScrubTap, window: ScrubWindow, filler: ScrubFiller, wasPlaying: Bool,
        anchorFrame: Int64
    ) {
        self.index = index
        self.engine = engine
        self.tap = tap
        self.window = window
        self.filler = filler
        self.wasPlaying = wasPlaying
        self.anchorFrame = anchorFrame
        cueAtBegin = anchorFrame
    }
}
