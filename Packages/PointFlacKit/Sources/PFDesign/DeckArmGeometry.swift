import CoreGraphics
import Foundation

/// A pivoted tonearm seen from above (S, J or straight), built the way a real arm is aligned: its effective length is
/// the pivot-to-spindle distance plus the overhang, so the stylus would reach just past the spindle, and its headshell
/// is turned toward the spindle by the offset angle, so the stylus meets the groove nearly square on.
///
/// Angles are degrees of rotation about the pivot: 0 hangs the arm straight down the screen (+y), and positive swings
/// it clockwise on screen, which for a pivot at the deck's rear right carries the stylus in across the record. The
/// deck rotates its drawing of the arm by the same angle.
public struct PivotedArm: Sendable, Equatable {
    public let spindle: CGPoint
    public let recordRadius: Double
    public let pivot: CGPoint
    /// Pivot to spindle.
    public let pivotDistance: Double
    /// Pivot to stylus: the pivot-to-spindle distance plus the overhang.
    public let length: Double
    public let offsetDegrees: Double

    public init(
        spindle: CGPoint, recordRadius: Double, pivot: CGPoint,
        overhangToRecord: Double = VinylGeometry.overhangToRecord,
        offsetDegrees: Double = VinylGeometry.offsetAngleDegrees
    ) {
        self.spindle = spindle
        self.recordRadius = recordRadius
        self.pivot = pivot
        pivotDistance = hypot(pivot.x - spindle.x, pivot.y - spindle.y)
        length = pivotDistance + overhangToRecord * recordRadius
        self.offsetDegrees = offsetDegrees
    }

    /// The angle that would point the arm straight at the spindle. The arm never gets there: the run-out comes first.
    public var spindleAngle: Double {
        atan2(pivot.x - spindle.x, spindle.y - pivot.y) * 180 / .pi
    }

    /// Where the stylus is with the arm at `angle`.
    public func needle(atAngle angle: Double) -> CGPoint {
        let r = angle * .pi / 180
        return CGPoint(x: pivot.x - length * sin(r), y: pivot.y + length * cos(r))
    }

    /// The stylus's distance from the spindle with the arm at `angle`.
    public func radius(atAngle angle: Double) -> Double {
        let theta = (spindleAngle - angle) * .pi / 180
        return sqrt(max(0, pivotDistance * pivotDistance + length * length - 2 * pivotDistance * length * cos(theta)))
    }

    /// The angle that puts the stylus `radius` from the spindle, swinging in from the rest (the law of cosines in the
    /// triangle pivot, spindle, stylus), so the needle sits exactly on the groove it should.
    public func angle(forRadius radius: Double) -> Double {
        let c = (pivotDistance * pivotDistance + length * length - radius * radius) / (2 * pivotDistance * length)
        return spindleAngle - acos(min(max(c, -1), 1)) * 180 / .pi
    }

    /// The angle pointing the arm at `point` (a finger on it).
    public func angle(toward point: CGPoint) -> Double {
        atan2(pivot.x - point.x, point.y - pivot.y) * 180 / .pi
    }

    /// The headshell's axis, from its back to the stylus, in the same convention as the arm: the line from the pivot
    /// to the stylus turned by the offset angle toward the spindle. On the playing side of the spindle line the
    /// spindle lies clockwise of the arm, so the turn is positive.
    public func headshellAngle(atAngle angle: Double) -> Double {
        angle + offsetDegrees
    }
}

/// A linear-tracking arm: a carriage on a rail that runs along a radius, so the stylus moves straight toward the
/// spindle, with no arc and no offset angle.
public struct LinearArm: Sendable, Equatable {
    public let spindle: CGPoint
    public let recordRadius: Double
    /// The radius the rail runs along, out from the spindle, in radians on screen (0 is +x, π/2 is down).
    public let direction: Double
    /// Where the carriage parks, off the record, as a distance from the spindle.
    public let restRadius: Double

    public init(spindle: CGPoint, recordRadius: Double, direction: Double, restRadius: Double) {
        self.spindle = spindle
        self.recordRadius = recordRadius
        self.direction = direction
        self.restRadius = restRadius
    }

    /// The stylus `radius` from the spindle, on the rail's radius.
    public func stylus(atRadius radius: Double) -> CGPoint {
        CGPoint(x: spindle.x + radius * cos(direction), y: spindle.y + radius * sin(direction))
    }

    /// How far out along the rail `point` lies: a finger beside the rail moves the carriage to its projection.
    public func radius(toward point: CGPoint) -> Double {
        (point.x - spindle.x) * cos(direction) + (point.y - spindle.y) * sin(direction)
    }
}

/// Where the needle is, for any arm, as one number that grows from the rest through the lead-in to the run-out: a
/// pivoted arm's angle about its pivot, or how far a linear carriage has travelled in from its rest. The deck seeks,
/// snaps, swings and draws the loupe through it, so a carriage seeks exactly as a pivoted arm does.
///
/// A side maps to the record's radius linearly, from the outer groove (fraction 0) to the inner one (1): a groove of
/// even pitch moves the needle inward at a steady rate, so the radius, not the arm's angle, keeps time.
public struct ArmTravel: Sendable, Equatable {
    public enum Arm: Sendable, Equatable {
        case pivoted(PivotedArm)
        case linear(LinearArm)
    }

    public let arm: Arm
    public let rest: Double
    public let leadIn: Double
    public let runout: Double

    /// A pivoted arm parked at `restAngle`, sweeping from the outer groove to the inner one.
    public init(pivoted arm: PivotedArm, restAngle: Double) {
        self.arm = .pivoted(arm)
        rest = restAngle
        leadIn = arm.angle(forRadius: arm.recordRadius * VinylGeometry.outerGrooveToRecord)
        runout = arm.angle(forRadius: arm.recordRadius * VinylGeometry.innerGrooveToRecord)
    }

    /// A linear carriage parked at its rest radius.
    public init(linear arm: LinearArm) {
        self.arm = .linear(arm)
        rest = 0
        leadIn = arm.restRadius - arm.recordRadius * VinylGeometry.outerGrooveToRecord
        runout = arm.restRadius - arm.recordRadius * VinylGeometry.innerGrooveToRecord
    }

    public var recordRadius: Double {
        switch arm {
        case .pivoted(let a): a.recordRadius
        case .linear(let a): a.recordRadius
        }
    }

    public var spindle: CGPoint {
        switch arm {
        case .pivoted(let a): a.spindle
        case .linear(let a): a.spindle
        }
    }

    /// The groove radius for `fraction` of the side (0 = lead-in, 1 = run-out), clamped to the grooves.
    public func radius(forFraction fraction: Double) -> Double {
        let f = min(max(fraction, 0), 1)
        let outer = VinylGeometry.outerGrooveToRecord
        let inner = VinylGeometry.innerGrooveToRecord
        return recordRadius * (outer - (outer - inner) * f)
    }

    /// The position that puts the stylus `radius` from the spindle.
    public func position(forRadius radius: Double) -> Double {
        switch arm {
        case .pivoted(let a): a.angle(forRadius: radius)
        case .linear(let a): a.restRadius - radius
        }
    }

    /// The stylus's distance from the spindle at `position`.
    public func radius(at position: Double) -> Double {
        switch arm {
        case .pivoted(let a): a.radius(atAngle: position)
        case .linear(let a): a.restRadius - position
        }
    }

    /// The position for `fraction` of the side (0 = lead-in, 1 = run-out).
    public func position(forFraction fraction: Double) -> Double {
        position(forRadius: radius(forFraction: fraction))
    }

    /// The fraction of the side under the needle at `position`, clamped to the grooves.
    public func fraction(forPosition position: Double) -> Double {
        let outer = recordRadius * VinylGeometry.outerGrooveToRecord
        let inner = recordRadius * VinylGeometry.innerGrooveToRecord
        return min(max((outer - radius(at: position)) / (outer - inner), 0), 1)
    }

    /// The stylus at `position`.
    public func needle(at position: Double) -> CGPoint {
        switch arm {
        case .pivoted(let a): a.needle(atAngle: position)
        case .linear(let a): a.stylus(atRadius: a.restRadius - position)
        }
    }

    /// The position a finger at `point` asks for, unclamped.
    public func position(toward point: CGPoint) -> Double {
        switch arm {
        case .pivoted(let a): a.angle(toward: point)
        case .linear(let a): a.restRadius - a.radius(toward: point)
        }
    }

    /// `position`, kept between the rest and the run-out.
    public func clamped(_ position: Double) -> Double {
        min(max(position, rest), runout)
    }
}
