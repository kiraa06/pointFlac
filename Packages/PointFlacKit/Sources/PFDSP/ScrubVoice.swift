import Foundation

/// The platter's sound under a finger (spec §4.3, §5.2: "audio follows the hand"): the music read at whatever speed
/// and direction the record turns, through a band-limited variable-rate resampler, like a deck's needle in the groove.
///
/// Three parts, all real-time safe (no allocation, locks or reference counting once made):
/// - ``ScrubKernel`` reads between samples with a Kaiser-windowed sinc, narrowing its passband as the record turns
///   faster than normal so a fast scratch never aliases.
/// - ``PlatterFollower`` turns hand positions, which arrive at the touch rate (60 or 120 Hz), into smooth motion: the
///   read speed (and so the pitch) glides instead of stepping, and lands where the hand stopped.
/// - ``ScrubVoice`` runs them per output frame, extrapolating the hand between touches, with a motor mode for the
///   spin-up after release, and the stylus's behaviour near rest: the level fades out, so a still record is silent.

/// Kaiser-windowed sinc interpolation over a ring of interleaved Float32 frames.
public struct ScrubKernel: @unchecked Sendable {
    /// Zero crossings either side of the centre at full bandwidth: 24 taps when the record turns at normal speed.
    public static let halfWidth = 12
    /// The fastest read, in source frames per output frame, that keeps its own anti-alias filter. Faster turns are
    /// read at this speed (the position still catches up), which bounds the work per frame to about 200 taps.
    public static let maxAdvance = 8.0
    static let oversample = 512
    static let beta = 7.5
    static let tableCount = halfWidth * oversample + 2

    /// Built once and never freed, so readers hold a plain pointer: no reference counting on the render thread.
    nonisolated(unsafe) private static let sharedTable: UnsafePointer<Float> = {
        let table = UnsafeMutablePointer<Float>.allocate(capacity: tableCount)
        let i0Beta = besselI0(beta)
        for i in 0..<tableCount {
            let x = Double(i) / Double(oversample)
            guard x < Double(halfWidth) else {
                table[i] = 0
                continue
            }
            let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
            let r = x / Double(halfWidth)
            table[i] = Float(sinc * besselI0(beta * (1 - r * r).squareRoot()) / i0Beta)
        }
        return UnsafePointer(table)
    }()

    private let table: UnsafePointer<Float>

    /// Touches the shared table: make kernels off the render thread (the table is built on first use).
    public init() {
        table = Self.sharedTable
    }

    /// The passband, as a fraction of the source's Nyquist, for reading `advance` source frames per output frame:
    /// full bandwidth up to normal speed, then narrowed so nothing above the output's Nyquist gets through. The 5 %
    /// margin keeps the filter's transition band below it too.
    public static func cutoff(forAdvance advance: Double) -> Double {
        0.95 / min(max(abs(advance), 1), maxAdvance)
    }

    /// Frames either side of the read position that `read` touches at `cutoff`.
    public static func reach(cutoff: Double) -> Int {
        Int((Double(halfWidth) / cutoff).rounded(.up))
    }

    /// Writes `channels` samples interpolated at the fractional source frame `position` into `out`.
    ///
    /// `ring` holds interleaved frames at index `frame & mask` (a power-of-two ring), so `position` is an absolute
    /// frame number. The caller makes sure every frame within `reach(cutoff:)` of `position` is valid. The weights are
    /// normalised to sum to one, so a constant reads back exactly. Real-time safe.
    @inline(__always)
    public func read(
        ring: UnsafePointer<Float>, mask: Int, channels: Int, position: Double, cutoff: Double,
        into out: UnsafeMutablePointer<Float>
    ) {
        let reach = Self.reach(cutoff: cutoff)
        let base = Int(position.rounded(.down))
        let frac = position - Double(base)
        let scale = cutoff * Double(Self.oversample)
        for c in 0..<channels { out[c] = 0 }
        var sum = 0.0
        var n = 1 - reach
        while n <= reach {
            let d = abs(Double(n) - frac) * scale
            let i = Int(d)
            if i < Self.tableCount - 1 {
                let t = Float(d - Double(i))
                let w = table[i] + (table[i + 1] - table[i]) * t
                let source = ring + ((base + n) & mask) * channels
                for c in 0..<channels { out[c] += w * source[c] }
                sum += Double(w)
            }
            n += 1
        }
        guard sum != 0 else { return }
        let gain = Float(1 / sum)
        for c in 0..<channels { out[c] *= gain }
    }

    /// The zeroth-order modified Bessel function of the first kind, by its power series (for the Kaiser window).
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let quarter = x * x / 4
        for k in 1..<64 {
            term *= quarter / Double(k * k)
            sum += term
            if term < sum * 1e-17 { break }
        }
        return sum
    }
}

/// The record's position and speed, in source frames and source frames per output frame, moved one output frame at a
/// time either after a hand (a critically damped spring) or by the motor (a constant-torque ramp).
public struct PlatterFollower: Sendable, Equatable {
    public private(set) var position: Double
    public private(set) var velocity: Double

    /// How quickly the record follows the hand. 30 Hz settles a sudden stop in about 55 ms and smooths touch steps,
    /// while lagging a steadily turning hand by nothing (the damping works against the hand's own speed).
    public static let handHz = 30.0
    /// The motor's spin-up from rest to 33⅓ rpm after release, at constant torque.
    public static let spinUpSeconds = 0.35

    public init(position: Double, velocity: Double) {
        self.position = position
        self.velocity = velocity
    }

    /// `handHz` in radians per output frame.
    public static func handOmega(outputRate: Double) -> Double {
        2 * .pi * handHz / outputRate
    }

    /// One output frame toward the hand at `target`, moving at `targetVelocity`: critically damped, so no overshoot.
    public mutating func follow(_ target: Double, velocity targetVelocity: Double = 0, omega: Double) {
        velocity += omega * omega * (target - position) + 2 * omega * (targetVelocity - velocity)
        position += velocity
    }

    /// One output frame of the motor: the speed moves toward `rate` by at most `step`, then holds there.
    public mutating func drive(toward rate: Double, step: Double) {
        let gap = rate - velocity
        velocity = abs(gap) <= step ? rate : velocity + (gap > 0 ? step : -step)
        position += velocity
    }

    /// `drive(toward:step:)` reaching `rate` from rest in `framesToSpeed` frames.
    public mutating func drive(toward rate: Double, framesToSpeed: Double) {
        drive(toward: rate, step: abs(rate) / max(framesToSpeed, 1))
    }
}

/// One scrubbing record: reads the music where the platter is, at the platter's speed, a block at a time.
///
/// Positions are absolute source frames; speeds are platter speeds (1 is normal play, −1 normal speed backwards).
/// The decoded music lives in a power-of-two ring of interleaved Float32 frames filled by someone else; `render` reads
/// only inside the `valid` range it is given and is silent outside it.
public struct ScrubVoice: Sendable {
    public let channels: Int
    /// Source frames per output frame at normal speed.
    public let nominal: Double
    public let outputRate: Double
    private let kernel = ScrubKernel()
    private let omega: Double
    private var follower: PlatterFollower

    private enum Drive: Sendable {
        case hand
        case motor
    }
    private var drive = Drive.hand
    private var handTarget: Double
    private var handVelocity: Double
    /// Frames the hand's last speed may still be extrapolated: a finger that stops sending moves has stopped.
    private var extrapolationLeft = 0
    private let maxExtrapolation: Int
    private var motorVelocity = 0.0
    private var motorStep = 0.0

    /// The stylus's level, which falls away as the record slows to a stop: a record held still is silent, not a held
    /// sample, and a hand's tiny tremors make no sound. (No DC blocker: its start-up transient would thump when a hand
    /// lands on a playing record, where the voice takes over mid-signal.)
    private var level: Float = 0
    private let levelCoefficient: Float

    /// Below this platter speed the level fades toward silence.
    static let quietBelow = 0.15
    /// How long the hand's speed is carried forward without a new touch.
    static let extrapolationSeconds = 0.04

    /// - Parameters:
    ///   - channels: 1…8.
    ///   - position: the source frame under the needle.
    ///   - speed: the platter speed it is already turning at (1 when playing, 0 when stopped).
    public init(channels: Int, sourceRate: Double, outputRate: Double, at position: Double, speed: Double = 0) {
        precondition((1...8).contains(channels), "ScrubVoice handles 1 to 8 channels")
        self.channels = channels
        nominal = sourceRate / outputRate
        self.outputRate = outputRate
        omega = PlatterFollower.handOmega(outputRate: outputRate)
        follower = PlatterFollower(position: position, velocity: speed * nominal)
        handTarget = position
        handVelocity = speed * nominal
        maxExtrapolation = Int(Self.extrapolationSeconds * outputRate)
        extrapolationLeft = maxExtrapolation
        level = Float(min(1, abs(speed) / Self.quietBelow))
        levelCoefficient = Float(1 - exp(-1 / (0.005 * outputRate)))
    }

    /// The source frame under the needle now.
    public var position: Double { follower.position }
    /// The platter speed now (1 is normal play).
    public var speed: Double { follower.velocity / nominal }

    /// The hand is at source frame `target`, turning the record at platter speed `speed`. Call on every touch move;
    /// between calls the voice carries the hand on at that speed for a few tens of milliseconds.
    public mutating func hand(target: Double, speed: Double) {
        drive = .hand
        handTarget = target
        handVelocity = speed * nominal
        extrapolationLeft = maxExtrapolation
    }

    /// The hand let go: the motor brings the platter to `speed` (1 to play on) at constant torque over `seconds`
    /// from rest.
    public mutating func release(toSpeed speed: Double, seconds: Double = PlatterFollower.spinUpSeconds) {
        drive = .motor
        motorVelocity = speed * nominal
        motorStep = nominal / max(1, seconds * outputRate)
    }

    /// Renders `frames` interleaved frames into `out`. Real-time safe.
    public mutating func render(
        ring: UnsafePointer<Float>, mask: Int, valid: Range<Int64>, frames: Int, into out: UnsafeMutablePointer<Float>
    ) {
        for i in 0..<frames {
            let frame = out + i * channels
            let advance = follower.velocity
            let cutoff = ScrubKernel.cutoff(forAdvance: advance)
            let reach = Int64(ScrubKernel.reach(cutoff: cutoff))
            let base = Int64(follower.position.rounded(.down))
            if base + 1 - reach >= valid.lowerBound, base + reach < valid.upperBound {
                kernel.read(
                    ring: ring, mask: mask, channels: channels, position: follower.position, cutoff: cutoff,
                    into: frame)
            } else {
                for c in 0..<channels { frame[c] = 0 }
            }
            let target = Float(min(1, abs(advance / nominal) / Self.quietBelow))
            level += (target - level) * levelCoefficient
            for c in 0..<channels { frame[c] *= level }
            step()
        }
    }

    /// Moves the platter on by one output frame.
    private mutating func step() {
        switch drive {
        case .hand:
            follower.follow(handTarget, velocity: handVelocity, omega: omega)
            if extrapolationLeft > 0 {
                handTarget += handVelocity
                extrapolationLeft -= 1
            } else {
                handVelocity = 0
            }
        case .motor:
            follower.drive(toward: motorVelocity, step: motorStep)
        }
    }
}
