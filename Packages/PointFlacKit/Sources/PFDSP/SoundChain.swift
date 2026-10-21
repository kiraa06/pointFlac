import Foundation
import Synchronization

/// What the Sound chain's meters read. The UI's meters add their own peak-hold and decay (Task 9).
public struct SoundMeters: Equatable, Sendable {
    /// The highest sample written since the previous read of ``ChainRunner/meters``, in dBFS, floored at −120.
    ///
    /// It is the peak since the last read, not of the latest block, so a meter polled at any rate misses no peak
    /// between its polls. Each read starts a new interval, so the runner should have one reader. Pure blocks are never
    /// read (they are left untouched), so in Pure it stays at the floor.
    public var peakDbFS: Double
    /// Samples written above full scale (|x| > 1) since the runner was made. The limiter keeps the chain's own output
    /// under its ceiling, so overs come only from the dry signal, in a fade from or to Pure.
    public var clipCount: Int
    /// The deepest limiter reduction in the latest block, in dB: 0 while the limiter is transparent, and in Pure.
    public var gainReductionDb: Double

    public init(peakDbFS: Double, clipCount: Int, gainReductionDb: Double) {
        self.peakDbFS = peakDbFS
        self.clipCount = clipCount
        self.gainReductionDb = gainReductionDb
    }
}

/// The Sound section's interactive blocks, compiled for one output rate and channel count (plan ruling R4-1): the
/// preamp, headphone correction, EQ and tone as biquads per channel, crossfeed (stereo only), then the true-peak
/// limiter, in Float64.
///
/// A chain is immutable once made: a settings change compiles a new chain, which a ``ChainRunner`` cross-fades in. Its
/// filter, crossfeed and limiter state belongs to the render thread of the runner that installed it.
///
/// ## Compiling
/// It works from `clamped()` settings, and drops what clamping lets through as NaN, so no NaN coefficient or gain can
/// reach the render thread: a band with a non-finite frequency, gain or Q is left out, and a non-finite trim,
/// correction preamp, graphic slider or tone control counts as 0 dB.
///
/// The gain ahead of the filters, ``preampDb``, is the sum of (ruling R4-T6a):
/// - the correction's own preamp, while correction is on;
/// - the automatic headroom, while it is on: `SoundResponse.autoHeadroomDb`, which sizes the headroom for the
///   response including the correction's preamp but does not apply that preamp itself;
/// - the trim.
///
/// That sum is then capped so the loudest frequency is driven at most +120 dB into the limiter (`maxDriveDb`). Only
/// stacked boosts with automatic headroom off get there (twenty +24 dB bands make +480 dB), and well past it, about
/// +280 dB, the limiter's gain, a Double, can no longer resolve the reduction it needs.
///
/// Pure settings compile to a chain that only delays (its limiter is transparent below the ceiling). Install nil for
/// Pure, which is bit-identical and has no delay.
///
/// ## State carried over
/// A chain made for the same rate and channel count as the one it replaces takes over that chain's state when the
/// runner installs it. Each filter keeps the state of the filter at the same place (block, index in that block's band
/// list, shape) with its own coefficients; crossfeed keeps its state if the preset is unchanged; and the limiter
/// carries on with its look-ahead, hold and release. Dragging one band then changes only that band's sound, and
/// reinstalling the same settings is inaudible.
public final class SoundChain: @unchecked Sendable {
    public let sampleRate: Double
    public let channels: Int
    /// Frames from input to output: the limiter's look-ahead. The filters and crossfeed add none.
    public let latencyFrames: Int
    /// The gain ahead of the filters, in dB (see "Compiling").
    public let preampDb: Double
    /// The settings it was compiled from, clamped and cleaned: a runner recompiles from them if it is installed twice.
    let settings: SoundSettings
    /// The runner's crossfade into this chain, 10 ms at its rate.
    let fadeFrames: Int

    /// Past this, in dB of drive at the loudest frequency, the preamp is pulled back (see "Compiling").
    static var maxDriveDb: Double { 120 }

    private let gain: Double
    /// Filters per channel, in chain order.
    private let sections: Int
    /// `channels × sections` filters, channel-major.
    private let biquads: UnsafeMutablePointer<Biquad>
    /// Each section's `FilterPlace.key`, for carrying state over.
    private let keys: UnsafeMutablePointer<UInt64>
    /// Stereo with crossfeed on only.
    private let crossfeed: UnsafeMutablePointer<Crossfeed>?
    /// The crossfeed preset's index, or −1: compared on the render thread, so a plain integer.
    private let crossfeedCode: Int
    private let limiter: TruePeakLimiter
    /// `limiter`, unretained, so the render thread reaches it without reference counting. `limiter` keeps it alive.
    private let unretainedLimiter: Unmanaged<TruePeakLimiter>
    /// Set by the first `install`: a chain runs in one runner only, once.
    let claimed = Atomic<Bool>(false)

    #if DEBUG
        /// Counts the chains made while it is the task's ``liveCounter`` that are still alive. Debug builds only, for
        /// tests that check every retired chain is freed.
        final class LiveCounter: Sendable {
            private let count = Atomic<Int>(0)
            var value: Int { count.load(ordering: .acquiring) }
            fileprivate func add() { count.add(1, ordering: .relaxed) }
            fileprivate func remove() { count.subtract(1, ordering: .relaxed) }
        }

        /// The counter chains made in this task (or synchronously inside its `withValue`) count themselves in. Scoped
        /// rather than process-wide, so a test counting its own chains is not thrown by other suites making chains in
        /// parallel in the same test process (Task 7's pipeline tests do).
        @TaskLocal static var liveCounter: LiveCounter?
        /// The counter this chain counted itself in, read once in `init`: `deinit` may run on another thread.
        private let counter: LiveCounter?
    #endif

    /// Compiles `s` for `channels` interleaved channels at `sampleRate`. Allocates: call it off the render thread.
    public init(_ s: SoundSettings, sampleRate: Double, channels: Int) {
        precondition(channels > 0, "SoundChain needs at least one channel")
        precondition(sampleRate.isFinite && sampleRate > 0, "SoundChain needs a sample rate")
        let s = Self.compilable(s)
        settings = s
        self.sampleRate = sampleRate
        self.channels = channels

        // The filters SoundResponse designs (so the graph shows what plays), with their places, in the same order.
        let filters = SoundResponse.filters(s, sampleRate: sampleRate)
        let places = SoundResponse.placedBands(s).map(\.place.key)
        let kept = zip(places, filters).filter { _, c in [c.b0, c.b1, c.b2, c.a1, c.a2].allSatisfy(\.isFinite) }
        sections = kept.count
        biquads = .allocate(capacity: max(1, channels * kept.count))
        keys = .allocate(capacity: max(1, kept.count))
        for (i, (key, c)) in kept.enumerated() {
            keys[i] = key
            for channel in 0..<channels { (biquads + channel * kept.count + i).initialize(to: Biquad(c)) }
        }

        let headroom = SoundResponse.autoHeadroomDb(s, sampleRate: sampleRate)
        var preamp = 0.0
        if !s.pure {
            let correction = s.correction.enabled ? s.correction.preampDb : 0
            preamp = correction + (s.preamp.autoHeadroom ? headroom : 0) + s.preamp.trimDb
            // −headroom is how far the curve, correction preamp included, peaks above 0 dB (0 if it doesn't).
            let loudest = -headroom + preamp - correction
            if loudest > Self.maxDriveDb { preamp -= loudest - Self.maxDriveDb }
        }
        preampDb = preamp.isFinite ? preamp : 0
        gain = pow(10, preampDb / 20)

        if channels == 2, !s.pure, s.crossfeed.enabled {
            crossfeed = .allocate(capacity: 1)
            crossfeed?.initialize(to: Crossfeed(preset: s.crossfeed.preset, sampleRate: sampleRate))
            crossfeedCode = CrossfeedPreset.allCases.firstIndex(of: s.crossfeed.preset) ?? 0
        } else {
            crossfeed = nil
            crossfeedCode = -1
        }

        limiter = TruePeakLimiter(channels: channels, sampleRate: sampleRate, ceilingDbTP: s.limiter.ceilingDbTP)
        unretainedLimiter = .passUnretained(limiter)
        latencyFrames = limiter.latencyFrames
        fadeFrames = max(1, Int((ChainRunner.fadeSeconds * sampleRate).rounded()))
        #if DEBUG
            counter = Self.liveCounter
            counter?.add()
        #endif
    }

    /// A fresh chain from `other`'s settings, rate and channels, for a runner asked to install a chain twice.
    convenience init(recompiling other: SoundChain) {
        self.init(other.settings, sampleRate: other.sampleRate, channels: other.channels)
    }

    deinit {
        biquads.deinitialize(count: channels * sections)
        biquads.deallocate()
        keys.deallocate()
        if let crossfeed {
            crossfeed.deinitialize(count: 1)
            crossfeed.deallocate()
        }
        #if DEBUG
            counter?.remove()
        #endif
    }

    /// `s` clamped, with what clamping lets through as NaN taken out (see "Compiling").
    static func compilable(_ settings: SoundSettings) -> SoundSettings {
        var s = settings.clamped()
        func finite(_ db: Double) -> Double { db.isFinite ? db : 0 }
        func checked(_ band: EQBand) -> EQBand {
            var band = band
            if !(band.frequency.isFinite && band.gainDb.isFinite && band.q.isFinite) { band.enabled = false }
            return band
        }
        s.preamp.trimDb = finite(s.preamp.trimDb)
        s.correction.preampDb = finite(s.correction.preampDb)
        s.correction.bands = s.correction.bands.map(checked)
        s.eq.bands = s.eq.bands.map(checked)
        s.eq.graphicGainsDb = s.eq.graphicGainsDb.map(finite)
        s.tone.bassDb = finite(s.tone.bassDb)
        s.tone.trebleDb = finite(s.tone.trebleDb)
        s.tone.tiltDb = finite(s.tone.tiltDb)
        if !s.limiter.ceilingDbTP.isFinite { s.limiter.ceilingDbTP = LimiterSettings().ceilingDbTP }
        return s
    }

    // MARK: Render thread

    /// The deepest reduction of the limiter's latest block, in dB.
    var gainReductionDb: Double {
        unretainedLimiter._withUnsafeGuaranteedRef { $0.gainReductionDb }
    }

    /// Runs `frames` interleaved frames through the chain in place: preamp, filters, crossfeed, limiter. Non-finite
    /// input samples are taken as silence. Real-time safe: no allocation, locks, logging or reference counting.
    func process(_ io: UnsafeMutablePointer<Double>, frames: Int) {
        guard frames > 0 else { return }
        let channels = channels
        let sections = sections
        let gain = gain
        for channel in 0..<channels {
            var p = io + channel
            for _ in 0..<frames {
                let x = p.pointee
                p.pointee = x.isFinite ? x * gain : 0
                p += channels
            }
            let row = biquads + channel * sections
            for section in 0..<sections {
                var filter = row[section]
                var q = io + channel
                for _ in 0..<frames {
                    q.pointee = filter.process(q.pointee)
                    q += channels
                }
                row[section] = filter
            }
        }
        if let crossfeed {
            var filter = crossfeed.pointee
            var p = io
            for _ in 0..<frames {
                var left = p[0]
                var right = p[1]
                filter.process(left: &left, right: &right)
                p[0] = left
                p[1] = right
                p += 2
            }
            crossfeed.pointee = filter
        }
        unretainedLimiter._withUnsafeGuaranteedRef { $0.process(io, frames: frames) }
    }

    /// Takes over `old`'s state where it fits (see "State carried over"). Does nothing across rates or channel counts.
    /// Real-time safe.
    func adoptState(of old: SoundChain) {
        guard old.biquads != biquads, old.channels == channels, old.sampleRate == sampleRate else { return }
        let channels = channels
        for section in 0..<sections {
            let key = keys[section]
            var match = -1
            var i = 0
            while i < old.sections {
                if old.keys[i] == key {
                    match = i
                    break
                }
                i += 1
            }
            guard match >= 0 else { continue }
            for channel in 0..<channels {
                let mine = biquads + channel * sections + section
                var carried = old.biquads[channel * old.sections + match]
                carried.c = mine.pointee.c
                mine.pointee = carried
            }
        }
        if let crossfeed, let theirs = old.crossfeed, crossfeedCode == old.crossfeedCode {
            crossfeed.pointee = theirs.pointee
        }
        unretainedLimiter._withUnsafeGuaranteedRef { mine in
            old.unretainedLimiter._withUnsafeGuaranteedRef { mine.adoptState(of: $0) }
        }
    }
}

/// Runs the installed ``SoundChain`` on the render thread and swaps chains without a click (Review Focus 3).
///
/// ## Install protocol
/// 1. `install` retains the chain and exchanges it into the mailbox, an `Atomic<UnsafeMutableRawPointer?>`; Pure is
///    a sentinel. A chain it takes back out of the mailbox was never seen by the render thread (an exchange hands each
///    pointer to exactly one side), so it is released at once. `install` may be called from any thread but the render
///    thread; calls are serialised.
/// 2. The render thread takes the mailbox at the start of a block, or of the rest of one, whenever no fade is in
///    flight: the latest install wins, and a fade is never cut short. So an install waits at most for the transition
///    in flight, one chain's latency plus 10 ms.
/// 3. A new chain first takes over the old one's state (see ``SoundChain``) and runs unheard for its latency, so its
///    look-ahead holds its own output. Then old and new run in parallel for 10 ms under an equal-gain crossfade (the
///    weights sum to 1, as for correlated signals). Pure is the dry signal, so a fade to Pure starts at once. A fade
///    between a chain and Pure mixes a delayed signal with an undelayed one, a brief comb but no click.
/// 4. When the fade ends, the render thread hands the old chain back through a lock-free ring; nothing is released on
///    the render thread. `install` drains the ring, and so does a 100 ms timer while chains are still out (it gives up
///    after a second with none coming back, when the output has stopped mid-fade, and the next `install` drains).
/// 5. Draining follows `ScrubTap.retireWindow`: it waits, at most 200 ms, until no render call is inside
///    (`rendering`, stored sequentially consistently before a call touches any chain and loaded so by the drain), so a
///    chain is never freed under the call that handed it back. If a call is still inside after that (a stalled render
///    thread), the chains are stranded: kept, not freed, until the runner itself goes.
///
/// ## Format changes
/// `reset(to:)` replaces everything at once, with no fade and no state carried over, while the output is stopped: a
/// chain compiled for a new rate or channel count starts from rest (Task 7, Review Focus 1).
///
/// ## Pure
/// With no chain and no fade in flight, `process` returns without touching `io`: the output is bit-identical.
///
/// ## Blocks a chain can't take
/// A block longer than `maxFrames` is processed in pieces of at most `maxFrames`. A chain made for another channel
/// count than the block's sits that block out as the dry signal, and a block of more than `maxChannels` channels is
/// never processed. So when no chain can take a block, the block is left untouched (bypassed), though a fade in flight
/// still runs its course. No frame or channel count makes the render thread trap or read out of bounds.
///
/// ## Real-time safety
/// `process` allocates nothing, takes no locks, logs nothing and causes no reference counting: it reaches chains
/// through unretained pointers, and all scratch is allocated in `init`. Call it from one thread at a time. The chain
/// conversion from and to Float32 is done in that scratch; the chain runs in Float64.
public final class ChainRunner: @unchecked Sendable {
    public let maxFrames: Int
    public let maxChannels: Int
    static let fadeSeconds = 0.010

    /// Main side → render thread: a retained chain, the Pure sentinel, or nil when nothing is waiting.
    private let mailbox = Atomic<UnsafeMutableRawPointer?>(nil)
    /// Set while a render call may touch a chain (see "Install protocol" step 5).
    private let rendering = Atomic<Bool>(false)

    /// Render thread → main side: retired chains, still retained, in a single-producer, single-consumer ring.
    private let retireSlots: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private let retireMask = 7
    private let retireWritten = Atomic<Int>(0)
    private let retireRead = Atomic<Int>(0)

    /// The render thread's own state. Allocated once, never freed while the runner lives; plain values only.
    private let state: UnsafeMutablePointer<RenderState>
    /// Float64 scratch, `maxFrames × maxChannels` each: the incoming chain's side and the outgoing side.
    private let incoming: UnsafeMutablePointer<Double>
    private let outgoing: UnsafeMutablePointer<Double>

    // Meters, render thread → any thread.
    private let peakBits = Atomic<UInt64>(0)
    private let clips = Atomic<Int>(0)
    private let reductionBits = Atomic<UInt64>(0)

    private let control = Mutex(Control())

    private struct RenderState {
        /// The chain playing, retained by the render side; nil in Pure.
        var current: UnsafeMutableRawPointer?
        /// During a fade, the chain fading out, retained; nil when that side is the dry signal.
        var leaving: UnsafeMutableRawPointer?
        var fading = false
        /// Frames since the fade began, its silent start (the new chain's latency) included.
        var elapsed = 0
        var prime = 0
        var length = 1
        var inverseLength = 1.0
        /// A retired chain the ring had no room for. While set, no new chain is taken.
        var unreturned: UnsafeMutableRawPointer?
    }

    /// Main side, under `control`.
    private struct Control {
        /// Chains whose reference the render side holds: in the mailbox, playing, fading or in the ring.
        var outstanding = 0
        /// The latest install was a chain, which the render thread keeps playing.
        var keepsOne = false
        var timer: DispatchSourceTimer?
        /// Timer ticks in a row that found nothing to drain: the render thread has stopped, mid-fade.
        var idleTicks = 0
        /// Chains a stalled render call might still have been inside when they came back: kept until the runner goes.
        var stranded: [SoundChain] = []
    }

    /// Stands for Pure in the mailbox. Computed, not stored, so the render thread never runs a lazy initialiser.
    private static var pure: UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: 1)! }

    private static let drainQueue = DispatchQueue(label: "pointFlac.sound.retire", qos: .utility)

    /// - Parameters:
    ///   - maxFrames: the largest piece of a block processed at once; longer blocks are split.
    ///   - maxChannels: the most channels processed; blocks of more are left untouched.
    public init(maxFrames: Int = 4096, maxChannels: Int = 8) {
        precondition(maxFrames > 0 && maxChannels > 0, "ChainRunner needs room for at least one sample")
        self.maxFrames = maxFrames
        self.maxChannels = maxChannels
        retireSlots = .allocate(capacity: 8)
        retireSlots.initialize(repeating: nil, count: 8)
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState())
        incoming = .allocate(capacity: maxFrames * maxChannels)
        incoming.initialize(repeating: 0, count: maxFrames * maxChannels)
        outgoing = .allocate(capacity: maxFrames * maxChannels)
        outgoing.initialize(repeating: 0, count: maxFrames * maxChannels)
    }

    /// Frees every chain the runner still holds. No render call may be running: the owner stops the output first.
    deinit {
        control.withLock { control in
            control.timer?.cancel()
            control.timer = nil
        }
        var held: [UnsafeMutableRawPointer] = []
        if let waiting = mailbox.exchange(nil, ordering: .acquiringAndReleasing), waiting != Self.pure {
            held.append(waiting)
        }
        held += [state.pointee.current, state.pointee.leaving, state.pointee.unreturned].compactMap { $0 }
        var read = retireRead.load(ordering: .acquiring)
        let written = retireWritten.load(ordering: .acquiring)
        while read != written {
            if let chain = retireSlots[read & retireMask] { held.append(chain) }
            read += 1
        }
        for chain in held { Unmanaged<SoundChain>.fromOpaque(chain).release() }
        retireSlots.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
        incoming.deallocate()
        outgoing.deallocate()
    }

    // MARK: Main side

    /// Plays `chain` from the render thread's next block, cross-faded in over 10 ms; nil is Pure. Any thread but the
    /// render thread. A chain already installed (here or in another runner) is recompiled, so no two runs ever share
    /// filter state; the copy picks up the playing chain's state, so this is seamless.
    public func install(_ chain: SoundChain?) {
        let chain = chain.map(Self.claim)
        let pointer = chain.map { Unmanaged.passRetained($0).toOpaque() } ?? Self.pure
        control.withLock { control in
            let displaced = mailbox.exchange(pointer, ordering: .acquiringAndReleasing)
            if chain != nil { control.outstanding += 1 }
            control.keepsOne = chain != nil
            if let displaced, displaced != Self.pure {
                // The render thread never took it.
                Unmanaged<SoundChain>.fromOpaque(displaced).release()
                control.outstanding -= 1
            }
            drain(&control)
            control.idleTicks = 0
            updateTimer(&control)
        }
    }

    /// Plays `chain` from the next render call at once, with no fade and nothing of what played before: every chain
    /// the runner holds (playing, fading out, waiting in the mailbox or handed back) is released, and the new one
    /// starts from rest, its look-ahead empty. nil is Pure. For a format change, where the old chain's filters and
    /// look-ahead hold the previous track, at another rate or channel count: a fade from it would play that tail into
    /// the new track, through filters designed for the wrong rate.
    ///
    /// Only while no render call can run: the output is stopped (`AudioOutput.stop()` returns once no render call is
    /// in flight) and not started again until this returns, as for `RenderSource.flushWhileStopped`. It writes the
    /// render thread's own state, which the output's stop and start order against the render calls either side.
    /// Serialised with `install`.
    public func reset(to chain: SoundChain?) {
        let chain = chain.map(Self.claim)
        control.withLock { control in
            var held: [UnsafeMutableRawPointer] = []
            if let waiting = mailbox.exchange(nil, ordering: .acquiringAndReleasing), waiting != Self.pure {
                held.append(waiting)
            }
            held += [state.pointee.current, state.pointee.leaving, state.pointee.unreturned].compactMap { $0 }
            // No render call is inside, so the handshake passes at once.
            drain(&control)
            state.pointee = RenderState()
            state.pointee.current = chain.map { Unmanaged.passRetained($0).toOpaque() }
            reductionBits.store(0, ordering: .relaxed)
            for old in held { Unmanaged<SoundChain>.fromOpaque(old).release() }
            control.outstanding += (chain == nil ? 0 : 1) - held.count
            control.keepsOne = chain != nil
            control.idleTicks = 0
            updateTimer(&control)
        }
    }

    /// `chain`, or a fresh compile of it if it was ever installed (here or in another runner), so no two runs share
    /// filter state.
    private static func claim(_ chain: SoundChain) -> SoundChain {
        guard chain.claimed.exchange(true, ordering: .relaxed) else { return chain }
        let copy = SoundChain(recompiling: chain)
        copy.claimed.store(true, ordering: .relaxed)
        return copy
    }

    /// The meters (see ``SoundMeters``). Reading starts a new peak interval. Any thread.
    public var meters: SoundMeters {
        let peak = Double(bitPattern: peakBits.exchange(0, ordering: .relaxed))
        return SoundMeters(
            peakDbFS: peak > 0 ? max(20 * log10(peak), -120) : -120,
            clipCount: clips.load(ordering: .relaxed),
            gainReductionDb: Double(bitPattern: reductionBits.load(ordering: .relaxed)))
    }

    /// Releases the chains the render thread has handed back, once no render call can still be inside the call that
    /// handed them back (`ScrubTap.retireWindow`'s handshake). Returns whether any came back.
    @discardableResult
    private func drain(_ control: inout Control) -> Bool {
        let written = retireWritten.load(ordering: .acquiring)
        var read = retireRead.load(ordering: .relaxed)
        guard read != written else { return false }
        var returned: [UnsafeMutableRawPointer] = []
        while read != written {
            if let chain = retireSlots[read & retireMask] { returned.append(chain) }
            read += 1
        }
        retireRead.store(read, ordering: .releasing)
        control.outstanding -= returned.count
        // A render call that handed one back set `rendering` first (sequentially consistent with these loads), so once
        // it reads false no call can still be inside.
        let deadline = ContinuousClock.now + .milliseconds(200)
        while rendering.load(ordering: .sequentiallyConsistent), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.0005)
        }
        if rendering.load(ordering: .sequentiallyConsistent) {
            // A render call still inside after 200 ms (a stalled render thread): never free them under it.
            control.stranded += returned.map { Unmanaged<SoundChain>.fromOpaque($0).takeRetainedValue() }
            return true
        }
        for chain in returned { Unmanaged<SoundChain>.fromOpaque(chain).release() }
        return true
    }

    /// Runs the 100 ms drain timer while chains are expected back, and stops it once none are, or after a second with
    /// none coming back (the output stopped mid-fade: the next `install` drains them instead).
    private func updateTimer(_ control: inout Control) {
        let expected = control.outstanding > (control.keepsOne ? 1 : 0) && control.idleTicks < 10
        if expected, control.timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: Self.drainQueue)
            timer.schedule(
                deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.control.withLock { control in
                    control.idleTicks = self.drain(&control) ? 0 : control.idleTicks + 1
                    self.updateTimer(&control)
                }
            }
            timer.resume()
            control.timer = timer
        } else if !expected, let timer = control.timer {
            timer.cancel()
            control.timer = nil
        }
    }

    // MARK: Render thread

    /// Whether `process` would return at once, leaving the block untouched: Pure, with no fade in flight, nothing
    /// waiting to be handed back and nothing in the mailbox (a relaxed load). Render thread only, as it reads the
    /// render state. A caller that has to convert samples for `process` (an Int32 client) skips the conversion then.
    @inline(__always)
    public var isIdle: Bool {
        let state = state
        return state.pointee.current == nil && !state.pointee.fading && state.pointee.unreturned == nil
            && mailbox.load(ordering: .relaxed) == nil
    }

    /// Runs `frames` interleaved Float32 frames of `channels` channels through the installed chain, in place. Render
    /// thread only, one call at a time; real-time safe.
    public func process(_ io: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0, !isIdle else { return }
        let state = state
        // Announce the call before touching any chain (sequentially consistent with `drain`).
        rendering.store(true, ordering: .sequentiallyConsistent)
        defer { rendering.store(false, ordering: .releasing) }

        var meter = Meter()
        var done = 0
        while done < frames {
            if let unreturned = state.pointee.unreturned, handBack(unreturned) { state.pointee.unreturned = nil }
            if !state.pointee.fading, state.pointee.unreturned == nil { takeMailbox() }
            var n = min(frames - done, maxFrames)
            if state.pointee.fading {
                n = min(n, state.pointee.prime + state.pointee.length - state.pointee.elapsed)
            }
            render(io + done * channels, frames: n, channels: channels, &meter)
            done += n
        }

        if meter.peak > 0 { peakBits.max(Double(meter.peak).bitPattern, ordering: .relaxed) }
        if meter.clipped > 0 { clips.wrappingAdd(meter.clipped, ordering: .relaxed) }
        let pure = state.pointee.current == nil && !state.pointee.fading
        reductionBits.store(pure ? 0 : meter.reduction.bitPattern, ordering: .relaxed)
    }

    private struct Meter {
        var peak: Float = 0
        var clipped = 0
        var reduction = 0.0

        @inline(__always)
        mutating func write(_ y: Float) {
            let magnitude = y.magnitude
            if magnitude > peak { peak = magnitude }
            if magnitude > 1 { clipped += 1 }
        }
    }

    /// Takes the waiting install, if any, and starts the fade to it.
    private func takeMailbox() {
        guard mailbox.load(ordering: .relaxed) != nil,
            let next = mailbox.exchange(nil, ordering: .acquiringAndReleasing)
        else { return }
        let state = state
        let old = state.pointee.current
        if next == Self.pure {
            guard let old else { return }
            state.pointee.current = nil
            begin(leaving: old, prime: 0, length: Self.withChain(old) { $0.fadeFrames })
            return
        }
        if let old {
            Self.withChain(next) { new in Self.withChain(old) { new.adoptState(of: $0) } }
        }
        state.pointee.current = next
        // Two calls rather than one returning a tuple, whose metadata a debug build would instantiate here.
        let latency = Self.withChain(next) { $0.latencyFrames }
        let length = Self.withChain(next) { $0.fadeFrames }
        begin(leaving: old, prime: latency, length: length)
    }

    private func begin(leaving: UnsafeMutableRawPointer?, prime: Int, length: Int) {
        state.pointee.leaving = leaving
        state.pointee.fading = true
        state.pointee.elapsed = 0
        state.pointee.prime = prime
        state.pointee.length = max(1, length)
        state.pointee.inverseLength = 1 / Double(max(1, length))
    }

    /// Hands a retired chain to the main side through the ring; false if the ring is full.
    private func handBack(_ chain: UnsafeMutableRawPointer) -> Bool {
        let written = retireWritten.load(ordering: .relaxed)
        guard written - retireRead.load(ordering: .acquiring) <= retireMask else { return false }
        retireSlots[written & retireMask] = chain
        retireWritten.store(written + 1, ordering: .releasing)
        return true
    }

    /// One piece of a block, at most `maxFrames` and never past the end of a fade.
    private func render(_ io: UnsafeMutablePointer<Float>, frames: Int, channels: Int, _ meter: inout Meter) {
        let state = state
        let fading = state.pointee.fading
        let fits = channels <= maxChannels
        let current = fits ? usable(state.pointee.current, channels: channels) : nil
        let leaving = fits && fading ? usable(state.pointee.leaving, channels: channels) : nil
        defer { if fading { advance(frames) } }
        // Nothing to run: Pure, or no chain for this channel count. The block stays untouched.
        guard current != nil || leaving != nil else { return }

        let count = frames * channels
        let incoming = incoming
        for i in 0..<count { incoming[i] = Double(io[i]) }
        if let current {
            Self.withChain(current) { chain in
                chain.process(incoming, frames: frames)
                meter.reduction = max(meter.reduction, chain.gainReductionDb)
            }
        }
        guard fading else {
            for i in 0..<count {
                let y = Float(incoming[i])
                io[i] = y
                meter.write(y)
            }
            return
        }

        let outgoing = outgoing
        for i in 0..<count { outgoing[i] = Double(io[i]) }
        if let leaving {
            Self.withChain(leaving) { chain in
                chain.process(outgoing, frames: frames)
                meter.reduction = max(meter.reduction, chain.gainReductionDb)
            }
        }
        // Equal gain: the weights sum to 1. Silent while the new chain fills its look-ahead, then a 10 ms ramp.
        let prime = state.pointee.prime
        let inverseLength = state.pointee.inverseLength
        var elapsed = state.pointee.elapsed
        var i = 0
        for _ in 0..<frames {
            let g = elapsed < prime ? 0 : min(1, Double(elapsed - prime + 1) * inverseLength)
            for _ in 0..<channels {
                let y = Float((1 - g) * outgoing[i] + g * incoming[i])
                io[i] = y
                meter.write(y)
                i += 1
            }
            elapsed += 1
        }
    }

    /// Moves the fade on by `frames`, and hands the old chain back when it ends.
    private func advance(_ frames: Int) {
        let state = state
        state.pointee.elapsed += frames
        guard state.pointee.elapsed >= state.pointee.prime + state.pointee.length else { return }
        state.pointee.fading = false
        if let old = state.pointee.leaving {
            state.pointee.leaving = nil
            if !handBack(old) { state.pointee.unreturned = old }
        }
    }

    /// `chain` if it was made for `channels` channels; otherwise nil, and the block's dry signal stands in for it.
    private func usable(_ chain: UnsafeMutableRawPointer?, channels: Int) -> UnsafeMutableRawPointer? {
        guard let chain, Self.withChain(chain, { $0.channels }) == channels else { return nil }
        return chain
    }

    /// Reaches a chain from its pointer without reference counting; the retain the main side passed keeps it alive.
    @inline(__always)
    private static func withChain<Result>(_ chain: UnsafeMutableRawPointer, _ body: (SoundChain) -> Result) -> Result {
        Unmanaged<SoundChain>.fromOpaque(chain)._withUnsafeGuaranteedRef(body)
    }
}
