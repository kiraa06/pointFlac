import CoreGraphics
import Foundation
import Testing

@testable import PFDesign

@Suite("Deck arm geometry")
struct DeckArmGeometryTests {
    /// A real 9-inch arm in millimetres: the spindle at the origin, a 151 mm record radius, and the pivot 215 mm away,
    /// up and to the right, as on a deck seen from above (y grows downward, as on screen).
    static let realArm = PivotedArm(
        spindle: .zero, recordRadius: 151, pivot: CGPoint(x: 215 * cos(-0.62), y: 215 * sin(-0.62)))
    /// The phone deck's proportions in points.
    static let phoneArm = PivotedArm(
        spindle: CGPoint(x: 162, y: 162), recordRadius: 130, pivot: CGPoint(x: 336, y: 38))

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    @Test("the pivoted arm's needle lands on the outer and inner grooves", arguments: [realArm, phoneArm])
    func pivotedLandsOnTheGrooves(arm: PivotedArm) {
        let travel = ArmTravel(pivoted: arm, restAngle: 0)
        let r = arm.recordRadius
        let leadIn = Self.distance(arm.needle(atAngle: travel.leadIn), arm.spindle)
        let runout = Self.distance(arm.needle(atAngle: travel.runout), arm.spindle)
        #expect(abs(leadIn - r * VinylGeometry.outerGrooveToRecord) < r * 0.005)
        #expect(abs(runout - r * VinylGeometry.innerGrooveToRecord) < r * 0.005)
        // The same through the travel's own maps, from the side's start and end.
        #expect(
            abs(travel.radius(at: travel.position(forFraction: 0)) - r * VinylGeometry.outerGrooveToRecord) < r * 0.005)
        #expect(
            abs(travel.radius(at: travel.position(forFraction: 1)) - r * VinylGeometry.innerGrooveToRecord) < r * 0.005)
        // Swinging in: the lead-in comes after the rest, the run-out after the lead-in.
        #expect(travel.rest < travel.leadIn && travel.leadIn < travel.runout)
    }

    @Test("arm length is the pivot-to-spindle distance plus the overhang", arguments: [realArm, phoneArm])
    func lengthIsDistancePlusOverhang(arm: PivotedArm) {
        let distance = Self.distance(arm.pivot, arm.spindle)
        #expect(abs(arm.pivotDistance - distance) < 1e-9)
        #expect(abs(arm.length - (distance + VinylGeometry.overhangToRecord * arm.recordRadius)) < 1e-9)
        // The stylus really is that far from the pivot, at any angle.
        for angle in stride(from: -10.0, through: 60, by: 7) {
            #expect(abs(Self.distance(arm.needle(atAngle: angle), arm.pivot) - arm.length) < 1e-9)
        }
    }

    @Test("the headshell turns by the offset angle, toward the spindle", arguments: [realArm, phoneArm])
    func headshellOffsetTowardTheSpindle(arm: PivotedArm) {
        let travel = ArmTravel(pivoted: arm, restAngle: 0)
        for fraction in stride(from: 0.0, through: 1, by: 0.25) {
            let angle = travel.position(forFraction: fraction)
            let head = arm.headshellAngle(atAngle: angle)
            #expect(abs(abs(head - angle) - VinylGeometry.offsetAngleDegrees) < 1e-9)
            // Directions in the arm's convention: 0° hangs straight down, positive swings clockwise on screen.
            func direction(_ degrees: Double) -> CGVector {
                let r = degrees * .pi / 180
                return CGVector(dx: -sin(r), dy: cos(r))
            }
            let needle = arm.needle(atAngle: angle)
            let toSpindle = CGVector(dx: arm.spindle.x - needle.x, dy: arm.spindle.y - needle.y)
            func turn(_ v: CGVector) -> Double {
                acos(
                    (v.dx * toSpindle.dx + v.dy * toSpindle.dy) / hypot(v.dx, v.dy) / hypot(toSpindle.dx, toSpindle.dy))
            }
            #expect(turn(direction(head)) < turn(direction(angle)))
        }
    }

    @Test("a pivoted arm's fraction and angle are inverses, and the needle moves inward as the side plays")
    func pivotedMapsRoundTrip() {
        let arm = Self.phoneArm
        let travel = ArmTravel(pivoted: arm, restAngle: 2)
        var last = Double.infinity
        for fraction in stride(from: 0.0, through: 1, by: 0.05) {
            let position = travel.position(forFraction: fraction)
            #expect(abs(travel.fraction(forPosition: position) - fraction) < 1e-6)
            let radius = travel.radius(at: position)
            #expect(radius < last)
            last = radius
        }
        // Off the grooves, the fraction clamps.
        #expect(travel.fraction(forPosition: travel.rest) == 0)
        #expect(travel.fraction(forPosition: travel.runout + 5) == 1)
        // A finger on the needle points the arm at its own angle.
        let angle = travel.position(forFraction: 0.4)
        #expect(abs(travel.position(toward: arm.needle(atAngle: angle)) - angle) < 1e-6)
    }

    @Test("the linear arm runs from the outer groove at 0 to the inner groove at 1, monotonically")
    func linearMapsFractionToRadius() {
        let arm = LinearArm(spindle: CGPoint(x: 162, y: 162), recordRadius: 130, direction: 0, restRadius: 160)
        let travel = ArmTravel(linear: arm)
        let r = arm.recordRadius
        #expect(abs(travel.radius(at: travel.position(forFraction: 0)) - r * VinylGeometry.outerGrooveToRecord) < 1e-9)
        #expect(abs(travel.radius(at: travel.position(forFraction: 1)) - r * VinylGeometry.innerGrooveToRecord) < 1e-9)
        var lastRadius = Double.infinity
        var lastPosition = -Double.infinity
        for fraction in stride(from: 0.0, through: 1, by: 0.05) {
            let position = travel.position(forFraction: fraction)
            let radius = travel.radius(at: position)
            #expect(radius < lastRadius)
            #expect(position > lastPosition)
            #expect(abs(travel.fraction(forPosition: position) - fraction) < 1e-9)
            lastRadius = radius
            lastPosition = position
        }
        // The carriage parks off the record, and the stylus rides the rail's radius.
        #expect(travel.radius(at: travel.rest) == 160)
        #expect(travel.rest < travel.leadIn && travel.leadIn < travel.runout)
        let stylus = travel.needle(at: travel.position(forFraction: 0.5))
        #expect(abs(stylus.y - 162) < 1e-9)
        #expect(stylus.x > 162)
        // A finger anywhere beside the rail moves the carriage to its projection.
        let finger = CGPoint(x: 162 + r * 0.7, y: 140)
        #expect(abs(travel.radius(at: travel.position(toward: finger)) - r * 0.7) < 1e-9)
    }
}
