import Foundation
import Synchronization

/// The level match behind the Sound tab's A/B comparison (Task 14): how loud the processed signal is against the
/// original, as ITU-R BS.1770 hears loudness, and the gain that brings the original to the same loudness. A louder
/// side always sounds better for a moment, so a comparison that isn't level-matched compares levels, not sound.
///
/// ## Measurement
/// Both signals are K-weighted (BS.1770-4: the head-effect pre-filter, a high shelf of about +4 dB above 1.7 kHz, then
/// the RLB high-pass near 38 Hz), designed for the rate in use as libebur128 designs them, which gives BS.1770's own
/// coefficients at 48 kHz. They are squared and summed across channels with equal weights (the channel layout is not
/// known here; both sides share it, so the weights cancel in the ratio).
///
/// The sums are kept in 10 ms blocks, and each mean square is the sum of the latest 40 blocks over their length: a
/// 400 ms window (the momentary loudness's) that slides every 10 ms. The caller hands the original over lined up with
/// the processed signal (delayed by the chain's latency), so both windows always hold the same music. A window that
/// is still filling (after a start or a format change) is the mean of what it holds.
///
/// ## Gain
/// The original's gain is `sqrt(processed / original)`, clamped to ±12 dB, and follows that target through a one-pole
/// smoother with a 50 ms time constant, frame by frame, so it never steps. A window that is silent on either side,
/// below BS.1770's absolute gate of −70 LKFS, leaves the target where it was: silence, a fade-in or a pause never sends
/// the gain to a clamp, and no NaN or infinity can arise. Non-finite samples count as silence.
///
/// It measures whether or not the comparison is held, so the gain is ready the moment a finger lands and keeps
/// following the processed signal while it is held.
///
/// ## Real-time safety
/// Every buffer is allocated in `init`. `process`, `restart` and `retune` touch only those raw pointers and stored
/// scalars, with plain loops: no allocation, locks, logging or reference counting. Call them from one thread at a
/// time (the render thread); `gainDb` may be read from any thread.
public final class LoudnessMatcher: @unchecked Sendable {
    /// What a matcher needs for one rate, worked out off the render thread (`SoundChain` keeps one per chain).
    public struct Tuning: Equatable, Sendable {
        public let sampleRate: Double
        /// BS.1770's pre-filter: a high shelf of about +4 dB above 1.7 kHz, for the head's acoustic effect.
        public let shelf: BiquadCoefficients
        /// BS.1770's RLB weighting: a second-order high-pass near 38 Hz.
        public let highPass: BiquadCoefficients
        /// Frames per 10 ms block, at least one.
        let blockFrames: Int
        /// The gain smoother's step toward its target per frame: a 50 ms time constant.
        let smoothing: Double

        /// libebur128's design (`ebur128_init_filter`, MIT), which reproduces BS.1770-4's tables at 48 kHz.
        public init(sampleRate: Double) {
            precondition(sampleRate.isFinite && sampleRate > 0, "LoudnessMatcher needs a sample rate")
            self.sampleRate = sampleRate
            // The pre-filter's analog parameters; its corner is kept below Nyquist at improbably low rates.
            let f0 = min(1681.974450955533, 0.45 * sampleRate)
            let g = 3.999843853973347
            let q = 0.7071752369554196
            var k = tan(.pi * f0 / sampleRate)
            let vh = pow(10, g / 20)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            shelf = BiquadCoefficients(
                b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
            let f1 = min(38.13547087602444, 0.45 * sampleRate)
            let q1 = 0.5003270373238773
            k = tan(.pi * f1 / sampleRate)
            let d = 1 + k / q1 + k * k
            highPass = BiquadCoefficients(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / d, a2: (1 - k / q1 + k * k) / d)
            blockFrames = max(1, Int((sampleRate * LoudnessMatcher.blockSeconds).rounded()))
            smoothing = -expm1(-1 / (LoudnessMatcher.smoothingSeconds * sampleRate))
        }
    }

    /// The window's blocks: 40 of 10 ms, 400 ms in all.
    static let blocks = 40
    static let blockSeconds = 0.010
    public static let smoothingSeconds = 0.050
    /// The gain's range, either way.
    public static let maxGainDb = 12.0

    public let maxFrames: Int
    public let maxChannels: Int
    private let minGain: Double
    private let maxGain: Double
    /// BS.1770's absolute gate, −70 LKFS, as the channels' summed mean square.
    private let gate: Double

    /// Four filters per channel, at `channel * 4`: the original's shelf and high-pass, then the processed signal's.
    private let filters: UnsafeMutablePointer<Biquad>
    /// The finished blocks' sums, a ring of `blocks`: the original's, then the processed signal's.
    private let dryBlocks: UnsafeMutablePointer<Double>
    private let wetBlocks: UnsafeMutablePointer<Double>
    /// Per-frame K-weighted energy of the piece being processed, summed across channels.
    private let dryEnergy: UnsafeMutablePointer<Double>
    private let wetEnergy: UnsafeMutablePointer<Double>

    // Render-thread state, one thread at a time. Unchecked, as `TruePeakLimiter`'s is: a debug build's dynamic
    // exclusivity checks would allocate the render thread's context on its first call.
    @exclusivity(unchecked) public private(set) var tuning: Tuning
    /// The next block's slot in the rings, and how many of them hold a finished block (at most `blocks`).
    @exclusivity(unchecked) private var slot = 0
    @exclusivity(unchecked) private var filled = 0
    /// The block being summed.
    @exclusivity(unchecked) private var blockDry = 0.0
    @exclusivity(unchecked) private var blockWet = 0.0
    @exclusivity(unchecked) private var blockCount = 0
    /// The gain the window asks for, clamped, and the smoothed gain that follows it. Render thread (or a test).
    @exclusivity(unchecked) private(set) var targetGain = 1.0
    @exclusivity(unchecked) private(set) var gain = 1.0

    /// `gain`'s bit pattern, for a readout on another thread.
    private let published = Atomic<UInt64>(1.0.bitPattern)

    /// - Parameters:
    ///   - maxFrames: the most frames one `process` call takes.
    ///   - maxChannels: the most channels it takes.
    public init(sampleRate: Double, maxFrames: Int = 4096, maxChannels: Int = 8) {
        precondition(maxFrames > 0 && maxChannels > 0, "LoudnessMatcher needs room for at least one sample")
        self.maxFrames = maxFrames
        self.maxChannels = maxChannels
        tuning = Tuning(sampleRate: sampleRate)
        minGain = pow(10, -Self.maxGainDb / 20)
        maxGain = pow(10, Self.maxGainDb / 20)
        gate = pow(10, (-70 + 0.691) / 10)
        filters = .allocate(capacity: maxChannels * 4)
        dryBlocks = .allocate(capacity: Self.blocks)
        wetBlocks = .allocate(capacity: Self.blocks)
        dryEnergy = .allocate(capacity: maxFrames)
        wetEnergy = .allocate(capacity: maxFrames)
        for c in 0..<maxChannels {
            (filters + c * 4).initialize(to: Biquad(tuning.shelf))
            (filters + c * 4 + 1).initialize(to: Biquad(tuning.highPass))
            (filters + c * 4 + 2).initialize(to: Biquad(tuning.shelf))
            (filters + c * 4 + 3).initialize(to: Biquad(tuning.highPass))
        }
        dryBlocks.initialize(repeating: 0, count: Self.blocks)
        wetBlocks.initialize(repeating: 0, count: Self.blocks)
        dryEnergy.initialize(repeating: 0, count: maxFrames)
        wetEnergy.initialize(repeating: 0, count: maxFrames)
    }

    deinit {
        filters.deinitialize(count: maxChannels * 4)
        filters.deallocate()
        dryBlocks.deallocate()
        wetBlocks.deallocate()
        dryEnergy.deallocate()
        wetEnergy.deallocate()
    }

    /// The smoothed gain the original gets, in dB. Any thread.
    public var gainDb: Double {
        20 * log10(Double(bitPattern: published.load(ordering: .relaxed)))
    }

    // MARK: Render thread

    /// Starts measuring again from nothing (after a pause in the stream, or a format change), keeping the gain: what
    /// the same settings needed before is the best guess until the window holds something.
    func restart() {
        let shelf = tuning.shelf
        let highPass = tuning.highPass
        var i = 0
        while i < maxChannels {
            filters[i * 4] = Biquad(shelf)
            filters[i * 4 + 1] = Biquad(highPass)
            filters[i * 4 + 2] = Biquad(shelf)
            filters[i * 4 + 3] = Biquad(highPass)
            i += 1
        }
        i = 0
        while i < Self.blocks {
            dryBlocks[i] = 0
            wetBlocks[i] = 0
            i += 1
        }
        slot = 0
        filled = 0
        blockDry = 0
        blockWet = 0
        blockCount = 0
    }

    /// Takes `tuning`'s rate, and starts measuring again (`restart`).
    func retune(_ tuning: Tuning) {
        self.tuning = tuning
        restart()
    }

    /// Measures `frames` interleaved frames of `channels` channels: `dry`, the original lined up with `wet`, the
    /// processed signal. Each frame moves the window and the gain on; then, if `scale` is given, its frame (which may
    /// be `dry` itself, or the original at another delay) is multiplied by the gain. Does nothing for more than
    /// `maxFrames` frames or `maxChannels` channels.
    func process(
        dry: UnsafePointer<Double>, wet: UnsafePointer<Float>, scale: UnsafeMutablePointer<Double>?, frames: Int,
        channels: Int
    ) {
        guard frames > 0, channels > 0, frames <= maxFrames, channels <= maxChannels else { return }
        let dryEnergy = dryEnergy
        let wetEnergy = wetEnergy
        var f = 0
        while f < frames {
            dryEnergy[f] = 0
            wetEnergy[f] = 0
            f += 1
        }
        // Channel by channel, the K-weighted energy of every frame.
        var c = 0
        while c < channels {
            let row = filters + c * 4
            var dryShelf = row[0]
            var dryHighPass = row[1]
            var wetShelf = row[2]
            var wetHighPass = row[3]
            var i = c
            f = 0
            while f < frames {
                let d = dry[i]
                let w = Double(wet[i])
                let kd = dryHighPass.process(dryShelf.process(d.isFinite ? d : 0))
                let kw = wetHighPass.process(wetShelf.process(w.isFinite ? w : 0))
                dryEnergy[f] += kd * kd
                wetEnergy[f] += kw * kw
                i += channels
                f += 1
            }
            row[0] = dryShelf
            row[1] = dryHighPass
            row[2] = wetShelf
            row[3] = wetHighPass
            c += 1
        }
        // Frame by frame: the blocks, the target at each block's end, and the smoothed gain.
        let blockFrames = tuning.blockFrames
        let smoothing = tuning.smoothing
        var blockDry = blockDry
        var blockWet = blockWet
        var blockCount = blockCount
        var target = targetGain
        var gain = gain
        var i = 0
        f = 0
        while f < frames {
            blockDry += dryEnergy[f]
            blockWet += wetEnergy[f]
            blockCount += 1
            if blockCount == blockFrames {
                dryBlocks[slot] = blockDry
                wetBlocks[slot] = blockWet
                slot = slot + 1 == Self.blocks ? 0 : slot + 1
                if filled < Self.blocks { filled += 1 }
                blockDry = 0
                blockWet = 0
                blockCount = 0
                target = windowTarget(else: target)
            }
            gain += (target - gain) * smoothing
            if let scale {
                var k = 0
                while k < channels {
                    scale[i + k] *= gain
                    k += 1
                }
            }
            i += channels
            f += 1
        }
        self.blockDry = blockDry
        self.blockWet = blockWet
        self.blockCount = blockCount
        targetGain = target
        self.gain = gain
        published.store(gain.bitPattern, ordering: .relaxed)
    }

    /// The gain the window asks for, clamped; `held` (the target so far) while either side is below the gate.
    private func windowTarget(else held: Double) -> Double {
        var dry = 0.0
        var wet = 0.0
        var k = 0
        while k < filled {
            dry += dryBlocks[k]
            wet += wetBlocks[k]
            k += 1
        }
        let frames = Double(filled * tuning.blockFrames)
        let dryMeanSquare = dry / frames
        let wetMeanSquare = wet / frames
        // Comparisons rather than `isFinite`: a NaN fails them, and so keeps the target.
        guard dryMeanSquare > gate, wetMeanSquare > gate else { return held }
        let ratio = (wetMeanSquare / dryMeanSquare).squareRoot()
        guard ratio > 0, ratio < .infinity else { return held }
        return min(max(ratio, minGain), maxGain)
    }
}
