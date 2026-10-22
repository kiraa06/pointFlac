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
    /// The gain the A/B comparison gives the original to match the processed loudness, in dB (``LoudnessMatcher``):
    /// measured while any chain plays, held or not, and kept through Pure. 0 until something has been measured.
    public var matchGainDb: Double

    public init(peakDbFS: Double, clipCount: Int, gainReductionDb: Double, matchGainDb: Double = 0) {
        self.peakDbFS = peakDbFS
        self.clipCount = clipCount
        self.gainReductionDb = gainReductionDb
        self.matchGainDb = matchGainDb
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
/// That sum is then capped so the loudest frequency is driven at most `TruePeakLimiter.maxDriveDb` (+120 dB) into the
/// limiter, the drive its guarantees hold for. Only stacked boosts with automatic headroom off get there (twenty
/// +24 dB bands make +480 dB); far past it, about +280 dB, the limiter's gain can no longer resolve the reduction.
///
/// Pure settings compile to a chain that only delays (its limiter is transparent below the ceiling). Install nil for
/// Pure, which is bit-identical and has no delay.
///
/// ## The A/B comparison
/// A chain also carries what a runner needs to play the original in its place, level-matched (Task 14): the
/// `LoudnessMatcher` tuning for its rate, the 20 ms crossfade at that rate, and a second limiter at the same ceiling.
/// The original, raised to the processed loudness, passes that limiter, so it never goes past the ceiling the
/// processed signal keeps; and comes out `latencyFrames` later, lined up with the chain's output. Below the ceiling
/// that limiter is a delay, bit for bit. It runs only while the comparison is held.
///
/// ## State carried over
/// A chain made for the same rate and channel count as the one it replaces takes over that chain's state when the
/// runner installs it. Each filter keeps the state of the filter at the same place (block, index in that block's band
/// list, shape) with its own coefficients, if their frequencies are within an octave: deleting a parametric band
/// shifts the later bands' indices, and state is not carried between filters that far apart. Crossfeed keeps its
/// state if the preset is unchanged, and the limiter carries on with its look-ahead, hold and release. Dragging one
/// band then changes only that band's sound, and reinstalling the same settings is inaudible.
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
    /// The A/B comparison's level match, tuned for this rate (see "The A/B comparison").
    let matchTuning: LoudnessMatcher.Tuning
    /// The A/B comparison's crossfade, 20 ms at this rate.
    let compareFadeFrames: Int

    private let gain: Double
    /// Filters per channel, in chain order.
    private let sections: Int
    /// `channels × sections` filters, channel-major.
    private let biquads: UnsafeMutablePointer<Biquad>
    /// Each section's `FilterPlace.key` and frequency, for carrying state over.
    private let keys: UnsafeMutablePointer<UInt64>
    private let frequencies: UnsafeMutablePointer<Double>
    /// Stereo with crossfeed on only.
    private let crossfeed: UnsafeMutablePointer<Crossfeed>?
    /// The crossfeed preset's index, or −1: compared on the render thread, so a plain integer.
    private let crossfeedCode: Int
    private let limiter: TruePeakLimiter
    /// `limiter`, unretained, so the render thread reaches it without reference counting. `limiter` keeps it alive.
    private let unretainedLimiter: Unmanaged<TruePeakLimiter>
    /// The A/B comparison's limiter, for the original (see "The A/B comparison"), and its unretained twin.
    private let compareLimiter: TruePeakLimiter
    private let unretainedCompare: Unmanaged<TruePeakLimiter>
    /// Set by the first `install`: a chain runs in one runner only, once.
    let claimed = Atomic<Bool>(false)

    #if DEBUG
        private static let live = Atomic<Int>(0)
        /// Chains alive in the whole process, debug builds only. Any test making chains in parallel moves it, so tests
        /// that check chains are freed hold weak references to their own chains instead.
        static var liveInstances: Int { live.load(ordering: .acquiring) }
    #endif

    /// Compiles `s` for `channels` interleaved channels at `sampleRate`. Allocates: call it off the render thread.
    public init(_ s: SoundSettings, sampleRate: Double, channels: Int) {
        precondition(channels > 0, "SoundChain needs at least one channel")
        precondition(sampleRate.isFinite && sampleRate > 0, "SoundChain needs a sample rate")
        let s = Self.compilable(s)
        settings = s
        self.sampleRate = sampleRate
        self.channels = channels

        // The bands SoundResponse.filters designs, designed the same way, so the graph shows what plays. One list
        // gives each filter and its place, so they can't fall out of step.
        var kept: [(key: UInt64, hz: Double, c: BiquadCoefficients)] = []
        for (place, band) in SoundResponse.placedBands(s) {
            let c = BiquadCoefficients.design(
                band.type, frequency: band.frequency, gainDb: band.gainDb, q: band.q, sampleRate: sampleRate)
            guard [c.b0, c.b1, c.b2, c.a1, c.a2].allSatisfy(\.isFinite) else { continue }
            kept.append((place.key, band.frequency, c))
        }
        sections = kept.count
        biquads = .allocate(capacity: max(1, channels * kept.count))
        keys = .allocate(capacity: max(1, kept.count))
        frequencies = .allocate(capacity: max(1, kept.count))
        for (i, section) in kept.enumerated() {
            keys[i] = section.key
            frequencies[i] = section.hz
            for channel in 0..<channels { (biquads + channel * kept.count + i).initialize(to: Biquad(section.c)) }
        }

        let headroom = SoundResponse.autoHeadroomDb(s, sampleRate: sampleRate)
        let preamp = s.pure ? 0 : Self.preampStaging(s, headroomDb: headroom).totalDb
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
        compareLimiter = TruePeakLimiter(
            channels: channels, sampleRate: sampleRate, ceilingDbTP: s.limiter.ceilingDbTP)
        unretainedCompare = .passUnretained(compareLimiter)
        matchTuning = LoudnessMatcher.Tuning(sampleRate: sampleRate)
        compareFadeFrames = max(1, Int((ChainRunner.compareFadeSeconds * sampleRate).rounded()))
        #if DEBUG
            Self.live.add(1, ordering: .relaxed)
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
        frequencies.deallocate()
        if let crossfeed {
            crossfeed.deinitialize(count: 1)
            crossfeed.deallocate()
        }
        #if DEBUG
            Self.live.subtract(1, ordering: .relaxed)
        #endif
    }

    /// The gain ahead of the filters, part by part, as a chain compiled from `s` applies it (see "Compiling"), given
    /// the automatic headroom the curve needs (`SoundResponse.autoHeadroomDb`). Pure is not part of it: a Pure chain
    /// applies none. For the Sound tab's gain staging, so it shows what plays.
    public static func preampStaging(_ s: SoundSettings, headroomDb: Double) -> PreampStaging {
        let correction = s.correction.enabled ? s.correction.preampDb : 0
        var total = correction + (s.preamp.autoHeadroom ? headroomDb : 0) + s.preamp.trimDb
        // −headroom is how far the curve, correction preamp included, peaks above 0 dB (0 if it doesn't).
        let loudest = -headroomDb + total - correction
        let capped = loudest > TruePeakLimiter.maxDriveDb
        if capped { total -= loudest - TruePeakLimiter.maxDriveDb }
        return PreampStaging(
            correctionDb: s.correction.enabled ? correction : nil,
            headroomDb: s.preamp.autoHeadroom ? headroomDb : nil, trimDb: s.preamp.trimDb, totalDb: total,
            capped: capped)
    }

    /// The stages a chain compiled from `s` puts to work, in chain order, as the signal readouts name them (ruling
    /// R4-UI-c): `activeBlockNames`, with "Preamp" exactly where the preamp stage changes the level
    /// (`PreampStaging.changesLevel`: a trim, the automatic headroom, the correction's own preamp), as the Sound
    /// tab's preamp capsule lights. `headroomDb` is the automatic headroom the curve needs at the rate it plays
    /// (`SoundResponse.autoHeadroomDb`). Empty in Pure.
    public static func stageNames(_ s: SoundSettings, headroomDb: Double) -> [String] {
        var names = s.activeBlockNames
        guard !names.isEmpty else { return [] }
        names.removeAll { $0 == "Preamp" }
        if preampStaging(s, headroomDb: headroomDb).changesLevel {
            names.insert("Preamp", at: names.first == "ReplayGain" ? 1 : 0)
        }
        return names
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

    /// Render thread: the A/B comparison's limiter back to rest, before the runner primes it.
    func resetCompare() {
        unretainedCompare._withUnsafeGuaranteedRef { $0.reset() }
    }

    /// Render thread: limits `frames` interleaved frames of the original in place, for the A/B comparison. They come
    /// out `latencyFrames` later, lined up with the chain's output.
    func limitCompare(_ io: UnsafeMutablePointer<Double>, frames: Int) {
        unretainedCompare._withUnsafeGuaranteedRef { $0.process(io, frames: frames) }
    }

    /// Takes over the state of the chain at `old` where it fits (see "State carried over"), the A/B comparison's
    /// limiter included, and returns whether it did: not across rates or channel counts. Real-time safe: `old` is read
    /// as plain values, so no class reference is captured or retained on the render thread, even in a debug build.
    @discardableResult
    func adoptState(of old: UnsafeMutableRawPointer) -> Bool {
        let theirs = Unmanaged<SoundChain>.fromOpaque(old)._withUnsafeGuaranteedRef { $0.parts }
        guard theirs.biquads != biquads, theirs.channels == channels, theirs.sampleRate == sampleRate else {
            return false
        }
        let channels = channels
        for section in 0..<sections {
            let key = keys[section]
            let hz = frequencies[section]
            var match = -1
            var i = 0
            while i < theirs.sections {
                let ratio = theirs.frequencies[i] > hz ? theirs.frequencies[i] / hz : hz / theirs.frequencies[i]
                if theirs.keys[i] == key, ratio <= 2 {
                    match = i
                    break
                }
                i += 1
            }
            guard match >= 0 else { continue }
            for channel in 0..<channels {
                let mine = biquads + channel * sections + section
                var carried = theirs.biquads[channel * theirs.sections + match]
                carried.c = mine.pointee.c
                mine.pointee = carried
            }
        }
        if let crossfeed, let previous = theirs.crossfeed, crossfeedCode == theirs.crossfeedCode {
            crossfeed.pointee = previous.pointee
        }
        let limiter = theirs.limiter
        unretainedLimiter._withUnsafeGuaranteedRef { $0.adoptState(of: limiter) }
        let compare = theirs.compareLimiter
        unretainedCompare._withUnsafeGuaranteedRef { $0.adoptState(of: compare) }
        return true
    }

    /// What `adoptState(of:)` reads from the chain it replaces.
    private struct Parts {
        var channels: Int
        var sampleRate: Double
        var sections: Int
        var biquads: UnsafeMutablePointer<Biquad>
        var keys: UnsafeMutablePointer<UInt64>
        var frequencies: UnsafeMutablePointer<Double>
        var crossfeed: UnsafeMutablePointer<Crossfeed>?
        var crossfeedCode: Int
        var limiter: Unmanaged<TruePeakLimiter>
        var compareLimiter: Unmanaged<TruePeakLimiter>
    }

    private var parts: Parts {
        Parts(
            channels: channels, sampleRate: sampleRate, sections: sections, biquads: biquads, keys: keys,
            frequencies: frequencies, crossfeed: crossfeed, crossfeedCode: crossfeedCode, limiter: unretainedLimiter,
            compareLimiter: unretainedCompare)
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
///    Either way the chains are freed on the runner's own utility queue, not on the caller's thread or the main actor:
///    `install` only takes them out of the ring, so it never waits.
/// 5. The drain follows `ScrubTap.retireWindow`: it waits, at most 200 ms, until no render call is inside
///    (`rendering`, stored sequentially consistently before a call touches any chain and loaded so by the drain), or
///    the call that was inside has returned (`calls`), so a chain is never freed under the call that handed it back.
///    If one call is still inside after that (a stalled render thread), the chains are stranded: kept, not freed,
///    until the runner itself goes. The wait holds no lock.
/// 6. A free queued on the drain queue holds the runner, so it never outlives it; the timer holds it weakly, so an
///    armed timer never keeps it alive. The runner may therefore go on the drain queue, at the end of a free or a
///    tick, and its `deinit` never waits on that queue: it closes the timer and frees what it still holds, wherever it
///    runs (re-review N-1; codegen decides where a debug build's last release lands, so nothing may depend on it).
///
/// ## Format changes
/// `reset(to:)` replaces everything at once, with no fade and no state carried over, while the output is stopped: a
/// chain compiled for a new rate or channel count starts from rest (Task 7, Review Focus 1).
///
/// ## The A/B comparison
/// While `abBypass` is set (Task 14), the runner plays the original, the block as it came in, in place of the chain's
/// output, brought to the processed signal's loudness by a ``LoudnessMatcher`` and lined up with it:
/// - The original goes into a delay line, so the match measures it as it lines up with the chain's output: the same
///   music in both 400 ms windows. The windows run whenever a chain plays, held or not, so the gain is ready when a
///   finger lands, and keeps following the processed signal while it is held (an install, a drag).
/// - Held, the original, raised by the gain, passes the current chain's comparison limiter (see ``SoundChain``): the
///   same ceiling as the processed signal, and the same latency, so it comes out in line with the chain's output. The
///   limiter is primed with the line's last `latencyFrames` when a hold begins, so the first frame is in line too.
/// - Each switch is a 20 ms crossfade of the two lined-up, level-matched signals, equal-gain as for the chain fade.
///   Released, once the crossfade is over the chain's output is bit for bit what it is without the comparison.
/// - The chain runs throughout, so its filters, look-ahead and release carry on, and a release is as seamless as a
///   press. A chain install while held keeps the original in line: chains at one rate share a latency, and a new
///   chain takes over the comparison limiter's state as it does the rest. A format change (`reset(to:)`) starts the
///   line, the match's windows and the limiter afresh, as the chain itself does, and keeps the gain and the hold.
/// - Only a chain is compared: with none (Pure, or nothing for this channel count) the hold does nothing. A hold
///   still fading out when the chain gives way to Pure finishes on the lined-up original, without the limiter, whose
///   chain has been handed back.
///
/// ## Pure
/// With no chain, no fade and no comparison in flight, `process` returns without touching `io`: the output is
/// bit-identical, whether or not `abBypass` is set.
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
    /// The A/B comparison's crossfade, each way.
    static let compareFadeSeconds = 0.020
    /// The original's delay line, in frames: it delays by up to one less, a chain's latency up to 2.7 MHz.
    static let lineFrames = 4096

    /// While set, the original plays in place of the chain's output, level-matched and lined up (see "The A/B
    /// comparison"). Any thread; the render thread reads it at each block.
    public let abBypass = Atomic<Bool>(false)

    /// Main side → render thread: a retained chain, the Pure sentinel, or nil when nothing is waiting.
    private let mailbox = Atomic<UnsafeMutableRawPointer?>(nil)
    /// Set while a render call may touch a chain (see "Install protocol" step 5).
    private let rendering = Atomic<Bool>(false)
    /// Render calls that have touched chains, counted as each returns: a drain waits for the one inside to return.
    private let calls = Atomic<UInt64>(0)

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
    /// The A/B comparison's level match, and its unretained twin for the render thread.
    private let matcher: LoudnessMatcher
    private let unretainedMatcher: Unmanaged<LoudnessMatcher>
    /// The original's recent frames: a ring of `lineFrames` frames of `maxChannels` samples, plain values.
    private let line: UnsafeMutablePointer<Double>
    private let lineMask = ChainRunner.lineFrames - 1
    /// Float64 scratch, `maxFrames × maxChannels` each: the original as it is now (raised and limited, it is what the
    /// comparison plays), and as it lines up with the chain's output (what the match measures).
    private let original: UnsafeMutablePointer<Double>
    private let lined: UnsafeMutablePointer<Double>

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
        /// The A/B comparison: the original's share of the output (0 the processed signal, 1 the original), and its
        /// step per frame, a 20 ms crossfade at the current chain's rate.
        var abWeight = 0.0
        var abStep = 1.0
        /// The current chain's comparison limiter has been primed and is being fed.
        var abPrimed = false
        /// Frames the original is delayed by to line up with the chain's output: the current chain's latency.
        var delay = 0
        /// The next frame written into the original's line.
        var lineWrite = 0
    }

    /// Main side, under `control`.
    private struct Control {
        /// Set by `deinit`: no timer is armed again.
        var closed = false
        /// Chains whose reference the render side holds: in the mailbox, playing, fading or in the ring.
        var outstanding = 0
        /// The latest install was a chain, which the render thread keeps playing.
        var keepsOne = false
        var timer: DispatchSourceTimer?
        /// Timer ticks in a row that found nothing to drain: the render thread has stopped, mid-fade.
        var idleTicks = 0
        /// Chains a stalled render call might still have been inside when they came back: kept until the runner goes.
        var stranded: [SoundChain] = []
        #if DEBUG
            /// Runs in every timer tick, on the drain queue, under the lock. For tests that hold a tick in flight.
            var onTick: (@Sendable () -> Void)?
        #endif
    }

    /// Stands for Pure in the mailbox. Computed, not stored, so the render thread never runs a lazy initialiser.
    private static var pure: UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: 1)! }

    /// Where retired chains are freed and the timer runs (see "Install protocol" steps 4–6).
    private let drainQueue = DispatchQueue(label: "pointFlac.sound.retire", qos: .utility)

    /// Retired chains on their way to the drain queue.
    private struct Retired: @unchecked Sendable {
        var chains: [UnsafeMutableRawPointer] = []
    }

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
        matcher = LoudnessMatcher(sampleRate: 48_000, maxFrames: maxFrames, maxChannels: maxChannels)
        unretainedMatcher = .passUnretained(matcher)
        line = .allocate(capacity: Self.lineFrames * maxChannels)
        line.initialize(repeating: 0, count: Self.lineFrames * maxChannels)
        original = .allocate(capacity: maxFrames * maxChannels)
        original.initialize(repeating: 0, count: maxFrames * maxChannels)
        lined = .allocate(capacity: maxFrames * maxChannels)
        lined.initialize(repeating: 0, count: maxFrames * maxChannels)
    }

    /// Frees every chain the runner still holds. No render call may be running: the owner stops the output first.
    /// It may run on the drain queue (see "Install protocol" step 6), so it never waits on it: no free is queued (each
    /// holds the runner), and a tick in flight is the one letting it go.
    deinit {
        control.withLock { control in
            control.closed = true
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
        line.deallocate()
        original.deallocate()
        lined.deallocate()
    }

    // MARK: Main side

    /// Plays `chain` from the render thread's next block, cross-faded in over 10 ms; nil is Pure. Any thread but the
    /// render thread. A chain already installed (here or in another runner) is recompiled, so no two runs ever share
    /// filter state; the copy picks up the playing chain's state, so this is seamless.
    public func install(_ chain: SoundChain?) {
        let chain = chain.map(Self.claim)
        let pointer = chain.map { Unmanaged.passRetained($0).toOpaque() } ?? Self.pure
        let retired = control.withLock { control -> Retired in
            let displaced = mailbox.exchange(pointer, ordering: .acquiringAndReleasing)
            if chain != nil { control.outstanding += 1 }
            control.keepsOne = chain != nil
            if let displaced, displaced != Self.pure {
                // The render thread never took it.
                Unmanaged<SoundChain>.fromOpaque(displaced).release()
                control.outstanding -= 1
            }
            let retired = collect(&control)
            control.idleTicks = 0
            updateTimer(&control)
            return retired
        }
        guard !retired.chains.isEmpty else { return }
        // The block holds the runner until the free is done (see "Install protocol" step 6).
        drainQueue.async { [self] in freeWhenIdle(retired) }
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
    /// Serialised with `install`. The chains it lets go are freed on the runner's queue, like every retired chain
    /// (`waitForFrees()` waits for them); no render call can be inside, so the handshake passes at once.
    public func reset(to chain: SoundChain?) {
        assert(!rendering.load(ordering: .sequentiallyConsistent), "reset(to:) while a render call is in flight")
        let chain = chain.map(Self.claim)
        let retired = control.withLock { control -> Retired in
            // The ring's chains first (this takes them off `outstanding`), then whatever the render state still holds.
            var retired = collect(&control)
            var held: [UnsafeMutableRawPointer] = []
            if let waiting = mailbox.exchange(nil, ordering: .acquiringAndReleasing), waiting != Self.pure {
                held.append(waiting)
            }
            held += [state.pointee.current, state.pointee.leaving, state.pointee.unreturned].compactMap { $0 }
            let weight = state.pointee.abWeight
            state.pointee = RenderState()
            state.pointee.current = chain.map { Unmanaged.passRetained($0).toOpaque() }
            restartComparison(for: chain, weight: weight)
            reductionBits.store(0, ordering: .relaxed)
            retired.chains += held
            control.outstanding += (chain == nil ? 0 : 1) - held.count
            control.keepsOne = chain != nil
            control.idleTicks = 0
            updateTimer(&control)
            return retired
        }
        guard !retired.chains.isEmpty else { return }
        // The block holds the runner until the free is done (see "Install protocol" step 6).
        drainQueue.async { [self] in freeWhenIdle(retired) }
    }

    /// `reset(to:)`'s part for the A/B comparison, with the render state just reset: the line silent, the match tuned
    /// for `chain`'s rate with empty windows, its gain kept. A hold carries on (`weight`) with a chain, and ends with
    /// none.
    private func restartComparison(for chain: SoundChain?, weight: Double) {
        var i = 0
        while i < Self.lineFrames * maxChannels {
            line[i] = 0
            i += 1
        }
        guard let chain else {
            matcher.restart()
            return
        }
        state.pointee.abWeight = weight
        state.pointee.abStep = 1 / Double(chain.compareFadeFrames)
        state.pointee.delay = chain.latencyFrames
        matcher.retune(chain.matchTuning)
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
            gainReductionDb: Double(bitPattern: reductionBits.load(ordering: .relaxed)), matchGainDb: matcher.gainDb)
    }

    /// Frees every chain handed back so far (or strands it), and returns once that is done. For tests.
    func waitForFrees() {
        let retired = control.withLock { collect(&$0) }
        drainQueue.sync { freeWhenIdle(retired) }
    }

    /// Chains stranded so far (see "Install protocol" step 5). For tests.
    var strandedCount: Int { control.withLock { $0.stranded.count } }

    #if DEBUG
        /// Runs `hook` in every timer tick, on the drain queue, under the runner's lock. For tests.
        func setTickHook(_ hook: @escaping @Sendable () -> Void) {
            control.withLock { $0.onTick = hook }
        }
    #endif

    /// Drain queue: one timer tick.
    private func tick() {
        let retired = control.withLock { control -> Retired in
            #if DEBUG
                control.onTick?()
            #endif
            guard !control.closed else { return Retired() }
            let retired = collect(&control)
            control.idleTicks = retired.chains.isEmpty ? control.idleTicks + 1 : 0
            updateTimer(&control)
            return retired
        }
        freeWhenIdle(retired)
    }

    /// Takes the chains the render thread has handed back out of the ring. Under `control`.
    private func collect(_ control: inout Control) -> Retired {
        let written = retireWritten.load(ordering: .acquiring)
        var read = retireRead.load(ordering: .relaxed)
        var retired = Retired()
        while read != written {
            if let chain = retireSlots[read & retireMask] { retired.chains.append(chain) }
            read += 1
        }
        retireRead.store(read, ordering: .releasing)
        control.outstanding -= retired.chains.count
        return retired
    }

    /// Drain queue: frees `retired` once no render call can still be inside the call that handed them back
    /// (`ScrubTap.retireWindow`'s handshake), or strands them if one call is still inside after 200 ms. Holds no lock
    /// while it waits.
    ///
    /// The wait also ends when the call that was inside has returned (`calls` moved on), so a busy render thread,
    /// whose next call may already be inside, never holds a free up, and a drain thread that was itself held up
    /// past the deadline never strands chains a call that long since returned had handed back.
    private func freeWhenIdle(_ retired: Retired) {
        guard !retired.chains.isEmpty else { return }
        // A render call that handed one back set `rendering` first, sequentially consistent with these loads (which
        // come after the pointers were taken out of the ring), so once it reads false, or `calls` has moved on from
        // the call that was inside, no call can still be inside the one that handed them back.
        let inside = calls.load(ordering: .sequentiallyConsistent)
        func stillInside() -> Bool {
            rendering.load(ordering: .sequentiallyConsistent) && calls.load(ordering: .sequentiallyConsistent) == inside
        }
        let deadline = ContinuousClock.now + .milliseconds(200)
        while stillInside(), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.0005)
        }
        if stillInside() {
            // A render call still inside after 200 ms (a stalled render thread): never free them under it.
            let chains = retired.chains.map { Unmanaged<SoundChain>.fromOpaque($0).takeRetainedValue() }
            control.withLock { $0.stranded += chains }
            return
        }
        for chain in retired.chains { Unmanaged<SoundChain>.fromOpaque(chain).release() }
    }

    /// Runs the 100 ms drain timer while chains are expected back, and stops it once none are, or after a second with
    /// none coming back (the output stopped mid-fade: the next `install` drains them instead). Under `control`.
    private func updateTimer(_ control: inout Control) {
        let expected = !control.closed && control.outstanding > (control.keepsOne ? 1 : 0) && control.idleTicks < 10
        if expected, control.timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: drainQueue)
            timer.schedule(
                deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
            // Weakly: an armed timer never keeps the runner alive. A tick in flight holds it until it returns.
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            control.timer = timer
        } else if !expected, let timer = control.timer {
            timer.cancel()
            control.timer = nil
        }
    }

    // MARK: Render thread

    /// Whether `process` would return at once, leaving the block untouched: Pure, with no fade in flight, no A/B
    /// comparison fading out, nothing waiting to be handed back and nothing in the mailbox (a relaxed load). Render
    /// thread only, as it reads the render state (so `package`, not public). A caller that has to convert samples for
    /// `process` (an Int32 client) skips the conversion then. One guard of loads in turn, not `&&`: `&&`'s right-hand side is an autoclosure,
    /// which a debug build makes capture, and so retain, the runner.
    @inline(__always)
    package var isIdle: Bool {
        let state = state
        guard state.pointee.current == nil, !state.pointee.fading, state.pointee.unreturned == nil,
            state.pointee.abWeight == 0
        else { return false }
        return mailbox.load(ordering: .relaxed) == nil
    }

    /// Runs `frames` interleaved Float32 frames of `channels` channels through the installed chain, in place. Render
    /// thread only, one call at a time; real-time safe.
    public func process(_ io: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        let state = state
        if state.pointee.current == nil, !state.pointee.fading, state.pointee.unreturned == nil,
            state.pointee.abWeight == 0, mailbox.load(ordering: .relaxed) == nil
        {
            return
        }
        // Announce the call before touching any chain (sequentially consistent with the drain's loads).
        rendering.store(true, ordering: .sequentiallyConsistent)
        defer {
            calls.wrappingAdd(1, ordering: .releasing)
            rendering.store(false, ordering: .releasing)
        }

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
            // The comparison limiter goes with the chain: a hold still fading out finishes on the lined-up original.
            state.pointee.abPrimed = false
            begin(leaving: old, prime: 0, length: Self.withChain(old) { $0.fadeFrames })
            return
        }
        if let old {
            // Only the raw `old` is captured: a closure capturing a chain would retain it in a debug build.
            let adopted = Self.withChain(next) { $0.adoptState(of: old) }
            // A comparison limiter that took nothing over starts again from the line.
            if !adopted { state.pointee.abPrimed = false }
        } else {
            // From Pure: the line holds whatever played before, and the match's windows with it.
            clearLine(Self.withChain(next) { $0.latencyFrames })
            unretainedMatcher._withUnsafeGuaranteedRef { $0.restart() }
            state.pointee.abPrimed = false
        }
        let rate = Self.withChain(next) { $0.sampleRate }
        if unretainedMatcher._withUnsafeGuaranteedRef({ $0.tuning.sampleRate }) != rate { retuneMatcher(next) }
        state.pointee.current = next
        // Two calls rather than one returning a tuple, whose metadata a debug build would instantiate here.
        let latency = Self.withChain(next) { $0.latencyFrames }
        let length = Self.withChain(next) { $0.fadeFrames }
        state.pointee.delay = latency
        state.pointee.abStep = 1 / Double(Self.withChain(next) { $0.compareFadeFrames })
        begin(leaving: old, prime: latency, length: length)
    }

    /// Silences the `frames` frames of the line before the next one written, the most the original is delayed by.
    private func clearLine(_ frames: Int) {
        let line = line
        let mask = lineMask
        let stride = maxChannels
        var frame = state.pointee.lineWrite &- min(frames, mask)
        while frame != state.pointee.lineWrite {
            let slot = (frame & mask) * stride
            var c = 0
            while c < stride {
                line[slot + c] = 0
                c += 1
            }
            frame &+= 1
        }
    }

    /// Tunes the match for `chain`'s rate, from its precomputed tuning, and starts its windows afresh.
    private func retuneMatcher(_ chain: UnsafeMutableRawPointer) {
        let tuning = Unmanaged<SoundChain>.fromOpaque(chain)._withUnsafeGuaranteedRef { $0.matchTuning }
        unretainedMatcher._withUnsafeGuaranteedRef { $0.retune(tuning) }
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

    /// One piece of a block, at most `maxFrames` and never past the end of a fade: the original into its line, the
    /// chains (and any fade between them), then the A/B comparison, and the meter over what leaves.
    private func render(_ io: UnsafeMutablePointer<Float>, frames: Int, channels: Int, _ meter: inout Meter) {
        let state = state
        let fading = state.pointee.fading
        let fits = channels <= maxChannels
        let current = fits ? usable(state.pointee.current, channels: channels) : nil
        let leaving = fits && fading ? usable(state.pointee.leaving, channels: channels) : nil
        defer { if fading { advance(frames) } }
        // Conditions in turn, not `&&` or `||`, whose right-hand sides are autoclosures: one reading the runner would
        // capture, and so retain, it in a debug build.
        let chains = current != nil || leaving != nil
        var fadingOut = false
        if fits, state.pointee.abWeight > 0 { fadingOut = true }
        // Nothing to run: Pure with no comparison fading out, or no chain for this channel count. The block stays
        // untouched.
        guard chains || fadingOut else { return }

        // Held: the original, while a chain plays whose latency the line can delay by.
        var comparing = false
        if current != nil, abBypass.load(ordering: .relaxed), state.pointee.delay <= lineMask { comparing = true }
        if comparing, !state.pointee.abPrimed, let current { primeComparison(current, channels: channels) }
        takeOriginal(io, frames: frames, channels: channels)
        if chains { runChains(io, frames: frames, channels: channels, current: current, leaving: leaving, &meter) }
        compare(io, frames: frames, channels: channels, current: current, comparing: comparing)
        let count = frames * channels
        var i = 0
        while i < count {
            meter.write(io[i])
            i += 1
        }
    }

    /// The chains over one piece, in place: the current one, and while fading the one leaving, under the fade.
    private func runChains(
        _ io: UnsafeMutablePointer<Float>, frames: Int, channels: Int, current: UnsafeMutableRawPointer?,
        leaving: UnsafeMutableRawPointer?, _ meter: inout Meter
    ) {
        let state = state
        let count = frames * channels
        let incoming = incoming
        var i = 0
        while i < count {
            incoming[i] = Double(io[i])
            i += 1
        }
        if let current {
            Self.withChain(current) { chain in
                chain.process(incoming, frames: frames)
                meter.reduction = max(meter.reduction, chain.gainReductionDb)
            }
        }
        guard state.pointee.fading else {
            i = 0
            while i < count {
                io[i] = Float(incoming[i])
                i += 1
            }
            return
        }

        let outgoing = outgoing
        i = 0
        while i < count {
            outgoing[i] = Double(io[i])
            i += 1
        }
        if let leaving {
            Self.withChain(leaving) { chain in
                chain.process(outgoing, frames: frames)
                meter.reduction = max(meter.reduction, chain.gainReductionDb)
            }
        }
        // Equal gain: the weights sum to 1. Silent while the new chain fills its look-ahead, then a 10 ms ramp. At
        // the end weights one side is taken whole, so a dry side heard alone stays bit for bit (−0 and NaN payloads
        // too), and a non-finite dry sample never leaks into a chain heard alone (0 × NaN is NaN).
        let prime = state.pointee.prime
        let inverseLength = state.pointee.inverseLength
        let outgoingDry = leaving == nil
        let incomingDry = current == nil
        var elapsed = state.pointee.elapsed
        i = 0
        var frame = 0
        while frame < frames {
            let g = elapsed < prime ? 0 : min(1, Double(elapsed - prime + 1) * inverseLength)
            if (g == 0 && outgoingDry) || (g == 1 && incomingDry) {
                i += channels
            } else {
                var c = 0
                while c < channels {
                    let mixed = (1 - g) * outgoing[i] + g * incoming[i]
                    io[i] = Float(g == 0 ? outgoing[i] : g == 1 ? incoming[i] : mixed)
                    i += 1
                    c += 1
                }
            }
            elapsed += 1
            frame += 1
        }
    }

    /// The original over one piece, before the chains touch it: into the line, into `original` as it is, and into
    /// `lined` as it lines up with the chain's output, `delay` frames ago. Non-finite samples are silence.
    private func takeOriginal(_ io: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let state = state
        let line = line
        let original = original
        let lined = lined
        let mask = lineMask
        let stride = maxChannels
        let delay = min(state.pointee.delay, mask)
        var write = state.pointee.lineWrite
        var i = 0
        var frame = 0
        while frame < frames {
            let slot = (write & mask) * stride
            let read = ((write &- delay) & mask) * stride
            var c = 0
            while c < channels {
                let x = Double(io[i])
                let clean = x.isFinite ? x : 0
                line[slot + c] = clean
                original[i] = clean
                lined[i] = line[read + c]
                i += 1
                c += 1
            }
            write &+= 1
            frame += 1
        }
        state.pointee.lineWrite = write
    }

    /// Starts `chain`'s comparison limiter from rest and feeds it the line's last `delay` frames, raised by the match's
    /// gain, so its output lines up with the chain's from the hold's first frame. Uses `original` as scratch, before
    /// this piece fills it.
    private func primeComparison(_ chain: UnsafeMutableRawPointer, channels: Int) {
        let state = state
        Self.withChain(chain) { $0.resetCompare() }
        let gain = unretainedMatcher._withUnsafeGuaranteedRef { $0.gain }
        let line = line
        let scratch = original
        let mask = lineMask
        let stride = maxChannels
        let delay = min(state.pointee.delay, mask)
        var frame = state.pointee.lineWrite &- delay
        var left = delay
        while left > 0 {
            let n = min(left, maxFrames)
            var i = 0
            var f = 0
            while f < n {
                let slot = (frame & mask) * stride
                var c = 0
                while c < channels {
                    scratch[i] = line[slot + c] * gain
                    i += 1
                    c += 1
                }
                frame &+= 1
                f += 1
            }
            Self.withChain(chain) { $0.limitCompare(scratch, frames: n) }
            left -= n
        }
        state.pointee.abPrimed = true
    }

    /// The A/B comparison over one piece whose processed output is in `io`: the match measures the lined-up original
    /// against it; then, while held or still fading either way, the original is mixed in, a 20 ms crossfade each way.
    /// Released and faded out, `io` stays as the chains left it.
    private func compare(
        _ io: UnsafeMutablePointer<Float>, frames: Int, channels: Int, current: UnsafeMutableRawPointer?,
        comparing: Bool
    ) {
        let state = state
        let original = original
        let lined = lined
        var weight = state.pointee.abWeight
        guard comparing || weight > 0 else {
            unretainedMatcher._withUnsafeGuaranteedRef {
                $0.process(dry: lined, wet: io, scale: nil, frames: frames, channels: channels)
            }
            state.pointee.abPrimed = false
            return
        }
        // What the comparison plays: the original raised to match, through the chain's comparison limiter, which
        // delays it into line. With no primed limiter (the chain gave way to Pure while a release was still fading),
        // the lined-up original raised to match.
        let source: UnsafeMutablePointer<Double>
        if let current, state.pointee.abPrimed {
            unretainedMatcher._withUnsafeGuaranteedRef {
                $0.process(dry: lined, wet: io, scale: original, frames: frames, channels: channels)
            }
            Self.withChain(current) { $0.limitCompare(original, frames: frames) }
            source = original
        } else {
            unretainedMatcher._withUnsafeGuaranteedRef {
                $0.process(dry: lined, wet: io, scale: lined, frames: frames, channels: channels)
            }
            state.pointee.abPrimed = false
            source = lined
        }
        let goal = comparing ? 1.0 : 0.0
        let step = state.pointee.abStep
        var i = 0
        var frame = 0
        while frame < frames {
            if weight < goal {
                weight = min(goal, weight + step)
            } else if weight > goal {
                weight = max(goal, weight - step)
            }
            if weight == 0 {
                i += channels
            } else if weight == 1 {
                var c = 0
                while c < channels {
                    io[i] = Float(source[i])
                    i += 1
                    c += 1
                }
            } else {
                var c = 0
                while c < channels {
                    io[i] = Float((1 - weight) * Double(io[i]) + weight * source[i])
                    i += 1
                    c += 1
                }
            }
            frame += 1
        }
        state.pointee.abWeight = weight
        if weight == 0, !comparing { state.pointee.abPrimed = false }
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

/// The gain ahead of a chain's filters, part by part (`SoundChain.preampStaging`).
public struct PreampStaging: Equatable, Sendable {
    /// The correction's own preamp; nil while correction is off.
    public var correctionDb: Double?
    /// The automatic headroom; nil while it is switched off.
    public var headroomDb: Double?
    public var trimDb: Double
    /// The sum, capped so the loudest frequency drives the limiter at most `TruePeakLimiter.maxDriveDb`.
    public var totalDb: Double
    /// The cap lowered the sum: only stacked boosts with automatic headroom off reach it.
    public var capped: Bool

    /// Whether the stage changes the level: the total is a twentieth of a dB or more from 0 dB.
    public var changesLevel: Bool { abs(totalDb) >= 0.05 }
}
