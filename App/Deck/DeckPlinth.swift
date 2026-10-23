import PFDesign
import SwiftUI

/// The plinth: its material, bevel and edge, the ambient shadow under it and the well the platter sits in. Lit from
/// the top left, like everything on the deck. Drawn once per design and size (Equatable): nothing in it moves.
struct DeckPlinth: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout
    /// Live glass for the player; a still preview draws the frosting without it, so it can be flattened.
    let live: Bool

    var body: some View {
        let radius = paint.cornerRadius(width: layout.size.width)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if paint.isGlass {
                // The original frosted plinth, live glass over the player's colour wash.
                let frost = shape.fill(
                    LinearGradient(
                        colors: [paint.glassTop, paint.glassBottom], startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                if live {
                    frost.glassEffect(.regular.tint(paint.glassTop.opacity(0.2)), in: .rect(cornerRadius: radius))
                } else {
                    frost.background(shape.fill(paint.dark ? Color(white: 0.16) : Color(white: 0.9)))
                }
            } else {
                shape.fill(paint.base)
            }
            Canvas { context, size in
                draw(&context, size: size, corner: radius)
            }
            .clipShape(shape)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(ambient), radius: 16, y: 10)
        .accessibilityHidden(true)
    }

    /// Darker plinths cast a deeper shadow; the frosted one, as before, a light one in the light look.
    private var ambient: Double {
        if paint.isGlass { return paint.dark ? 0.4 : 0.1 }
        return paint.design.plinth == .lacquer ? 0.22 : 0.34
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, corner: CGFloat) {
        let rect = CGRect(origin: .zero, size: size)
        var random = SeededRandom(paint.design.id)
        switch paint.design.plinth {
        case .frostedGlass: frosted(&context, rect)
        case .brushedMetal: brushed(&context, rect, &random)
        case .matteBlack: matte(&context, rect)
        case .walnut: walnut(&context, rect, &random)
        case .lacquer: lacquer(&context, rect, &random)
        case .smokedAcrylic: acrylic(&context, rect, corner: corner)
        case .leatherette: leatherette(&context, rect, corner: corner)
        }
        well(&context)
        bevel(&context, rect, corner: corner)
    }

    // MARK: Materials

    private func frosted(_ context: inout GraphicsContext, _ rect: CGRect) {
        context.grain(DeckGrain.speckle, in: rect, opacity: paint.dark ? 0.06 : 0.05)
        // The edge-lit rim: the accent glowing faintly from inside the glass, strongest at the top left.
        var glow = context
        glow.addFilter(.blur(radius: 10))
        let corner = paint.cornerRadius(width: rect.width)
        glow.stroke(
            Path(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerRadius: corner),
            with: .linearGradient(
                Gradient(colors: [paint.accent.opacity(paint.dark ? 0.32 : 0.24), paint.accent.opacity(0.04)]),
                startPoint: .zero, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)), lineWidth: 5)
        context.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [paint.accent.opacity(paint.dark ? 0.1 : 0.12), .clear]),
                center: CGPoint(x: rect.width * 0.12, y: rect.height * 0.08), startRadius: 0,
                endRadius: rect.width * 0.9))
    }

    private func brushed(_ context: inout GraphicsContext, _ rect: CGRect, _ random: inout SeededRandom) {
        // Fine horizontal brushing: short straight strokes of light and dark, varied in length and strength.
        let strokes = Int(rect.width * rect.height / 70)
        var light = Path()
        var dark = Path()
        for _ in 0..<strokes {
            let y = random.range(0, rect.height)
            let x = random.range(-40, rect.width)
            let length = random.range(30, 190)
            var line = Path()
            line.move(to: CGPoint(x: x, y: y))
            line.addLine(to: CGPoint(x: x + length, y: y))
            if random.unit() < 0.5 { light.addPath(line) } else { dark.addPath(line) }
        }
        context.stroke(light, with: .color(.white.opacity(0.07)), lineWidth: 0.45)
        context.stroke(dark, with: .color(.black.opacity(0.06)), lineWidth: 0.45)
        // Brushed metal throws a soft band of light across the grain, and the whole sheet is brighter toward the lamp.
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .white.opacity(0.16), location: 0.22),
                    .init(color: .clear, location: 0.42), .init(color: .clear, location: 0.7),
                    .init(color: .white.opacity(0.07), location: 0.82), .init(color: .clear, location: 0.95),
                ]), startPoint: .zero, endPoint: CGPoint(x: rect.width, y: 0)))
        diagonalSheen(&context, rect, light: 0.24, dark: 0.16)
    }

    private func matte(_ context: inout GraphicsContext, _ rect: CGRect) {
        context.grain(DeckGrain.speckle, in: rect, opacity: 0.22)
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.22)]), startPoint: .zero,
                endPoint: CGPoint(x: rect.width * 0.3, y: rect.height)))
    }

    private func walnut(_ context: inout GraphicsContext, _ rect: CGRect, _ random: inout SeededRandom) {
        // Veneer grain along the width. Each line wanders with two waves of its own and a slow drift, and is drawn in
        // runs of varying strength (some fading out altogether), in bands of tighter and looser grain, so no two lines
        // and no two stretches look alike.
        let deep = paint(0x2E1A10)
        let honey = paint(0xA8714A)
        var y: CGFloat = -10
        var density = 1.0
        while y < rect.height + 10 {
            if random.unit() < 0.08 { density = random.range(0.6, 1.9) }
            let f1 = random.range(0.004, 0.013)
            let f2 = random.range(0.02, 0.055)
            let a1 = random.range(1.2, 5.5)
            let a2 = random.range(0.2, 1.3)
            let p1 = random.range(0, 10)
            let p2 = random.range(0, 10)
            var drift = 0.0
            var points: [CGPoint] = []
            var x: CGFloat = -6
            while x <= rect.width + 6 {
                drift = (drift + random.range(-0.4, 0.4)) * 0.97
                let wave = sin(x * f1 + p1) * a1 + sin(x * f2 + p2) * a2 + sin(x * 0.004 + y * 0.03) * 5 + drift
                points.append(CGPoint(x: x, y: y + wave))
                x += 4
            }
            let tone = random.unit() < 0.62 ? deep : honey
            let width = random.range(0.5, 1.8)
            var i = 0
            while i < points.count - 1 {
                let end = min(points.count - 1, i + Int(random.range(5, 32)))
                var run = Path()
                run.move(to: points[i])
                for k in (i + 1)...end { run.addLine(to: points[k]) }
                let alpha = random.unit() < 0.12 ? 0 : random.range(0.06, 0.28)
                context.stroke(run, with: .color(tone.opacity(alpha)), lineWidth: width)
                i = end
            }
            y += random.range(0.9, 2.8) * density
        }
        // A cathedral figure: nested arches where the veneer was cut across a growth ring.
        let arch = CGPoint(
            x: random.range(rect.width * 0.2, rect.width * 0.8), y: random.range(rect.height * 0.25, rect.height * 0.8))
        for k in 0..<8 {
            let span = 26 + CGFloat(k) * 11
            let rise = 10 + CGFloat(k) * 2.6
            let base = arch.y + CGFloat(k) * 3.4
            var curve = Path()
            curve.move(to: CGPoint(x: arch.x - span * 2.2, y: base + rise * 0.4))
            curve.addCurve(
                to: CGPoint(x: arch.x + span * 2.2, y: base + rise * 0.3),
                control1: CGPoint(x: arch.x - span * 0.6, y: base + rise * 0.2),
                control2: CGPoint(x: arch.x - span * 0.2, y: base - rise * 1.6))
            context.stroke(curve, with: .color(deep.opacity(random.range(0.1, 0.2))), lineWidth: random.range(0.6, 1.4))
        }
        for _ in 0..<5 {
            let cy = random.range(0, rect.height)
            var band = Path()
            band.move(to: CGPoint(x: -10, y: cy))
            band.addCurve(
                to: CGPoint(x: rect.width + 10, y: cy + random.range(-14, 14)),
                control1: CGPoint(x: rect.width * 0.3, y: cy + random.range(-20, 20)),
                control2: CGPoint(x: rect.width * 0.7, y: cy + random.range(-20, 20)))
            var blurred = context
            blurred.addFilter(.blur(radius: 3))
            blurred.stroke(band, with: .color(deep.opacity(0.18)), lineWidth: random.range(4, 10))
        }
        var pores = Path()
        for _ in 0..<Int(rect.width * rect.height / 90) {
            let p = CGPoint(x: random.range(0, rect.width), y: random.range(0, rect.height))
            pores.addRect(CGRect(x: p.x, y: p.y, width: random.range(1, 3.5), height: 0.5))
        }
        context.fill(pores, with: .color(deep.opacity(0.22)))
        // Satin oil finish: a broad soft highlight across the top left.
        diagonalSheen(&context, rect, light: 0.16, dark: 0.24)
    }

    private func lacquer(_ context: inout GraphicsContext, _ rect: CGRect, _ random: inout SeededRandom) {
        context.grain(DeckGrain.speckle, in: rect, opacity: 0.03)
        // Ash cheeks at either side, their grain running front to back, set off from the lacquer by a fine shadow.
        let cheek = Self.cheekWidth(rect.width)
        let ash = paint(0xD8BE95)
        let grain = paint(0x8A6A3A)
        for x0 in [0, rect.width - cheek] {
            let strip = CGRect(x: x0, y: 0, width: cheek, height: rect.height)
            context.fill(Path(strip), with: .color(ash))
            var x = x0 + 0.6
            while x < x0 + cheek {
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                var y: CGFloat = 0
                let phase = random.range(0, 6)
                while y < rect.height {
                    y += 6
                    line.addLine(to: CGPoint(x: x + sin(y * 0.02 + phase) * 0.8, y: y))
                }
                context.stroke(line, with: .color(grain.opacity(random.range(0.06, 0.2))), lineWidth: 0.6)
                x += random.range(0.9, 2.2)
            }
            context.fill(
                Path(strip),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.22), .clear, .black.opacity(0.12)]), startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: rect.height)))
            let seam = x0 == 0 ? cheek : rect.width - cheek
            context.fill(
                Path(CGRect(x: seam - 0.5, y: 0, width: 1, height: rect.height)), with: .color(.black.opacity(0.2)))
        }
        // Gloss: a strong soft reflection near the top left of the lacquer.
        context.fill(
            Path(rect.insetBy(dx: cheek, dy: 0)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.55), location: 0), .init(color: .white.opacity(0), location: 0.45),
                    .init(color: .black.opacity(0.06), location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: rect.width, y: rect.height * 0.7)))
    }

    static func cheekWidth(_ width: CGFloat) -> CGFloat { width * 0.044 }

    private func acrylic(_ context: inout GraphicsContext, _ rect: CGRect, corner: CGFloat) {
        // Smoked acrylic: deep and faintly blue, lighter where it is thinner at the top left, with the polished slab
        // edges showing as fine bright lines stepped in from the rim (the light piping through the layers).
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [paint(0x2A2A36), paint.base, paint(0x09090D)]), startPoint: .zero,
                endPoint: CGPoint(x: rect.width, y: rect.height)))
        for i in 0..<4 {
            let inset = 3 + CGFloat(i) * 3.2
            let path = Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: max(2, corner - inset))
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [paint.edge.opacity(0.42 - Double(i) * 0.08), paint.edge.opacity(0.04)]),
                    startPoint: .zero, endPoint: CGPoint(x: rect.width, y: rect.height)), lineWidth: 0.7)
        }
        // A reflection lying across the surface.
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.15), .init(color: .white.opacity(0.07), location: 0.3),
                    .init(color: .clear, location: 0.42),
                ]), startPoint: .zero, endPoint: CGPoint(x: rect.width, y: rect.height)))
    }

    private func leatherette(_ context: inout GraphicsContext, _ rect: CGRect, corner: CGFloat) {
        context.grain(DeckGrain.pebble, in: rect, opacity: 0.16)
        context.grain(DeckGrain.speckle, in: rect, opacity: 0.05)
        diagonalSheen(&context, rect, light: 0.12, dark: 0.22)
        // Stitching round the lid's edge: cream thread dipping into the covering, each stitch with a tiny shadow.
        let inset: CGFloat = 9
        let seam = Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: max(4, corner - inset))
        let dash = StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [3.2, 2.6])
        var shadow = context
        shadow.translateBy(x: 0.5, y: 0.7)
        shadow.stroke(seam, with: .color(.black.opacity(0.35)), style: dash)
        context.stroke(seam, with: .color(paint(0xE8DFC8).opacity(0.85)), style: dash)
        // Brass corner caps.
        let metal = paint.hardware
        // Small enough that the display's corner and the grille clear them.
        let cap = rect.width * 0.046
        for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.minX, rect.maxY), (rect.maxX, rect.maxY)] {
            let c = CGPoint(x: x, y: y)
            let path = Path(ellipseIn: CGRect(x: c.x - cap, y: c.y - cap, width: cap * 2, height: cap * 2))
            context.fill(
                path,
                with: metal.dome(
                    center: CGPoint(x: x == 0 ? cap * 0.4 : x - cap * 0.4, y: y == 0 ? cap * 0.4 : y - cap * 0.4),
                    radius: cap))
            context.stroke(path, with: .color(.black.opacity(0.3)), lineWidth: 0.6)
        }
    }

    /// A broad light from the top left and a fall-off toward the bottom right.
    private func diagonalSheen(_ context: inout GraphicsContext, _ rect: CGRect, light: Double, dark: Double) {
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(light), location: 0), .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(dark), location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: rect.width * 0.55, y: rect.height)))
    }

    // MARK: Shared

    /// The well the platter turns in: a soft occlusion shadow below and right of it, and a dark gap round it.
    private func well(_ context: inout GraphicsContext) {
        let c = layout.recordCenter
        let r = layout.platterRadius
        var shadow = context
        shadow.addFilter(.blur(radius: r * 0.05))
        shadow.fill(
            Path(ellipseIn: CGRect(x: c.x - r + 2, y: c.y - r + 4, width: r * 2 + 3, height: r * 2 + 3)),
            with: .color(.black.opacity(paint.design.plinth == .lacquer ? 0.32 : 0.5)))
        let gap = r + max(1.5, r * 0.018)
        context.stroke(
            Path(ellipseIn: CGRect(x: c.x - gap, y: c.y - gap, width: gap * 2, height: gap * 2)),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0.45), .white.opacity(paint.isGlass ? 0.5 : 0.22)]),
                startPoint: CGPoint(x: c.x - gap, y: c.y - gap), endPoint: CGPoint(x: c.x + gap, y: c.y + gap)),
            lineWidth: 1.2)
    }

    /// The bevel: a lit upper-left edge and a shaded lower-right, inside the edge in the design's edge colour.
    private func bevel(_ context: inout GraphicsContext, _ rect: CGRect, corner: CGFloat) {
        let outer = Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: corner, style: .continuous)
        context.stroke(outer, with: .color(paint.isGlass ? paint.glassEdge : paint.edge.opacity(0.75)), lineWidth: 1.5)
        let inner = Path(
            roundedRect: rect.insetBy(dx: 2.2, dy: 2.2), cornerRadius: max(2, corner - 2), style: .continuous)
        context.stroke(
            inner,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .black.opacity(0.3)]),
                startPoint: .zero, endPoint: CGPoint(x: rect.width, y: rect.height)), lineWidth: 1.4)
    }
}
