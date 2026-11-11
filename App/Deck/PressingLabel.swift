import PFDesign
import SwiftUI

/// A playlist's centre label (spec §3 and §8), printed on cream paper. From the outside in:
/// - the paper rim ring, with the title, song count, side and speed curved round it in dark ink;
/// - the covers of up to six of its albums, each in an equal wedge from twelve o'clock with hairline cream gaps,
///   joined by a soft vignette (an empty playlist prints fine guilloché rings there instead);
/// - the centre badge: a cream disc ringed in the pressing colour, carrying a heart for Favourites or the playlist's
///   monogram, with the spindle hole punched through.
///
/// `diameter` is the label's own. Drawn once per look, side and size, and flattened to one layer: the deck only turns
/// it. Decorative, so hidden from VoiceOver.
struct PressingLabel: View {
    let look: PressingLook
    let side: String
    let diameter: CGFloat
    @Environment(\.isMonochrome) private var mono

    var body: some View {
        PressingLabelArt(look: look, side: side, diameter: diameter, detail: .full, mono: mono)
            .equatable()
            .accessibilityHidden(true)
    }
}

/// How much of the label is drawn: everything at deck size, or the shelf disc's, which keeps the covers and the badge
/// but drops the rim text, the rule and the paper's fibres, so it reads at 56 pt.
enum PressingDetail: Hashable {
    case full, small
}

/// The label's proportions, as fractions of its radius (spec §3).
enum PressingGeometry {
    /// Where the covers end and the paper rim ring starts.
    static let rimInner: CGFloat = 0.80
    /// The centre badge's radius.
    static let badge: CGFloat = 0.24
    /// The spindle hole's radius: 7.24 mm on a 100 mm label.
    static let hole: CGFloat = VinylGeometry.spindleHoleToRecord / VinylGeometry.labelToRecord
}

/// The label, flattened: Equatable on everything it draws from, so a deck turning it at 120 Hz never lays it out
/// again.
struct PressingLabelArt: View, Equatable {
    let look: PressingLook
    let side: String
    let diameter: CGFloat
    let detail: PressingDetail
    let mono: Bool

    var body: some View {
        let r = diameter / 2
        let ink = PressingInk(colour: look.colour, monochrome: mono)
        let covers = look.covers
        let gap = PressingPaint.gap(labelRadius: r, detail: detail)
        let frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ZStack {
            Canvas { context, size in
                PressingPaint.paper(
                    &context, center: CGPoint(x: size.width / 2, y: size.height / 2), radius: r, detail: detail,
                    seed: look.id)
            }
            ForEach(Array(covers.enumerated()), id: \.offset) { index, albumID in
                let wedge = PressingWedge(
                    index: index, count: covers.count, inner: PressingGeometry.badge * 0.9,
                    outer: PressingGeometry.rimInner, gap: gap)
                let place = wedge.cover(in: frame)
                // 300 px: the label is under 100 pt across, and the shelf decodes this size for its sleeves already.
                ArtworkView(albumID: albumID, artwork: nil, pixels: 300)
                    .frame(width: place.side, height: place.side)
                    .rotationEffect(place.turn)
                    .position(place.center)
                    .frame(width: diameter, height: diameter)
                    .clipShape(wedge)
            }
            Canvas { context, size in
                PressingPaint.print(
                    &context, look: look, side: side, center: CGPoint(x: size.width / 2, y: size.height / 2),
                    radius: r, detail: detail, ink: ink, mono: mono)
            }
        }
        .frame(width: diameter, height: diameter)
        // The spindle hole goes through the paper and the print alike.
        .mask {
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                var path = PressingPaint.circle(c, r)
                path.addPath(PressingPaint.circle(c, r * PressingGeometry.hole))
                context.fill(path, with: .color(.black), style: FillStyle(eoFill: true))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// One of the label's cover wedges: an annular sector from `inner` to `outer` (fractions of the radius), the
/// `index`th of `count` equal ones clockwise from twelve o'clock, its straight edges set in by half the cream gap on
/// each side. One wedge is a full disc.
struct PressingWedge: Shape {
    let index: Int
    let count: Int
    let inner: CGFloat
    let outer: CGFloat
    /// The cream gap between neighbouring wedges, in points.
    let gap: CGFloat

    private var span: Double { 2 * .pi / Double(max(count, 1)) }
    private var start: Double { -.pi / 2 + Double(index) * span }
    private var middle: Double { start + span / 2 }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let ro = radius * outer
        if count <= 1 { return PressingPaint.circle(c, ro) }
        var path = Path()
        path.addLines(outline(c, radius * inner, ro))
        path.closeSubpath()
        return path
    }

    /// Where the wedge's cover goes (spec §8.8). One cover fills the disc; two stand upright, each over its half;
    /// three to six turn so their tops face outward, each centred in its wedge and just wide enough to fill it.
    func cover(in rect: CGRect) -> (center: CGPoint, side: CGFloat, turn: Angle) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let ro = radius * outer
        let ri = radius * PressingGeometry.badge
        switch count {
        case ...1:
            return (c, ro * 2, .zero)
        case 2:
            return (CGPoint(x: c.x + cos(middle) * ro * 0.42, y: c.y), ro * 2, .zero)
        default:
            let side = max(ro - ri, 2 * ro * sin(.pi / Double(count))) * 1.1
            let at = (ri + ro) / 2
            return (
                CGPoint(x: c.x + cos(middle) * at, y: c.y + sin(middle) * at), side, .radians(middle + .pi / 2)
            )
        }
    }

    /// The wedge's outline, sampled every degree or so: the outer arc clockwise, then the inner arc back.
    private func outline(_ c: CGPoint, _ ri: CGFloat, _ ro: CGFloat) -> [CGPoint] {
        let half = gap / 2
        let outerInset = asin(min(0.99, half / max(ro, 0.1)))
        let innerInset = asin(min(0.99, half / max(ri, 0.1)))
        let steps = max(8, Int(span * 180 / .pi))
        func arc(_ radius: CGFloat, _ from: Double, _ to: Double) -> [CGPoint] {
            (0...steps).map { k in
                let a = from + (to - from) * Double(k) / Double(steps)
                return CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
            }
        }
        let end = start + span
        return arc(ro, start + outerInset, end - outerInset) + arc(ri, end - innerInset, start + innerInset)
    }
}

/// The pressing's drawing routines, shared by the label, the shelf disc and the cover mosaic.
enum PressingPaint {
    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// The cream gap between wedges: 1 pt on the deck's label, a hairline on the shelf's.
    static func gap(labelRadius r: CGFloat, detail: PressingDetail) -> CGFloat {
        detail == .full ? max(0.45, r * 0.023) : max(0.3, r * 0.03)
    }

    /// A fine line's width on a label of radius `r`: 0.87 pt at deck size, never thinner than half a point.
    static func line(labelRadius r: CGFloat) -> CGFloat { max(0.5, r * 0.02) }

    /// The label's paper: cream stock and, at deck size, its fibres (short strokes, warm and light) and a touch of
    /// shade toward the rim.
    static func paper(
        _ context: inout GraphicsContext, center c: CGPoint, radius r: CGFloat, detail: PressingDetail, seed: String
    ) {
        let disc = circle(c, r)
        context.fill(disc, with: .color(Color(PressingInk.paperRGB)))
        guard detail == .full else { return }
        var random = SeededRandom(seed + "paper")
        let kl = line(labelRadius: r)
        var fibres = context
        fibres.clip(to: disc)
        for _ in 0..<Int(r * r * 0.54) {
            let a = random.unit() * 2 * .pi
            let q = sqrt(random.unit()) * r
            let x = c.x + cos(a) * q
            let y = c.y + sin(a) * q
            let length = random.range(0.4, 2) * kl
            let b = random.unit() * 2 * .pi
            let warm = random.unit() < 0.5
            let colour =
                warm
                ? Color(PressingInk.fibre, opacity: random.range(0.05, 0.12))
                : Color.white.opacity(random.range(0.12, 0.27))
            var fibre = Path()
            fibre.move(to: CGPoint(x: x, y: y))
            fibre.addLine(to: CGPoint(x: x + cos(b) * length, y: y + sin(b) * length))
            fibres.stroke(fibre, with: .color(colour), lineWidth: 0.35 * kl)
        }
        fibres.fill(
            disc,
            with: .radialGradient(
                Gradient(colors: [.clear, Color(red: 90 / 255, green: 60 / 255, blue: 30 / 255, opacity: 0.1)]),
                center: c, startRadius: r * 0.5, endRadius: r))
    }

    /// Everything printed over the covers: the vignette (or an empty playlist's guilloché), the rule, the rim text and
    /// the badge.
    static func print(
        _ context: inout GraphicsContext, look: PressingLook, side: String, center c: CGPoint, radius r: CGFloat,
        detail: PressingDetail, ink: PressingInk, mono: Bool
    ) {
        let w0 = r * PressingGeometry.badge
        let w1 = r * PressingGeometry.rimInner
        if look.covers.isEmpty {
            guilloche(&context, center: c, inner: w0, outer: w1, colour: ink.vinyl, line: max(0.2, r * 0.01))
        } else {
            // The vignette that joins the covers: a warm shade where they meet the badge and the paper ring.
            var vignette = context
            vignette.clip(to: circle(c, w1).subtracting(circle(c, w0 * 0.9)))
            let shade = Color(red: 20 / 255, green: 10 / 255, blue: 5 / 255)
            vignette.fill(
                circle(c, w1),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: shade.opacity(0.32), location: 0), .init(color: shade.opacity(0), location: 0.3),
                        .init(color: shade.opacity(0), location: 0.68), .init(color: shade.opacity(0.36), location: 1),
                    ]), center: c, startRadius: w0, endRadius: w1))
            context.stroke(
                circle(c, w1), with: .color(Color(red: 60 / 255, green: 40 / 255, blue: 20 / 255, opacity: 0.25)),
                lineWidth: max(0.3, r * 0.004))
        }
        if detail == .full {
            context.stroke(
                circle(c, r * 0.965), with: .color(ink.text.opacity(0.35)), lineWidth: max(0.3, r * 0.005))
            RecordPrint.arc(
                &context, look.rimText(side: side), center: c, radius: r * 0.875, size: max(2.4, r * 0.112),
                color: ink.text, start: -90, smallCaps: true, tracking: 0.2, baseline: true)
        }
        badge(&context, look: look, center: c, radius: w0, hole: r * PressingGeometry.hole, ink: ink, mono: mono)
    }

    /// The centre badge: a cream disc with a faint printed edge, ringed in the pressing colour, with the heart or the
    /// monogram. `hole` is the spindle hole's radius (0 for the square cover, which has none): the heart gets a cream
    /// washer round it, so the hole reads as punched through.
    static func badge(
        _ context: inout GraphicsContext, look: PressingLook, center c: CGPoint, radius b: CGFloat, hole: CGFloat,
        ink: PressingInk, mono: Bool
    ) {
        context.fill(circle(c, b), with: .color(ink.paper))
        context.stroke(circle(c, b), with: .color(ink.text.opacity(0.18)), lineWidth: max(0.3, b * 0.017))
        context.stroke(circle(c, b * 0.9), with: .color(ink.print), lineWidth: max(0.4, b * 0.05))
        if look.isFavourites {
            context.fill(heart(center: CGPoint(x: c.x, y: c.y + b * 0.025), width: b * 1.42), with: .color(ink.print))
            if hole > 0 { context.fill(circle(c, hole + b * 0.083), with: .color(ink.paper)) }
        } else {
            monogram(&context, look.monogram, center: c, badge: b, ink: ink, mono: mono)
        }
    }

    /// The monogram (spec §8.1): two letters interlocked, the second a lighter impression set down and to the right
    /// of the first; or one large letter. Either way the spindle hole goes through it.
    static func monogram(
        _ context: inout GraphicsContext, _ letters: String, center c: CGPoint, badge b: CGFloat, ink: PressingInk,
        mono: Bool
    ) {
        let chars = Array(letters.prefix(2))
        guard !chars.isEmpty else { return }
        var ctx = context
        // An emoji keeps its own colours, so Monochrome greys it here.
        if mono { ctx.addFilter(.grayscale(1)) }
        func draw(_ ch: Character, size: CGFloat, x: CGFloat, baseline y: CGFloat, opacity: Double) {
            let text = ctx.resolve(
                Text(String(ch)).font(.system(size: size, weight: .bold, design: .serif))
                    .foregroundStyle(ink.print.opacity(opacity)))
            let box = CGSize(width: size * 4, height: size * 4)
            let height = max(text.measure(in: box).height, 0.01)
            let anchor = UnitPoint(x: 0.5, y: text.firstBaseline(in: box) / height)
            ctx.draw(text, at: CGPoint(x: c.x + x, y: c.y + y), anchor: anchor)
        }
        if chars.count == 2 {
            let size = b * 1.04
            let dx = b * 0.19
            draw(chars[1], size: size, x: dx, baseline: size * 0.35 + b * 0.1, opacity: 0.5)
            draw(chars[0], size: size, x: -dx, baseline: size * 0.35 - b * 0.06, opacity: 1)
        } else {
            let size = b * 1.4
            draw(chars[0], size: size, x: 0, baseline: size * 0.35, opacity: 1)
        }
    }

    /// The classic heart curve, `width` wide, centred on `center`.
    static func heart(center c: CGPoint, width w: CGFloat) -> Path {
        let k = w / 32
        var path = Path()
        for i in 0...96 {
            let t = Double(i) / 96 * 2 * .pi
            let x = 16 * pow(sin(t), 3)
            let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            let point = CGPoint(x: c.x + x * k, y: c.y - (y + 2.5) * k)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// An empty playlist's paper (spec §3): fine concentric rings, each waving gently, in two interlaced families, in
    /// the pressing colour at a quarter strength.
    static func guilloche(
        _ context: inout GraphicsContext, center c: CGPoint, inner: CGFloat, outer: CGFloat, colour: Color,
        line: CGFloat
    ) {
        guard outer > inner else { return }
        let rings = 11
        let amplitude = (outer - inner) * 0.045
        for family in 0..<2 {
            let lobes = Double(18 + family * 6)
            for j in 0..<rings {
                let base = inner + (outer - inner) * (CGFloat(j) + 0.5) / CGFloat(rings)
                let phase = Double(j) * 0.55 + Double(family) * .pi
                var wave = Path()
                for i in 0...360 {
                    let t = Double(i) / 360 * 2 * .pi
                    let q = base + amplitude * sin(lobes * t + phase)
                    let point = CGPoint(x: c.x + cos(t) * q, y: c.y + sin(t) * q)
                    if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
                }
                wave.closeSubpath()
                // Each ring on its own, so where the families cross the ink doubles, as it does on a banknote.
                context.stroke(wave, with: .color(colour.opacity(0.25)), lineWidth: line)
            }
        }
    }
}
