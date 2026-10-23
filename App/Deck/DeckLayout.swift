import PFDesign
import SwiftUI

/// The plinth's geometry, from its size and design: where the record, platter, pivot (or rail) and needle are, all in
/// a 12-inch LP's real proportions (`VinylGeometry`). The arm's travel is solved so the needle sits exactly on the
/// outer groove at the lead-in and on the inner groove at the run-out.
///
/// The record's size depends only on the plinth's width, never on the design: the hand-off measures the platter
/// before it knows which design will draw it, and a record must land the same size on every deck.
struct DeckLayout: Equatable {
    let size: CGSize
    let design: DeckDesign
    let recordCenter: CGPoint
    let recordRadius: CGFloat
    /// The platter, a little wider than the record (a mass-loaded one a little less so).
    let platterRadius: CGFloat
    /// The needle's travel across a side, whatever the arm.
    let travel: ArmTravel

    init(size: CGSize, design: DeckDesign = .standard) {
        self.size = size
        self.design = design
        let w = size.width
        let pad = w * 0.05
        let platter = max(40, min(w * 0.76, size.height - pad - Self.screenBand))
        let radius = platter / 2 / VinylGeometry.platterToRecord
        recordRadius = radius
        recordCenter = CGPoint(x: pad + platter / 2, y: pad + platter / 2)
        platterRadius =
            radius
            * (design.platter == .massBlack ? VinylGeometry.massPlatterToRecord : VinylGeometry.platterToRecord)
        if design.armStyle == .linear {
            // The rail runs out along the 3 o'clock radius to a pillar on the right; the carriage parks just off the
            // platter.
            let arm = LinearArm(
                spindle: recordCenter, recordRadius: radius, direction: 0,
                restRadius: platterRadius + radius * 0.07)
            travel = ArmTravel(linear: arm)
        } else {
            // The pivot sits at the rear right, about 1.45 record radii from the spindle and 28° above the line
            // across the deck: a 9-inch arm's 215 mm on a 151 mm radius, clear of the platter.
            let reach = radius * 1.45
            let tilt = 28.0 * .pi / 180
            let pivot = CGPoint(x: recordCenter.x + reach * cos(tilt), y: recordCenter.y - reach * sin(tilt))
            let arm = PivotedArm(spindle: recordCenter, recordRadius: radius, pivot: pivot)
            // At rest the arm lies in its rest, swung a touch in from straight down, with the headshell well off
            // the platter.
            travel = ArmTravel(pivoted: arm, restAngle: 3)
        }
    }

    /// Room under the platter for the dot-matrix screen and the front controls.
    static let screenBand: CGFloat = 58

    /// The plinth's height for a width: the platter, its margin, and the screen's band.
    static func height(forWidth w: CGFloat) -> CGFloat {
        w * 0.05 + w * 0.76 + screenBand
    }

    /// The pivoted arm, if this deck has one.
    var pivoted: PivotedArm? {
        if case .pivoted(let arm) = travel.arm { return arm }
        return nil
    }

    /// The linear arm, if this deck has one.
    var linear: LinearArm? {
        if case .linear(let arm) = travel.arm { return arm }
        return nil
    }

    func needle(at position: Double) -> CGPoint {
        travel.needle(at: position)
    }

    /// The front band under the platter: its controls sit left of the display.
    var frontBand: CGRect {
        CGRect(x: 0, y: size.height - Self.screenBand, width: size.width, height: Self.screenBand)
    }

    /// The front band's free space, left of the display.
    var frontControls: CGRect {
        let display = DeckScreen.frame(in: size)
        let x = size.width * 0.045
        return CGRect(x: x, y: frontBand.minY + 6, width: display.minX - x - 10, height: Self.screenBand - 12)
    }
}
