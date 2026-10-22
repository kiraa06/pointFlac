import Foundation
import Synchronization

/// The last block of the Sound chain (spec §4.8 block 7): a look-ahead limiter that keeps the output's true peak (the
/// peak of the band-limited signal between samples, as ITU-R BS.1770-4 Annex 2 defines dBTP) under a ceiling. EQ
/// boosts and preamp trim can then not push the DAC's reconstruction past full scale between samples, where a
/// sample-peak limiter would let it through.
///
/// It is in the chain whenever any block is on (plan ruling R4-6), so it must cost nothing audible while it is not
/// needed: the audio path is only a delay line and a gain, and the gain is exactly 1 until a true peak would cross the
/// ceiling. Below the ceiling the output is the input, bit for bit, `latencyFrames` later. The oversampling is for
/// detection only; the audio itself is never resampled or filtered.
///
/// ## What it guarantees
/// Content up to 0.45 × the rate, steady or broadband, holds the ceiling within these measured bounds:
/// - **44.1 and 48 kHz (16×): +0.03 dB.**
/// - **Higher rates (8×): +0.1 dB.** Up to 20 kHz the bound is the grid's 0.035 dB, and a 20 kHz tone measures under
///   the ceiling. The rest is ultrasonic content, read on the coarser grid.
///
/// These hold for input at most `maxDriveDb` (+120 dB) over full scale. Far past that, about +280 dB, the gain
/// (a Double) can no longer resolve the reduction it needs, and the output overshoots: +47.7 dB out for input at 1e18
/// (+360 dB). `SoundChain` caps its drive to this bound.
///
/// **Energy above 0.45 × the rate is not guaranteed.** It is under-read, as with any finite true-peak detector,
/// BS.1770 meters included: near fs/2 a finite interpolator cannot reconstruct the signal (the half-sample phase has a
/// zero at fs/2). For example, twenty +24 dB peaks reaching 21.65 kHz at 44.1 kHz come out +0.30 dB over, and white
/// noise reaching fs/2 driven 12 dB in comes out +1.0 dB over. Music at 44.1 and 48 kHz carries little there (an
/// anti-alias filter stops it). The EQ's bands stop at 20 kHz, which is 0.454 × 44.1 kHz, and a tone there still
/// measures +0.003 dB.
///
/// Measured details, as the applied gain times a steady tone's amplitude over 128 crest positions, and for noise on an
/// FFT-exact reconstruction (five 65 536-frame runs per rate, driven 13 dB in):
/// - 16×: tones within +0.03 dB up to 0.45 × the rate (the worst, +0.029 dB, at 8/19 of it); noise band-limited to 0.45 × within +0.002 dB.
/// - 8×: tones up to 20 kHz under the ceiling; ultrasonic tones +0.044 dB at fs/4, +0.059 dB at fs/3, +0.087 dB at
///   0.4 fs, +0.1 dB at 4/9 fs; noise band-limited to 0.45 × within +0.065 dB.
///
/// ## Detector
/// Each frame, every channel is read at the sample and at `oversampling − 1` evenly spaced points before the next
/// one: 16× up to 48 kHz and 8× above, so the grid is at least 705.6 kHz (rulings R4-T4b, R4-T4e). A BS.1770-style 4×
/// grid let steady tones through 0.17 dB over at fs/4 and 0.44 dB at 0.4 fs: a crest between two points is under-read
/// by up to cos(π f / grid). The points sit on the sample grid, so a sample peak is read exactly and no output sample
/// can pass the ceiling.
///
/// Each interpolating phase is a 32-tap Kaiser-windowed sinc (16 frames either side, β 5, normalised to unity at DC).
/// The low β trades passband ripple (+0.04 / −0.03 dB up to 0.45 × the rate; the response falls away above it, −1.6 dB
/// at 0.47 ×) for a passband that reaches that far. Reading high only makes the limiter act a little early: up to
/// 0.025 dB below the ceiling on tones to 0.4 × the rate, 0.04 dB at 0.44 ×, and 0.065 dB on full-band noise. The frame's peak is the largest across channels.
///
/// ## Gain envelope
/// Channels share one gain, so a limited channel never shifts the stereo image. Per frame:
/// 1. The gain the frame needs is `ceiling / peak` (1 when under the ceiling), over the intervals either side of the
///    frame, since the sample's gain shapes both.
/// 2. Hold: the smallest needed gain over the look-ahead window, by a monotonic deque (amortised O(1) per frame,
///    never more than the window per frame), so a reduction is in place before its over arrives.
/// 3. Release: an exponential rise back toward the hold, with time constant `releaseSeconds`. A fall follows the hold
///    at once (no attack time constant, so nothing leaks through), and a rise within 1e-9 of its target lands on it, so
///    a release ends at exactly 1 and the output is bit-exact again.
/// 4. Ramp: the mean of that over the look-ahead window, by a running sum (O(1)). This turns the hold's step into a
///    straight line across the look-ahead, so an attack never clicks. Each value averaged is a minimum over a window
///    that contains the frame being output, so the mean is never above what that frame needs: the reduction is
///    complete when the over arrives.
///
/// ## Real-time safety
/// Every buffer is allocated in `init` and freed in `deinit`. `process` touches only those raw pointers, stored
/// scalars and one atomic: no allocation, locks, logging or reference counting. Call `process` from one thread at a
/// time (the render thread); `gainReductionDb` may be read from any thread.
public final class TruePeakLimiter: @unchecked Sendable {
    public let channels: Int
    /// Frames from input to output: the look-ahead, plus 15 more for the detector to read past the frame it judges.
    public let latencyFrames: Int

    /// Taps per interpolating phase: 16 frames either side of the point. A multiple of 4, for `process`'s unrolling.
    static let tapsPerPhase = 32
    static let beta = 5.0
    /// Within this of its target, a releasing gain takes the target exactly. Computed, not stored: `process` reads it,
    /// and a stored static's lazy initialiser would first run on the render thread.
    static var snap: Double { 1e-9 }

    /// The most drive, in dB over full scale, the guarantees hold for (see "What it guarantees"). Computed, not
    /// stored, like `snap`.
    static var maxDriveDb: Double { 120 }

    /// Detection points per sample interval, the sample itself included: see `oversampling(atRate:)`.
    let oversampling: Int
    /// The ceiling as a linear amplitude.
    private let ceiling: Double
    /// The look-ahead window, in frames: both the hold's and the ramp's length.
    private let lookahead: Int
    private let inverseLookahead: Double
    /// The release's step toward its target, per frame.
    private let releaseCoefficient: Double

    /// Each channel's recent input in a ring of `historyFrames` (a power of two), written twice, at `i` and
    /// `i + historyFrames`, so each detector phase's taps are always contiguous. Channel `c` starts at
    /// `c * 2 * historyFrames`.
    private let history: UnsafeMutablePointer<Double>
    private let historyFrames: Int
    /// The interpolating phases' taps, `tapsPerPhase` each, for offsets 1/`oversampling` … (`oversampling` − 1)/
    /// `oversampling`.
    private let taps: UnsafeMutablePointer<Double>
    /// The hold's deque of (needed gain, frame), a ring of `holdMask + 1` entries.
    private let holdGains: UnsafeMutablePointer<Double>
    private let holdFrames: UnsafeMutablePointer<Int>
    private let holdMask: Int
    /// The ramp's window: `1 − gain` for the last `lookahead` frames.
    private let deficits: UnsafeMutablePointer<Double>

    // Render-thread state, touched by one thread at a time. Unchecked: a debug build's dynamic exclusivity checks
    // (`swift_beginAccess`) would allocate the render thread's TLS context on its first call (re-review N-2). Release
    // builds check nothing either way.
    @exclusivity(unchecked) private var frame = 0
    @exclusivity(unchecked) private var holdHead = 0
    @exclusivity(unchecked) private var holdTail = 0
    @exclusivity(unchecked) private var previousPeak = 0.0
    @exclusivity(unchecked) private var envelope = 1.0
    @exclusivity(unchecked) private var deficitSum = 0.0
    /// Nonzero entries in `deficits`: at zero the ramp is exactly 1, whatever rounding the running sum carries.
    @exclusivity(unchecked) private var deficitCount = 0
    @exclusivity(unchecked) private var deficitSlot = 0

    /// `gainReductionDb`'s bit pattern, for a meter on another thread.
    private let reduction = Atomic<UInt64>(0)

    /// - Parameters:
    ///   - channels: interleaved channels, one or more, sharing one gain.
    ///   - ceilingDbTP: the true-peak ceiling, −60…0 dBTP.
    ///   - lookaheadSeconds: how far ahead overs are seen, which is also how long an attack takes (at least a frame).
    ///   - releaseSeconds: the release's time constant.
    public init(
        channels: Int, sampleRate: Double, ceilingDbTP: Double, lookaheadSeconds: Double = 0.0015,
        releaseSeconds: Double = 0.1
    ) {
        precondition(channels > 0, "TruePeakLimiter needs at least one channel")
        precondition(sampleRate.isFinite && sampleRate > 0, "TruePeakLimiter needs a sample rate")
        self.channels = channels
        let ceilingDb = ceilingDbTP.isNaN ? LimiterSettings().ceilingDbTP : min(max(ceilingDbTP, -60), 0)
        ceiling = pow(10, ceilingDb / 20)
        let seconds = lookaheadSeconds.isFinite ? min(max(lookaheadSeconds, 0), 0.1) : 0.0015
        lookahead = max(1, Int((seconds * sampleRate).rounded()))
        inverseLookahead = 1 / Double(lookahead)
        let release = releaseSeconds.isFinite && releaseSeconds > 0 ? min(releaseSeconds, 10) : 0.1
        // expm1 keeps the step exact for long releases at high rates, where 1 − exp(−x) loses its digits.
        releaseCoefficient = -expm1(-1 / (release * sampleRate))
        // The interval after frame m needs frame m + 16; the hold and the ramp then reach lookahead − 1 frames on.
        latencyFrames = lookahead + Self.tapsPerPhase / 2 - 1
        oversampling = Self.oversampling(atRate: sampleRate)

        historyFrames = Self.powerOfTwo(atLeast: latencyFrames + Self.tapsPerPhase)
        history = .allocate(capacity: channels * 2 * historyFrames)
        history.initialize(repeating: 0, count: channels * 2 * historyFrames)

        taps = .allocate(capacity: (oversampling - 1) * Self.tapsPerPhase)
        let i0Beta = ScrubKernel.besselI0(Self.beta)
        let half = Double(Self.tapsPerPhase / 2)
        for phase in 1..<oversampling {
            let t = Double(phase) / Double(oversampling)
            let row = taps + (phase - 1) * Self.tapsPerPhase
            var sum = 0.0
            for i in 0..<Self.tapsPerPhase {
                // Tap i reads frame m − 15 + i for the point m + t.
                let u = Double(i - (Self.tapsPerPhase / 2 - 1)) - t
                let sinc = sin(.pi * u) / (.pi * u)
                let r = u / half
                row[i] = sinc * ScrubKernel.besselI0(Self.beta * (1 - r * r).squareRoot()) / i0Beta
                sum += row[i]
            }
            for i in 0..<Self.tapsPerPhase { row[i] /= sum }
        }

        let holdCapacity = Self.powerOfTwo(atLeast: lookahead + 1)
        holdMask = holdCapacity - 1
        holdGains = .allocate(capacity: holdCapacity)
        holdGains.initialize(repeating: 1, count: holdCapacity)
        holdFrames = .allocate(capacity: holdCapacity)
        holdFrames.initialize(repeating: 0, count: holdCapacity)
        deficits = .allocate(capacity: lookahead)
        deficits.initialize(repeating: 0, count: lookahead)
    }

    deinit {
        history.deallocate()
        taps.deallocate()
        holdGains.deallocate()
        holdFrames.deallocate()
        deficits.deallocate()
    }

    /// The deepest reduction the latest `process` call applied, in dB: 0 while transparent, positive while limiting
    /// (capped at 120). Safe to read from any thread.
    public var gainReductionDb: Double {
        Double(bitPattern: reduction.load(ordering: .relaxed))
    }

    /// Limits `frames` interleaved frames in place; the output is the input `latencyFrames` earlier, times the gain.
    /// Non-finite input samples are taken as silence, so a fault upstream never reaches the DAC. Real-time safe.
    public func process(_ io: UnsafeMutablePointer<Double>, frames: Int) {
        guard frames > 0 else { return }
        let channels = channels
        let history = history
        let historyFrames = historyFrames
        let mask = historyFrames - 1
        let stride = 2 * historyFrames
        let taps = taps
        let tapsPerPhase = Self.tapsPerPhase
        let interpolating = oversampling - 1
        let snap = Self.snap
        let reach = tapsPerPhase - 1
        let centre = tapsPerPhase / 2 - 1
        let ceiling = ceiling
        let lookahead = lookahead
        let inverseLookahead = inverseLookahead
        let releaseCoefficient = releaseCoefficient
        let latency = latencyFrames
        let holdGains = holdGains
        let holdFrames = holdFrames
        let holdMask = holdMask
        let deficits = deficits
        var frame = frame
        var head = holdHead
        var tail = holdTail
        var previousPeak = previousPeak
        var envelope = envelope
        var deficitSum = deficitSum
        var deficitCount = deficitCount
        var deficitSlot = deficitSlot
        var smallestGain = 1.0

        for offset in 0..<frames {
            let samples = io + offset * channels
            let write = frame & mask
            // Frame m = frame − 16 and the interval after it: frames m − 15 ... m + 16.
            let window = (frame - reach) & mask
            var peak = 0.0
            for c in 0..<channels {
                let line = history + c * stride
                let x = samples[c].isFinite ? samples[c] : 0
                line[write] = x
                line[write + historyFrames] = x
                let points = line + window
                let atSample = points[centre].magnitude
                if atSample > peak { peak = atSample }
                var row = taps
                var phase = 0
                while phase < interpolating {
                    // Four running sums, so the adds don't wait on one another; tapsPerPhase is a multiple of 4.
                    var sum0 = 0.0
                    var sum1 = 0.0
                    var sum2 = 0.0
                    var sum3 = 0.0
                    var i = 0
                    while i < tapsPerPhase {
                        sum0 += row[i] * points[i]
                        sum1 += row[i + 1] * points[i + 1]
                        sum2 += row[i + 2] * points[i + 2]
                        sum3 += row[i + 3] * points[i + 3]
                        i += 4
                    }
                    // Written as a comparison so a NaN from overflowing extremes is ignored, never kept.
                    let between = ((sum0 + sum1) + (sum2 + sum3)).magnitude
                    if between > peak { peak = between }
                    row += tapsPerPhase
                    phase += 1
                }
            }

            // The sample's gain shapes the intervals either side of it.
            let around = peak > previousPeak ? peak : previousPeak
            previousPeak = peak
            let needed = around > ceiling ? ceiling / around : 1

            // Hold: the deque's gains rise from head to tail; the head is the window's minimum.
            while tail > head && holdGains[(tail - 1) & holdMask] >= needed { tail -= 1 }
            holdGains[tail & holdMask] = needed
            holdFrames[tail & holdMask] = frame
            tail += 1
            if holdFrames[head & holdMask] <= frame - lookahead { head += 1 }
            let hold = holdGains[head & holdMask]

            // Release.
            if hold < envelope {
                envelope = hold
            } else if hold > envelope {
                envelope += (hold - envelope) * releaseCoefficient
                if hold - envelope < snap { envelope = hold }
            }

            // Ramp.
            let deficit = 1 - envelope
            let leaving = deficits[deficitSlot]
            deficits[deficitSlot] = deficit
            deficitSlot = deficitSlot + 1 == lookahead ? 0 : deficitSlot + 1
            if leaving != 0 { deficitCount -= 1 }
            if deficit != 0 { deficitCount += 1 }
            deficitSum += deficit - leaving
            let gain: Double
            if deficitCount == 0 {
                deficitSum = 0
                gain = 1
            } else {
                gain = min(1, 1 - deficitSum * inverseLookahead)
            }
            if gain < smallestGain { smallestGain = gain }

            let read = (frame - latency) & mask
            for c in 0..<channels { samples[c] = history[c * stride + read] * gain }
            frame += 1
        }

        self.frame = frame
        holdHead = head
        holdTail = tail
        self.previousPeak = previousPeak
        self.envelope = envelope
        self.deficitSum = deficitSum
        self.deficitCount = deficitCount
        self.deficitSlot = deficitSlot
        let db = smallestGain < 1 ? min(-20 * log10(max(smallestGain, 1e-6)), 120) : 0
        reduction.store(db.bitPattern, ordering: .relaxed)
    }

    /// Render thread: carries on from `other`'s state (its recent input, hold, release and ramp), as if this limiter had
    /// been running all along, so a recompiled chain picks up mid-stream without restarting its look-ahead. Does
    /// nothing unless both were made for the same channels and rate, whose buffers then have the same shapes; their
    /// ceilings may differ. Real-time safe: it only copies, into buffers allocated in `init`, and reads `other` as
    /// plain values, so no class reference is captured or retained, even in a debug build.
    func adoptState(of other: Unmanaged<TruePeakLimiter>) {
        let theirs = other._withUnsafeGuaranteedRef { $0.state }
        guard theirs.history != history, theirs.channels == channels, theirs.historyFrames == historyFrames,
            theirs.lookahead == lookahead, theirs.holdMask == holdMask, theirs.oversampling == oversampling
        else { return }
        history.update(from: theirs.history, count: channels * 2 * historyFrames)
        holdGains.update(from: theirs.holdGains, count: holdMask + 1)
        holdFrames.update(from: theirs.holdFrames, count: holdMask + 1)
        deficits.update(from: theirs.deficits, count: lookahead)
        frame = theirs.frame
        holdHead = theirs.holdHead
        holdTail = theirs.holdTail
        previousPeak = theirs.previousPeak
        envelope = theirs.envelope
        deficitSum = theirs.deficitSum
        deficitCount = theirs.deficitCount
        deficitSlot = theirs.deficitSlot
    }

    /// Render thread: back to rest, as `init` left it: silent history, no reduction, the ramp empty. For a limiter that
    /// starts again after standing idle (the A/B comparison's, `SoundChain`). Real-time safe: plain loops over buffers
    /// allocated in `init`.
    func reset() {
        var i = 0
        while i < channels * 2 * historyFrames {
            history[i] = 0
            i += 1
        }
        i = 0
        while i <= holdMask {
            holdGains[i] = 1
            holdFrames[i] = 0
            i += 1
        }
        i = 0
        while i < lookahead {
            deficits[i] = 0
            i += 1
        }
        frame = 0
        holdHead = 0
        holdTail = 0
        previousPeak = 0
        envelope = 1
        deficitSum = 0
        deficitCount = 0
        deficitSlot = 0
        reduction.store(0, ordering: .relaxed)
    }

    /// What `adoptState(of:)` copies, and the shapes it checks, as plain values.
    private struct State {
        var history: UnsafeMutablePointer<Double>
        var holdGains: UnsafeMutablePointer<Double>
        var holdFrames: UnsafeMutablePointer<Int>
        var deficits: UnsafeMutablePointer<Double>
        var channels: Int
        var historyFrames: Int
        var lookahead: Int
        var holdMask: Int
        var oversampling: Int
        var frame: Int
        var holdHead: Int
        var holdTail: Int
        var previousPeak: Double
        var envelope: Double
        var deficitSum: Double
        var deficitCount: Int
        var deficitSlot: Int
    }

    private var state: State {
        State(
            history: history, holdGains: holdGains, holdFrames: holdFrames, deficits: deficits, channels: channels,
            historyFrames: historyFrames, lookahead: lookahead, holdMask: holdMask, oversampling: oversampling,
            frame: frame, holdHead: holdHead, holdTail: holdTail, previousPeak: previousPeak, envelope: envelope,
            deficitSum: deficitSum, deficitCount: deficitCount, deficitSlot: deficitSlot)
    }

    /// Detection points per sample interval at `sampleRate`: 16 up to 48 kHz and 8 above, so the grid is at least
    /// 705.6 kHz (rulings R4-T4b, R4-T4e). A crest between two points is then under-read by at most
    /// cos(π f / grid), which is 0.035 dB at 20 kHz. Using 8× (not 4×) at the highest rates keeps ultrasonic content,
    /// such as a DSD-sourced file's noise-shaped hash, within 0.09 dB.
    static func oversampling(atRate sampleRate: Double) -> Int {
        sampleRate <= 48_000 ? 16 : 8
    }

    static func powerOfTwo(atLeast n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}
