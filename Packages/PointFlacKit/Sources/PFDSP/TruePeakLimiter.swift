import Foundation
import Synchronization

/// The last block of the Sound chain (spec §4.8 block 7): a look-ahead limiter that keeps the output's true peak, as
/// ITU-R BS.1770-4 Annex 2 measures it, under a ceiling in dBTP. EQ boosts and preamp trim can then never push the
/// DAC's reconstruction past full scale, even between samples, where a sample-peak limiter would let it through.
///
/// It is in the chain whenever any block is on (plan ruling R4-6), so it must cost nothing audible while it is not
/// needed: the audio path is only a delay line and a gain, and the gain is exactly 1 until a true peak would cross the
/// ceiling. Below the ceiling the output is the input, bit for bit, `latencyFrames` later. The oversampling is for
/// detection only; the audio itself is never resampled or filtered.
///
/// ## Detector
/// Each frame, every channel is read at the sample and at a quarter, a half and three quarters of the way to the next
/// one, by a 4× polyphase interpolator after BS.1770-4 Annex 2: 48 taps, 12 per phase, a Kaiser-windowed sinc with
/// β 8, each phase normalised to unity at DC. The phases sit on the sample grid, so phase 0 is the sample itself (the
/// windowed sinc is an impulse there) and a sample peak is read exactly. The interpolating phases are flat to 0.01 dB
/// up to 0.3 × the rate and fall away above it (−1.7 dB at 0.4 ×), as twelve taps must. With the quarter-sample grid,
/// that is a 4× meter's blind spot: tones are held to within 0.07 dB at any frequency, but full-band noise can peak
/// about 0.25 dB over the ceiling as a 16× reconstruction sees it. The frame's peak is the largest across channels.
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
    /// Frames from input to output: the look-ahead, plus five more for the detector to read past the frame it judges.
    public let latencyFrames: Int

    static let phases = 4
    static let tapsPerPhase = 12
    static let beta = 8.0
    /// Within this of its target, a releasing gain takes the target exactly.
    static let snap = 1e-9

    /// The ceiling as a linear amplitude.
    private let ceiling: Double
    /// The look-ahead window, in frames: both the hold's and the ramp's length.
    private let lookahead: Int
    private let inverseLookahead: Double
    /// The release's step toward its target, per frame.
    private let releaseCoefficient: Double

    /// Each channel's recent input in a ring of `historyFrames` (a power of two), written twice, at `i` and
    /// `i + historyFrames`, so the detector's twelve taps are always contiguous. Channel `c` starts at
    /// `c * 2 * historyFrames`.
    private let history: UnsafeMutablePointer<Double>
    private let historyFrames: Int
    /// The three interpolating phases' taps, `tapsPerPhase` each, for offsets ¼, ½ and ¾.
    private let taps: UnsafeMutablePointer<Double>
    /// The hold's deque of (needed gain, frame), a ring of `holdMask + 1` entries.
    private let holdGains: UnsafeMutablePointer<Double>
    private let holdFrames: UnsafeMutablePointer<Int>
    private let holdMask: Int
    /// The ramp's window: `1 − gain` for the last `lookahead` frames.
    private let deficits: UnsafeMutablePointer<Double>

    // Render-thread state.
    private var frame = 0
    private var holdHead = 0
    private var holdTail = 0
    private var previousPeak = 0.0
    private var envelope = 1.0
    private var deficitSum = 0.0
    /// Nonzero entries in `deficits`: at zero the ramp is exactly 1, whatever rounding the running sum carries.
    private var deficitCount = 0
    private var deficitSlot = 0

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
        let release = releaseSeconds.isFinite && releaseSeconds > 0 ? releaseSeconds : 0.1
        releaseCoefficient = 1 - exp(-1 / (release * sampleRate))
        // The interval after frame m needs frame m + 6; the hold and the ramp then reach lookahead − 1 frames on.
        latencyFrames = lookahead + Self.tapsPerPhase / 2 - 1

        historyFrames = Self.powerOfTwo(atLeast: latencyFrames + Self.tapsPerPhase)
        history = .allocate(capacity: channels * 2 * historyFrames)
        history.initialize(repeating: 0, count: channels * 2 * historyFrames)

        taps = .allocate(capacity: (Self.phases - 1) * Self.tapsPerPhase)
        let i0Beta = ScrubKernel.besselI0(Self.beta)
        let half = Double(Self.tapsPerPhase / 2)
        for phase in 1..<Self.phases {
            let t = Double(phase) / Double(Self.phases)
            let row = taps + (phase - 1) * Self.tapsPerPhase
            var sum = 0.0
            for i in 0..<Self.tapsPerPhase {
                // Tap i reads frame m − 5 + i for the point m + t.
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
        let interpolating = Self.phases - 1
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
            // Frame m = frame − 6 and the interval after it: frames m − 5 ... m + 6.
            let window = (frame - reach) & mask
            var peak = 0.0
            for c in 0..<channels {
                let line = history + c * stride
                let x = samples[c].isFinite ? samples[c] : 0
                line[write] = x
                line[write + historyFrames] = x
                let points = line + window
                let atSample = abs(points[centre])
                if atSample > peak { peak = atSample }
                for phase in 0..<interpolating {
                    let row = taps + phase * tapsPerPhase
                    var sum = 0.0
                    for i in 0..<tapsPerPhase { sum += row[i] * points[i] }
                    // Written as a comparison so a NaN from overflowing extremes is ignored, never kept.
                    let between = abs(sum)
                    if between > peak { peak = between }
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
                if hold - envelope < Self.snap { envelope = hold }
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

    static func powerOfTwo(atLeast n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}
