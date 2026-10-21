import Foundation

/// The platter's angle over time, with physical spin-up and wind-down.
///
/// Why analytic rather than stepped: the deck draws the record from a `TimelineView`, and computing the angle from the
/// time (instead of adding a delta each frame) keeps it exact at any frame rate, costs nothing between frames, and
/// never drifts when a frame is late.
public struct SpinModel: Sendable, Equatable {
    /// 33⅓ rpm: one turn every 1.8 s.
    public static let secondsPerTurn = 1.8
    public static let fullSpeed = 360 / secondsPerTurn  // degrees per second

    /// Time to reach full speed from rest, and to stop from full speed.
    public var spinUpSeconds: Double
    public var windDownSeconds: Double

    private var anchorTime: Double = 0
    private var anchorAngle: Double = 0
    private var startVelocity: Double = 0
    private var targetVelocity: Double = 0
    private var rampSeconds: Double = 0

    public init(spinUpSeconds: Double = 0.9, windDownSeconds: Double = 1.4) {
        self.spinUpSeconds = spinUpSeconds
        self.windDownSeconds = windDownSeconds
    }

    /// Starts spinning up to 33⅓, or winding down to rest, from wherever the platter is at `t`.
    public mutating func setSpinning(_ spinning: Bool, at t: Double) {
        let angle = angle(at: t)
        let velocity = velocity(at: t)
        let target = spinning ? Self.fullSpeed : 0
        guard target != targetVelocity || velocity != target else { return }
        anchorTime = t
        anchorAngle = angle
        startVelocity = velocity
        targetVelocity = target
        let span = abs(target - velocity) / Self.fullSpeed
        rampSeconds = span * (spinning ? spinUpSeconds : windDownSeconds)
    }

    /// Puts the record at `angle`, at rest (a hand let go of it), or spinning at once at full speed.
    public mutating func place(at angle: Double, time t: Double, spinning: Bool) {
        anchorTime = t
        anchorAngle = angle
        startVelocity = spinning ? Self.fullSpeed : 0
        targetVelocity = startVelocity
        rampSeconds = 0
    }

    public func velocity(at t: Double) -> Double {
        let dt = max(0, t - anchorTime)
        guard rampSeconds > 0, dt < rampSeconds else { return targetVelocity }
        return startVelocity + (targetVelocity - startVelocity) * dt / rampSeconds
    }

    /// Degrees, unbounded (the view only rotates by it).
    public func angle(at t: Double) -> Double {
        let dt = max(0, t - anchorTime)
        if rampSeconds > 0, dt < rampSeconds {
            return anchorAngle + startVelocity * dt + (targetVelocity - startVelocity) * dt * dt / (2 * rampSeconds)
        }
        let ramp = (startVelocity + targetVelocity) / 2 * rampSeconds
        return anchorAngle + ramp + targetVelocity * (dt - rampSeconds)
    }

    /// Nothing moves at `t`: the timeline driving the record can pause.
    public func isAtRest(at t: Double) -> Bool {
        targetVelocity == 0 && velocity(at: t) == 0
    }
}

/// The tonearm's sweep: the needle angle for a place on the side, and back.
///
/// Angles are degrees of rotation about the pivot from the arm's rest position. The lead-in groove sits at
/// `leadInAngle` and the run-out at `runoutAngle`; the needle tracks linearly between them, as the mockups draw it.
public struct TonearmGeometry: Sendable, Equatable {
    public var restAngle: Double
    public var leadInAngle: Double
    public var runoutAngle: Double

    public init(restAngle: Double = 0, leadInAngle: Double = 17, runoutAngle: Double = 38) {
        self.restAngle = restAngle
        self.leadInAngle = leadInAngle
        self.runoutAngle = runoutAngle
    }

    /// The angle for `fraction` (0 = lead-in, 1 = run-out) of the side.
    public func angle(forFraction fraction: Double) -> Double {
        leadInAngle + (runoutAngle - leadInAngle) * min(max(fraction, 0), 1)
    }

    /// The fraction of the side under the needle at `angle`, clamped to the grooves.
    public func fraction(forAngle angle: Double) -> Double {
        guard runoutAngle != leadInAngle else { return 0 }
        return min(max((angle - leadInAngle) / (runoutAngle - leadInAngle), 0), 1)
    }
}

/// The platter as a jog wheel (spec §4.3): one turn of the record moves 1.8 s, as at 33⅓ rpm.
public enum JogMath {
    /// The signed change from angle `a` to angle `b`, in degrees, the short way round: (−180, 180]. Summing these per
    /// drag step unwraps a finger going round and round.
    public static func delta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Seconds of audio for `degrees` of record rotation (clockwise is forward).
    public static func seconds(forDegrees degrees: Double) -> Double {
        degrees / 360 * SpinModel.secondsPerTurn
    }
}
