import PFDesign
import SwiftUI

/// The platter and its mat, drawn once per design and size. The finish is a conic gradient fixed to the light, not
/// to the platter: a lathe-turned surface is the same at every angle, so as it spins its bright wedges stay put, as
/// they do on a real deck. The strobe's 33⅓ rows are drawn here too: under the lamp they stand still at speed.
struct DeckPlatter: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout

    var body: some View {
        let side = Self.side(layout)
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            platter(&context, c)
            mat(&context, c)
            if let strobe = paint.design.strobe {
                let rows = StrobeRows(layout: layout)
                context.fill(
                    rows.dots(center: c, speeds: [100.0 / 3.0]),
                    with: StrobeRows.lamp(paint(strobe), center: c, uniform: paint.isGlass))
            }
        }
        .frame(width: side, height: side)
        .position(layout.recordCenter)
        .accessibilityHidden(true)
    }

    static func side(_ layout: DeckLayout) -> CGFloat { layout.platterRadius * 2 + 8 }

    /// The finish's tones: body, highlight and shade.
    private var tones: (body: UInt32, light: UInt32, dark: UInt32) {
        switch paint.design.platter {
        case .aluminium: (0xB9BEC4, 0xF1F3F5, 0x868C93)
        case .black: (0x2B2D31, 0x45484E, 0x141518)
        case .cream: (0xE6DCC2, 0xFAF4E4, 0xC7B992)
        case .smoke: (0x2F333A, 0x4D535C, 0x181A1F)
        case .massBlack: (0x151517, 0x26262A, 0x070708)
        }
    }

    private func platter(_ context: inout GraphicsContext, _ c: CGPoint) {
        let r = layout.platterRadius
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let t = tones
        let body = paint(t.body)
        let light = paint(t.light)
        let dark = paint(t.dark)
        // Two bright lobes, top left and bottom right (toward and away from the lamp), dark between: a turned disc.
        let finish = Gradient(stops: [
            .init(color: body, location: 0), .init(color: light, location: 0.1), .init(color: body, location: 0.2),
            .init(color: dark, location: 0.35), .init(color: body, location: 0.45),
            .init(color: light.opacity(0.9), location: 0.6), .init(color: body, location: 0.7),
            .init(color: dark, location: 0.85), .init(color: body, location: 1),
        ])
        context.fill(disc, with: .conicGradient(finish, center: c, angle: .degrees(189)))
        // Lathe rings: fine concentric marks, a little uneven.
        var random = SeededRandom(paint.design.id + "platter")
        var radius = r * 0.12
        while radius < r - 1 {
            let ring = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            let lightRing = random.unit() < 0.5
            context.stroke(
                ring, with: .color((lightRing ? Color.white : .black).opacity(random.range(0.02, 0.06))),
                lineWidth: 0.4)
            radius += random.range(0.7, 1.6)
        }
        if paint.design.platter == .massBlack {
            // A thick mass-loaded platter: its machined top edge catches a thin line of light, and the side wall
            // reads as a darker band at the rim.
            let wall = r - 2.5
            context.stroke(
                Path(ellipseIn: CGRect(x: c.x - wall, y: c.y - wall, width: wall * 2, height: wall * 2)),
                with: .color(.black.opacity(0.6)), lineWidth: 4)
            context.stroke(
                Path(
                    ellipseIn: CGRect(x: c.x - r + 4.5, y: c.y - r + 4.5, width: (r - 4.5) * 2, height: (r - 4.5) * 2)),
                with: .color(paint.accent.opacity(0.4)), lineWidth: 0.6)
        }
        // The rim's bevel: lit at the top left, shaded at the bottom right.
        context.stroke(
            Path(ellipseIn: CGRect(x: c.x - r + 0.6, y: c.y - r + 0.6, width: (r - 0.6) * 2, height: (r - 0.6) * 2)),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .black.opacity(0.45)]),
                startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)),
            lineWidth: 1.2)
        // The step down to the top, where the mat sits.
        let step = layout.recordRadius * 1.03
        context.stroke(
            Path(ellipseIn: CGRect(x: c.x - step, y: c.y - step, width: step * 2, height: step * 2)),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0.35), .white.opacity(0.18)]),
                startPoint: CGPoint(x: c.x - step, y: c.y - step), endPoint: CGPoint(x: c.x + step, y: c.y + step)),
            lineWidth: 0.8)
    }

    private func mat(_ context: inout GraphicsContext, _ c: CGPoint) {
        let kind = paint.design.mat
        guard kind != .none else { return }
        // A little smaller than the record, as a real mat is, so the record's rim overhangs it.
        let r = layout.recordRadius * 0.985
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let colour: UInt32 =
            switch kind {
            case .rubber: 0x1B1C1F
            case .rubberLight: 0x3D3D3E
            case .felt: 0x222225
            case .feltRed: 0x7A1F1F
            case .none: 0
            }
        // The mat's own thickness: a soft shadow on the platter.
        var shadow = context
        shadow.addFilter(.blur(radius: 1.5))
        shadow.fill(disc.offsetBy(dx: 0.6, dy: 1), with: .color(.black.opacity(0.5)))
        context.fill(disc, with: .color(paint(colour)))
        switch kind {
        case .rubber, .rubberLight:
            // Concentric ribs, each with a lit and a shaded side.
            var radius = layout.recordRadius * 0.36
            while radius < r - 1.5 {
                let rib = Path(
                    ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(rib, with: .color(.white.opacity(0.06)), lineWidth: 0.6)
                context.stroke(rib.offsetBy(dx: 0.3, dy: 0.5), with: .color(.black.opacity(0.3)), lineWidth: 0.5)
                radius += 3.2
            }
        case .felt, .feltRed:
            var fibre = context
            fibre.clip(to: disc)
            fibre.grain(DeckGrain.speckle, in: disc.boundingRect, opacity: 0.35)
            fibre.grain(DeckGrain.pebble, in: disc.boundingRect, opacity: 0.12)
        case .none:
            break
        }
        context.fill(
            disc,
            with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.18)]), center: c, startRadius: r * 0.6, endRadius: r))
        context.stroke(disc, with: .color(.black.opacity(0.4)), lineWidth: 0.6)
    }
}

/// The strobe's four rows of dots round the platter's rim (`VinylGeometry.strobeRows`): from the inside out, 50 Hz
/// at 33⅓ (180), 50 Hz at 45 (133), 60 Hz at 33⅓ (216) and 60 Hz at 45 (160). Each dot is half its pitch wide, so
/// each row's dots differ in size.
struct StrobeRows {
    let layout: DeckLayout

    /// Innermost first.
    static let order: [(rpm: Double, mainsHz: Int, dots: Int)] = {
        let rows = VinylGeometry.strobeRows
        return [rows[0], rows[2], rows[1], rows[3]]
    }()

    /// The rows' dots for the given speeds, round `center`.
    func dots(center c: CGPoint, speeds: [Double]) -> Path {
        let outer = layout.platterRadius - 1.6
        let inner = layout.recordRadius * 1.03 + 1.4
        let pitch = (outer - inner) / 4
        var path = Path()
        for (i, row) in Self.order.enumerated() where speeds.contains(where: { abs($0 - row.rpm) < 0.5 }) {
            let radius = inner + pitch * (CGFloat(i) + 0.5)
            let height = pitch * 0.58
            let width = 2 * .pi * radius / CGFloat(row.dots) / 2
            let dot = Path(
                roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                cornerRadius: min(width, height) * 0.3)
            for n in 0..<row.dots {
                let a = Double(n) / Double(row.dots) * 2 * .pi
                let transform = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a)
                    .translatedBy(x: 0, y: -radius)
                path.addPath(dot, transform: transform)
            }
        }
        return path
    }

    /// The lamp's light on the rim, fixed to the deck: brightest at the front left, where the strobe lamp stands, and
    /// falling off round the platter. Glasshouse's rim is edge-lit all round.
    static func lamp(_ colour: Color, center: CGPoint, uniform: Bool) -> GraphicsContext.Shading {
        if uniform { return .color(colour.opacity(0.75)) }
        return .conicGradient(
            Gradient(stops: [
                .init(color: colour, location: 0), .init(color: colour.opacity(0.55), location: 0.18),
                .init(color: colour.opacity(0.3), location: 0.5), .init(color: colour.opacity(0.55), location: 0.82),
                .init(color: colour, location: 1),
            ]), center: center, angle: .degrees(135))
    }

    /// How far the 45 rows appear to creep for a platter turned `degrees` at 33⅓: a fraction of the speed
    /// difference, so the wrong-speed rows drift slowly backward while the right ones stand still, and nothing moves
    /// at rest.
    static func creep(platterDegrees degrees: Double) -> Double {
        degrees * (1 - 45 / (100.0 / 3.0)) * 0.03
    }
}

/// The 45 rpm strobe rows, which creep while the platter turns at 33⅓: the dots are drawn once and only rotated by
/// `phase` per frame, under the lamp's light, which stays put.
struct StrobeCreep: View {
    let paint: DeckPaint
    let layout: DeckLayout
    let phase: Double

    var body: some View {
        if let strobe = paint.design.strobe {
            let side = DeckPlatter.side(layout)
            StrobeDots(layout: layout, colour: paint(strobe))
                .equatable()
                .frame(width: side, height: side)
                .rotationEffect(.degrees(phase))
                .mask {
                    if paint.isGlass {
                        Color.black.opacity(0.75)
                    } else {
                        AngularGradient(
                            stops: [
                                .init(color: .black, location: 0), .init(color: .black.opacity(0.55), location: 0.18),
                                .init(color: .black.opacity(0.3), location: 0.5),
                                .init(color: .black.opacity(0.55), location: 0.82), .init(color: .black, location: 1),
                            ], center: .center, angle: .degrees(135))
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

/// The 45 rows' dots in the strobe's colour.
private struct StrobeDots: View, Equatable {
    let layout: DeckLayout
    let colour: Color

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(StrobeRows(layout: layout).dots(center: c, speeds: [45]), with: .color(colour))
        }
    }
}
