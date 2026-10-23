import PFDesign
import SwiftUI

/// The arm's height over the record, 0 (stylus down) to 1 (lifted), over time: the cue's damped descent, slow and
/// easing in to the groove, and a quicker lift. Analytic in time, like `SpinModel`, so it is exact at any frame rate.
struct LiftModel: Equatable {
    private var from: Double = 1
    private var to: Double = 1
    private var start: Double = 0
    private var duration: Double = 0

    /// Lowering takes a beat, as a damped cue lever does; lifting is quick.
    static let lowerSeconds = 0.9
    static let raiseSeconds = 0.25

    func value(at t: Double) -> Double {
        guard duration > 0 else { return to }
        let x = min(max((t - start) / duration, 0), 1)
        // Down: ease out, so the stylus settles gently. Up: ease in and out.
        let eased = to < from ? 1 - pow(1 - x, 3) : x * x * (3 - 2 * x)
        return from + (to - from) * eased
    }

    func isSettled(at t: Double) -> Bool { duration == 0 || t >= start + duration }

    /// Lowers or lifts from wherever the arm is at `t`; at once under Reduce Motion.
    mutating func set(down: Bool, at t: Double, animated: Bool) {
        let target = down ? 0.0 : 1.0
        guard target != to else { return }
        let current = value(at: t)
        from = current
        to = target
        start = t
        duration = animated ? abs(target - current) * (down ? Self.lowerSeconds : Self.raiseSeconds) : 0
    }
}

/// The pivoted arm's proportions, from the record's radius: a 9-inch arm's headshell, cartridge, counterweight and
/// tube, scaled to the record on screen.
struct ArmMetrics {
    let length: CGFloat
    let r: CGFloat
    let offset: Double

    init(arm: PivotedArm) {
        length = arm.length
        r = arm.recordRadius
        offset = arm.offsetDegrees * .pi / 180
    }

    var tube: CGFloat { max(4, r * 0.04) }
    /// Behind the pivot, to the counterweight's far end.
    var back: CGFloat { r * 0.31 }
    /// The drawing's frame: the pivot at (width / 2, top).
    var top: CGFloat { back + 8 }
    var width: CGFloat { r * 0.7 }
    var height: CGFloat { top + length + r * 0.1 }
    var pivot: CGPoint { CGPoint(x: width / 2, y: top) }
    /// The headshell's axis, toward the stylus, and the side away from the spindle (where the finger lift is).
    var forward: CGVector { CGVector(dx: -sin(offset), dy: cos(offset)) }
    var outward: CGVector { CGVector(dx: cos(offset), dy: sin(offset)) }
    var stylus: CGPoint { CGPoint(x: pivot.x, y: pivot.y + length) }

    /// A point `along` the headshell's axis from the stylus (negative is back toward the arm) and `across` it
    /// (positive is away from the spindle).
    func head(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
        CGPoint(
            x: stylus.x + forward.dx * along + outward.dx * across,
            y: stylus.y + forward.dy * along + outward.dy * across)
    }

    /// Where the tube meets the headshell.
    var collar: CGPoint { head(-r * 0.3, 0) }
    /// The headshell's centre, where a finger takes the arm.
    var grip: CGPoint { head(-r * 0.13, 0) }
}

/// A pivoted arm (S, J or straight) hanging straight down from its pivot: the tube, the counterweight behind the
/// pivot with its scale ring, the headshell turned toward the spindle by the offset angle with its finger lift, and
/// the cartridge with its stylus. The deck rotates it about the pivot; drawn once. `silhouette` draws it in black,
/// softened by `blur`, for its shadow: the deck crossfades a tight and a soft one as the arm lifts, so no blur runs
/// per frame.
struct ArmBody: View, Equatable {
    let paint: DeckPaint
    let arm: PivotedArm
    let silhouette: Bool
    var blur: CGFloat = 0

    var body: some View {
        let m = ArmMetrics(arm: arm)
        Canvas { context, _ in
            if blur > 0 { context.addFilter(.blur(radius: blur)) }
            draw(&context, m)
        }
        .frame(width: m.width, height: m.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tubePath(_ m: ArmMetrics) -> Path {
        let p = m.pivot
        let b = m.collar
        var path = Path()
        path.move(to: CGPoint(x: p.x, y: p.y - m.r * 0.12))
        path.addLine(to: p)
        switch paint.design.armStyle {
        case .sShaped:
            // Out of the pivot along the arm's line, a gentle bow toward the spindle, then back out to meet the
            // headshell square on: the S that sets the offset without a cranked headshell.
            path.addCurve(
                to: b,
                control1: CGPoint(x: p.x - m.length * 0.075, y: p.y + m.length * 0.42),
                control2: CGPoint(x: b.x - m.forward.dx * m.length * 0.26, y: b.y - m.forward.dy * m.length * 0.26))
        case .jShaped:
            // Straight out of the pivot, then one tight bend into the headshell near the end.
            let bend = CGPoint(x: b.x - m.forward.dx * m.length * 0.2, y: b.y - m.forward.dy * m.length * 0.2)
            let straightEnd = CGPoint(x: p.x + (bend.x - p.x) * 0.8, y: p.y + (bend.y - p.y) * 0.8)
            path.addLine(to: straightEnd)
            path.addQuadCurve(to: b, control: bend)
        case .straight, .linear:
            path.addLine(to: b)
        }
        return path
    }

    private func draw(_ context: inout GraphicsContext, _ m: ArmMetrics) {
        let metal = paint.armMetal
        let tube = tubePath(m)
        let shade: GraphicsContext.Shading = .color(.black)
        // The tube: body, a bright line on its lit side and a dark one on the far side.
        context.stroke(
            tube, with: silhouette ? shade : .color(metal.body), style: StrokeStyle(lineWidth: m.tube, lineCap: .round))
        if !silhouette {
            var lit = context
            lit.translateBy(x: -m.tube * 0.2, y: -m.tube * 0.12)
            lit.stroke(tube, with: .color(metal.light), style: StrokeStyle(lineWidth: m.tube * 0.32, lineCap: .round))
            var dim = context
            dim.translateBy(x: m.tube * 0.26, y: m.tube * 0.1)
            dim.stroke(tube, with: .color(metal.shade.opacity(0.8)), style: StrokeStyle(lineWidth: m.tube * 0.22))
        }
        counterweight(&context, m, metal)
        headshell(&context, m, metal)
    }

    private func counterweight(_ context: inout GraphicsContext, _ m: ArmMetrics, _ metal: DeckPaint.Metal) {
        let w = m.r * 0.25
        let length = m.r * 0.17
        let rect = CGRect(x: m.pivot.x - w / 2, y: m.pivot.y - m.back, width: w, height: length)
        let body = Path(roundedRect: rect, cornerRadius: w * 0.16)
        if silhouette {
            context.fill(body, with: .color(.black))
            return
        }
        let cylinder: GraphicsContext.Shading = .linearGradient(
            metal.cylinder, startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0))
        context.fill(body, with: cylinder)
        // Knurled grip at the back, the scale ring at the front with its fine marks, and the end face's edge.
        var ribs = Path()
        var x = rect.minX + 1.2
        while x < rect.maxX - 1 {
            ribs.move(to: CGPoint(x: x, y: rect.minY + 1))
            ribs.addLine(to: CGPoint(x: x, y: rect.minY + length * 0.55))
            x += 1.3
        }
        context.stroke(ribs, with: .color(.black.opacity(0.22)), lineWidth: 0.45)
        let ring = CGRect(x: rect.minX, y: rect.maxY - length * 0.3, width: w, height: length * 0.3)
        context.fill(Path(ring), with: .color(.black.opacity(0.55)))
        var marks = Path()
        for i in 0...10 {
            let mx = ring.minX + ring.width * (0.12 + 0.76 * CGFloat(i) / 10)
            marks.move(to: CGPoint(x: mx, y: ring.minY + 0.6))
            marks.addLine(to: CGPoint(x: mx, y: ring.minY + (i % 5 == 0 ? ring.height * 0.75 : ring.height * 0.45)))
        }
        context.stroke(marks, with: .color(.white.opacity(0.75)), lineWidth: 0.4)
        context.stroke(body, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
    }

    private func headshell(_ context: inout GraphicsContext, _ m: ArmMetrics, _ metal: DeckPaint.Metal) {
        let r = m.r
        let half = r * 0.068
        // The plate, from the collar to just short of the cartridge's nose, tapering a little toward the front.
        var plate = Path()
        plate.move(to: m.head(-r * 0.3, -half * 0.8))
        plate.addLine(to: m.head(-r * 0.05, -half))
        plate.addQuadCurve(to: m.head(-r * 0.03, 0), control: m.head(-r * 0.03, -half))
        plate.addQuadCurve(to: m.head(-r * 0.05, half), control: m.head(-r * 0.03, half))
        plate.addLine(to: m.head(-r * 0.3, half * 0.8))
        plate.closeSubpath()
        // The cartridge: its coloured body under the plate, the nose showing in front, the stylus at its tip.
        let cartridgeHalf = r * 0.052
        var cartridge = Path()
        cartridge.move(to: m.head(-r * 0.19, -cartridgeHalf))
        cartridge.addLine(to: m.head(r * 0.022, -cartridgeHalf))
        cartridge.addLine(to: m.head(r * 0.03, -cartridgeHalf * 0.6))
        cartridge.addLine(to: m.head(r * 0.03, cartridgeHalf * 0.6))
        cartridge.addLine(to: m.head(r * 0.022, cartridgeHalf))
        cartridge.addLine(to: m.head(-r * 0.19, cartridgeHalf))
        cartridge.closeSubpath()
        // The finger lift: a slim bent tab off the outer side, toward the front.
        var lift = Path()
        lift.move(to: m.head(-r * 0.08, half * 0.9))
        lift.addQuadCurve(to: m.head(-r * 0.115, half + r * 0.085), control: m.head(-r * 0.05, half + r * 0.06))
        lift.addQuadCurve(to: m.head(-r * 0.15, half + r * 0.07), control: m.head(-r * 0.14, half + r * 0.1))
        // The locking collar where the headshell plugs into the tube: a short knurled ring square to the headshell.
        let collarTransform = CGAffineTransform(translationX: m.collar.x, y: m.collar.y).rotated(by: m.offset)
        let collarRect = CGRect(x: -half * 0.78, y: -r * 0.03, width: half * 1.56, height: r * 0.05)
        let collar = Path(roundedRect: collarRect, cornerRadius: r * 0.012).applying(collarTransform)
        if silhouette {
            context.fill(cartridge, with: .color(.black))
            context.fill(plate, with: .color(.black))
            context.stroke(
                lift, with: .color(.black), style: StrokeStyle(lineWidth: max(1.2, r * 0.013), lineCap: .round))
            context.fill(collar, with: .color(.black))
            return
        }
        context.fill(cartridge, with: .color(paint(paint.design.cartridge)))
        context.stroke(cartridge, with: .color(.black.opacity(0.45)), lineWidth: 0.5)
        // The cartridge's lit top edge.
        var edge = Path()
        edge.move(to: m.head(-r * 0.17, -cartridgeHalf * 0.75))
        edge.addLine(to: m.head(r * 0.018, -cartridgeHalf * 0.75))
        context.stroke(edge, with: .color(.white.opacity(0.28)), lineWidth: 0.7)
        context.fill(
            plate,
            with: .linearGradient(
                metal.cylinder, startPoint: m.head(-r * 0.15, -half), endPoint: m.head(-r * 0.15, half)))
        context.stroke(plate, with: .color(.black.opacity(0.4)), lineWidth: 0.5)
        // Two mounting screws, half an inch apart, through the plate.
        for along in [-r * 0.15, -r * 0.065] {
            let s = m.head(along, 0)
            let screw = Path(
                ellipseIn: CGRect(x: s.x - r * 0.014, y: s.y - r * 0.014, width: r * 0.028, height: r * 0.028))
            context.fill(screw, with: .color(metal.shade))
            context.stroke(screw, with: .color(.white.opacity(0.35)), lineWidth: 0.3)
        }
        context.stroke(
            lift, with: .color(metal.body), style: StrokeStyle(lineWidth: max(1.4, r * 0.014), lineCap: .round))
        context.stroke(
            lift, with: .color(metal.light), style: StrokeStyle(lineWidth: max(0.5, r * 0.005), lineCap: .round))
        context.fill(
            collar,
            with: .linearGradient(
                metal.cylinder, startPoint: m.head(-r * 0.3, -half * 0.78), endPoint: m.head(-r * 0.3, half * 0.78)))
        var knurl = Path()
        for i in 1..<7 {
            let across = -half * 0.78 + half * 1.56 * CGFloat(i) / 7
            knurl.move(to: CGPoint(x: across, y: collarRect.minY + 0.6))
            knurl.addLine(to: CGPoint(x: across, y: collarRect.maxY - 0.6))
        }
        context.stroke(knurl.applying(collarTransform), with: .color(.black.opacity(0.25)), lineWidth: 0.4)
        context.stroke(collar, with: .color(.black.opacity(0.4)), lineWidth: 0.5)
        // The stylus: a speck of diamond on its cantilever, just ahead of the body.
        var cantilever = Path()
        cantilever.move(to: m.head(r * 0.012, 0))
        cantilever.addLine(to: m.head(r * 0.034, 0))
        context.stroke(cantilever, with: .color(Color(white: 0.85)), lineWidth: 0.7)
        let tip = m.head(r * 0.036, 0)
        context.fill(
            Path(ellipseIn: CGRect(x: tip.x - 0.7, y: tip.y - 0.7, width: 1.4, height: 1.4)), with: .color(.white))
    }
}

/// What the pivoted arm stands on, which does not swing: the base ring, the anti-skate dial with its scale, the
/// cue lever's base and the arm rest, set along the arm's parked line just off the platter.
struct ArmFurniture: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout

    var body: some View {
        Canvas { context, _ in
            // A linear deck's rail bridges over the record, so it is drawn above it (`LinearRailView`).
            if let arm = layout.pivoted { pivoted(&context, arm) }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pivoted(_ context: inout GraphicsContext, _ arm: PivotedArm) {
        let r = arm.recordRadius
        let p = arm.pivot
        let metal = paint.armMetal
        // The base: a dark collar set into the plinth, with a turned metal ring on top.
        let base = r * 0.165
        var shadow = context
        shadow.addFilter(.blur(radius: 3))
        shadow.fill(
            Path(ellipseIn: CGRect(x: p.x - base + 2, y: p.y - base + 3, width: base * 2, height: base * 2)),
            with: .color(.black.opacity(0.45)))
        context.fill(
            Path(ellipseIn: CGRect(x: p.x - base, y: p.y - base, width: base * 2, height: base * 2)),
            with: .radialGradient(
                Gradient(colors: [paint(0x2A2C30), paint(0x121315)]), center: p, startRadius: 0, endRadius: base))
        let ring = base * 0.86
        context.stroke(
            Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
            with: .conicGradient(
                Gradient(colors: [metal.light, metal.shade, metal.body, metal.light, metal.shade, metal.light]),
                center: p, angle: .degrees(200)), lineWidth: base * 0.16)
        // Height-adjust marks round the ring.
        var marks = Path()
        for i in 0..<36 {
            let a = Double(i) / 36 * 2 * .pi
            marks.move(to: CGPoint(x: p.x + cos(a) * base * 0.72, y: p.y + sin(a) * base * 0.72))
            marks.addLine(
                to: CGPoint(
                    x: p.x + cos(a) * base * (i % 6 == 0 ? 0.6 : 0.66),
                    y: p.y + sin(a) * base * (i % 6 == 0 ? 0.6 : 0.66)))
        }
        context.stroke(marks, with: .color(.white.opacity(0.45)), lineWidth: 0.4)
        // The anti-skate dial, rear left of the pivot, with its 0–5 scale.
        let dial = CGPoint(x: p.x - r * 0.25, y: p.y - r * 0.17)
        let dialRadius = r * 0.05
        var scale = Path()
        for i in 0...10 {
            let a = (150 + Double(i) * 24) * .pi / 180
            let long = i % 2 == 0
            scale.move(to: CGPoint(x: dial.x + cos(a) * dialRadius * 1.25, y: dial.y + sin(a) * dialRadius * 1.25))
            scale.addLine(
                to: CGPoint(
                    x: dial.x + cos(a) * dialRadius * (long ? 1.6 : 1.45),
                    y: dial.y + sin(a) * dialRadius * (long ? 1.6 : 1.45)))
        }
        context.stroke(scale, with: .color(Self.markInk(paint).opacity(0.6)), lineWidth: 0.45)
        context.knob(center: dial, radius: dialRadius, metal: metal, pointer: paint.accent, pointing: 150 + 4 * 24)
        // The cue lever's base, front right of the pivot.
        let lever = Self.cueLeverBase(arm)
        context.fill(
            Path(roundedRect: lever.offsetBy(dx: 0.6, dy: 1), cornerRadius: lever.width / 2),
            with: .color(.black.opacity(0.35)))
        context.fill(Path(roundedRect: lever, cornerRadius: lever.width / 2), with: .color(paint(0x17181B)))
        context.stroke(
            Path(roundedRect: lever, cornerRadius: lever.width / 2), with: .color(.white.opacity(0.18)), lineWidth: 0.5)
        // The arm rest: a short post with a rubber-lined cradle across the parked tube, and the clip that holds it.
        let rest = Self.restPost(layout, arm)
        let post = r * 0.04
        let angle = layout.travel.rest * .pi / 180
        let cradle = CGRect(x: -post * 1.9, y: -post * 0.75, width: post * 3.8, height: post * 1.5)
        let place = CGAffineTransform(translationX: rest.x, y: rest.y).rotated(by: angle)
        var postShadow = context
        postShadow.addFilter(.blur(radius: 2.2))
        postShadow.fill(
            Path(roundedRect: cradle, cornerRadius: post * 0.75).applying(place.translatedBy(x: 2.5, y: 3.5)),
            with: .color(.black.opacity(0.4)))
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: rest.x - post * 1.25, y: rest.y - post * 1.25, width: post * 2.5, height: post * 2.5)),
            with: .color(paint(0x141517)))
        context.fill(
            Path(roundedRect: cradle, cornerRadius: post * 0.75).applying(place),
            with: .linearGradient(
                metal.cylinder, startPoint: CGPoint(x: rest.x, y: rest.y - post),
                endPoint: CGPoint(x: rest.x, y: rest.y + post)))
        let pad = cradle.insetBy(dx: post * 0.9, dy: post * 0.28)
        context.fill(
            Path(roundedRect: pad, cornerRadius: pad.height / 2).applying(place), with: .color(paint(0x1A1A1C)))
        context.stroke(
            Path(roundedRect: cradle, cornerRadius: post * 0.75).applying(place), with: .color(.black.opacity(0.4)),
            lineWidth: 0.5)
        // The clip, hinged on the outer side.
        var clip = Path()
        clip.move(to: CGPoint(x: cradle.maxX - post * 0.2, y: 0))
        clip.addQuadCurve(
            to: CGPoint(x: cradle.maxX + post * 0.9, y: -post * 0.9),
            control: CGPoint(x: cradle.maxX + post * 0.8, y: 0))
        context.stroke(
            clip.applying(place), with: .color(metal.body),
            style: StrokeStyle(lineWidth: max(1, post * 0.3), lineCap: .round))
    }

    /// Engraving on the plinth: dark on pale finishes, light on dark ones.
    static func markInk(_ paint: DeckPaint) -> Color {
        switch paint.design.plinth {
        case .brushedMetal, .lacquer: .black
        case .frostedGlass: paint.dark ? .white : .black
        default: .white
        }
    }

    static func cueLeverBase(_ arm: PivotedArm) -> CGRect {
        let r = arm.recordRadius
        return CGRect(x: arm.pivot.x + r * 0.17, y: arm.pivot.y + r * 0.12, width: r * 0.075, height: r * 0.22)
    }

    static func restPost(_ layout: DeckLayout, _ arm: PivotedArm) -> CGPoint {
        let a = layout.travel.rest * .pi / 180
        let along = arm.length * 0.66
        return CGPoint(x: arm.pivot.x - along * sin(a), y: arm.pivot.y + along * cos(a))
    }
}

/// The cue lever's handle, which rides up its base as the arm lifts.
struct CueLever: View {
    let paint: DeckPaint
    let arm: PivotedArm
    let lift: Double

    var body: some View {
        let base = ArmFurniture.cueLeverBase(arm)
        let r = arm.recordRadius
        let metal = paint.armMetal
        RoundedRectangle(cornerRadius: r * 0.015)
            .fill(LinearGradient(gradient: metal.cylinder, startPoint: .leading, endPoint: .trailing))
            .overlay(RoundedRectangle(cornerRadius: r * 0.015).strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
            .frame(width: r * 0.11, height: r * 0.05)
            .shadow(color: .black.opacity(0.4), radius: 1, x: 0.5, y: 1)
            .position(x: base.midX, y: base.maxY - r * 0.04 - (base.height - r * 0.08) * lift)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The pivot's cap, over the swinging arm: a domed gimbal cover whose highlight stays to the lamp.
struct ArmCap: View, Equatable {
    let paint: DeckPaint
    let arm: PivotedArm

    var body: some View {
        let r = arm.recordRadius * 0.092
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let metal = paint.armMetal
            var shadow = context
            shadow.addFilter(.blur(radius: 1.5))
            shadow.fill(
                Path(ellipseIn: CGRect(x: c.x - r + 1, y: c.y - r + 1.6, width: r * 2, height: r * 2)),
                with: .color(.black.opacity(0.45)))
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: metal.dome(center: c, radius: r))
            let inner = r * 0.45
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)),
                with: .color(.black.opacity(0.3)))
            let boss = r * 0.24
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - boss, y: c.y - boss, width: boss * 2, height: boss * 2)),
                with: metal.dome(center: c, radius: boss))
        }
        .frame(width: r * 3, height: r * 3)
        .position(arm.pivot)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The linear tracker's rail and pillar, over the record and under the carriage. Drawn once.
struct LinearRailView: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout

    var body: some View {
        Canvas { context, _ in
            if let arm = layout.linear { LinearRail.draw(&context, paint: paint, arm: arm, layout: layout) }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The linear tracker: a rail that bridges out over the record along the 3 o'clock radius from a pillar on the
/// right, a carriage that rides it, and a short arm down to the cartridge, square to the groove.
enum LinearRail {
    /// How far the rail runs above the radius the stylus tracks.
    static func railOffset(_ r: CGFloat) -> CGFloat { r * 0.15 }

    static func railRect(_ arm: LinearArm, _ layout: DeckLayout) -> CGRect {
        let r = arm.recordRadius
        let y = arm.spindle.y - railOffset(r)
        let x0 = arm.spindle.x + r * VinylGeometry.innerGrooveToRecord - r * 0.13
        let x1 = min(layout.size.width - r * 0.1, arm.spindle.x + arm.restRadius + r * 0.2)
        return CGRect(x: x0, y: y - r * 0.036, width: x1 - x0, height: r * 0.072)
    }

    static func draw(_ context: inout GraphicsContext, paint: DeckPaint, arm: LinearArm, layout: DeckLayout) {
        let r = arm.recordRadius
        let metal = paint.armMetal
        let rail = railRect(arm, layout)
        let pillar = CGRect(x: rail.maxX - r * 0.06, y: rail.midY - r * 0.16, width: r * 0.15, height: r * 0.32)
        // Shadows: the rail floats over the record, so its shadow falls a little way down and right.
        var shadow = context
        shadow.addFilter(.blur(radius: 3))
        shadow.fill(
            Path(roundedRect: rail.offsetBy(dx: 3, dy: 6), cornerRadius: rail.height / 2),
            with: .color(.black.opacity(0.4)))
        shadow.fill(
            Path(roundedRect: pillar.offsetBy(dx: 2, dy: 3), cornerRadius: 3), with: .color(.black.opacity(0.5)))
        context.fill(
            Path(roundedRect: pillar, cornerRadius: 3),
            with: .linearGradient(
                Gradient(colors: [metal.light, metal.body, metal.shade]),
                startPoint: CGPoint(x: pillar.minX, y: pillar.minY),
                endPoint: CGPoint(x: pillar.maxX, y: pillar.maxY)))
        context.stroke(Path(roundedRect: pillar, cornerRadius: 3), with: .color(.black.opacity(0.4)), lineWidth: 0.5)
        let bar = Path(roundedRect: rail, cornerRadius: rail.height / 2)
        context.fill(
            bar,
            with: .linearGradient(
                metal.cylinder, startPoint: CGPoint(x: 0, y: rail.minY), endPoint: CGPoint(x: 0, y: rail.maxY)))
        // The slot the carriage runs in.
        context.fill(
            Path(
                CGRect(
                    x: rail.minX + rail.height * 0.6, y: rail.midY - 0.5, width: rail.width - rail.height * 1.2,
                    height: 1)),
            with: .color(.black.opacity(0.6)))
        context.stroke(bar, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
        // The end cap over the record, with a small accent mark: the one bit of colour on the arm.
        let cap = CGRect(x: rail.minX, y: rail.minY, width: rail.height, height: rail.height)
        context.fill(
            Path(ellipseIn: cap.insetBy(dx: rail.height * 0.3, dy: rail.height * 0.3)),
            with: .color(paint.accent.opacity(0.85)))
    }
}

/// The linear tracker's carriage and short arm, drawn once and slid along the rail. `silhouette` draws it black,
/// for its shadow. The frame is centred on the stylus.
struct CarriageBody: View, Equatable {
    let paint: DeckPaint
    let arm: LinearArm
    let silhouette: Bool
    var blur: CGFloat = 0

    static func size(_ r: CGFloat) -> CGSize { CGSize(width: r * 0.3 + 16, height: r * 0.44 + 16) }

    var body: some View {
        let r = arm.recordRadius
        let size = Self.size(r)
        Canvas { context, size in
            if blur > 0 { context.addFilter(.blur(radius: blur)) }
            let s = CGPoint(x: size.width / 2, y: size.height / 2)
            let metal = paint.armMetal
            let railY = s.y - LinearRail.railOffset(r)
            let carriage = CGRect(x: s.x - r * 0.1, y: railY - r * 0.07, width: r * 0.2, height: r * 0.14)
            let stem = CGRect(
                x: s.x - r * 0.018, y: carriage.maxY - 1, width: r * 0.036, height: s.y - carriage.maxY - r * 0.03)
            // The cartridge hangs square to the groove, its stylus exactly on the needle's point.
            let cartridge = CGRect(x: s.x - r * 0.05, y: s.y - r * 0.1, width: r * 0.1, height: r * 0.095)
            if silhouette {
                context.fill(Path(roundedRect: carriage, cornerRadius: 3), with: .color(.black))
                context.fill(Path(stem), with: .color(.black))
                context.fill(Path(roundedRect: cartridge, cornerRadius: 1.5), with: .color(.black))
                return
            }
            context.fill(
                Path(stem),
                with: .linearGradient(
                    metal.cylinder, startPoint: CGPoint(x: stem.minX, y: 0), endPoint: CGPoint(x: stem.maxX, y: 0)))
            context.fill(Path(roundedRect: cartridge, cornerRadius: 1.5), with: .color(paint(paint.design.cartridge)))
            context.stroke(
                Path(roundedRect: cartridge, cornerRadius: 1.5), with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            let tip = s
            var cantilever = Path()
            cantilever.move(to: CGPoint(x: s.x, y: cartridge.maxY - 0.5))
            cantilever.addLine(to: tip)
            context.stroke(cantilever, with: .color(Color(white: 0.85)), lineWidth: 0.7)
            context.fill(
                Path(ellipseIn: CGRect(x: tip.x - 0.7, y: tip.y - 0.7, width: 1.4, height: 1.4)), with: .color(.white))
            context.fill(
                Path(roundedRect: carriage, cornerRadius: 3),
                with: .linearGradient(
                    Gradient(colors: [metal.light, metal.body, metal.shade]),
                    startPoint: CGPoint(x: carriage.minX, y: carriage.minY),
                    endPoint: CGPoint(x: carriage.maxX, y: carriage.maxY)))
            context.stroke(
                Path(roundedRect: carriage, cornerRadius: 3), with: .color(.black.opacity(0.45)), lineWidth: 0.5)
            // The carriage's top: two screws and a tracking lamp.
            for dx in [-r * 0.06, r * 0.06] {
                context.screw(
                    center: CGPoint(x: s.x + dx, y: carriage.midY), radius: r * 0.012, metal: metal, angle: 30)
            }
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: s.x - r * 0.012, y: carriage.midY - r * 0.012, width: r * 0.024, height: r * 0.024)),
                with: .color(paint.accent))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
