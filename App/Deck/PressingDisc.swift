import PFDesign
import SwiftUI

/// A playlist's pressing as the shelf shows it, 56–64 pt across (spec §3, "Three sizes"): the same coloured vinyl and
/// label, simplified so it reads small. The grooves are a few sheen rings, the label has no rim text but keeps its
/// covers and badge, and the disc lies on the shelf with a soft shadow under a fixed highlight. Decorative: the
/// button it sits in carries the label.
struct PressingDisc: View {
    let look: PressingLook
    /// The disc's diameter.
    let size: CGFloat
    @Environment(\.isMonochrome) private var mono

    var body: some View {
        PressingDiscArt(look: look, size: size, mono: mono)
            .equatable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The disc, flattened once per look and size.
private struct PressingDiscArt: View, Equatable {
    let look: PressingLook
    let size: CGFloat
    let mono: Bool

    var body: some View {
        let ink = PressingInk(colour: look.colour, monochrome: mono)
        let pad = size * 0.2
        let label = size * VinylGeometry.labelToRecord
        ZStack {
            Canvas { context, canvas in
                shadow(&context, CGPoint(x: canvas.width / 2, y: canvas.height / 2))
            }
            .frame(width: size + pad * 2, height: size + pad * 2)
            ZStack {
                Canvas { context, canvas in
                    vinyl(&context, CGPoint(x: canvas.width / 2, y: canvas.height / 2), ink)
                }
                PressingLabelArt(look: look, side: "A", diameter: label, detail: .small, mono: mono)
                Canvas { context, canvas in
                    light(&context, CGPoint(x: canvas.width / 2, y: canvas.height / 2), label / 2)
                }
            }
            .frame(width: size, height: size)
            .mask {
                Canvas { context, canvas in
                    let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                    var path = PressingPaint.circle(c, size / 2)
                    path.addPath(PressingPaint.circle(c, size / 2 * VinylGeometry.spindleHoleToRecord))
                    context.fill(path, with: .color(.black), style: FillStyle(eoFill: true))
                }
            }
        }
        .frame(width: size + pad * 2, height: size + pad * 2)
        .drawingGroup()
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    /// A fine line at this size.
    private var line: CGFloat { max(0.35, size / 300) }

    /// Lying on the shelf: a soft shade cast down from the lamp and a tight contact line, both outside the disc only,
    /// so light still comes through the vinyl.
    private func shadow(_ context: inout GraphicsContext, _ c: CGPoint) {
        let r = size / 2
        var outside = context
        var clip = Path(CGRect(x: c.x - size, y: c.y - size, width: size * 2, height: size * 2))
        clip.addPath(PressingPaint.circle(c, r - 1))
        outside.clip(to: clip, style: FillStyle(eoFill: true))
        var soft = outside
        soft.addFilter(.blur(radius: r * 0.06))
        soft.fill(PressingPaint.circle(CGPoint(x: c.x, y: c.y + r * 0.05), r), with: .color(.black.opacity(0.5)))
        outside.stroke(
            PressingPaint.circle(CGPoint(x: c.x, y: c.y + 0.3 * line), r + 0.2 * line),
            with: .color(.black.opacity(0.5)), lineWidth: 0.8 * line)
    }

    /// The vinyl: deep coloured glass lit through (or black vinyl for Onyx), its grooves as a few sheen rings, under
    /// the lamp's two fixed streaks.
    private func vinyl(_ context: inout GraphicsContext, _ c: CGPoint, _ ink: PressingInk) {
        let r = size / 2
        let disc = PressingPaint.circle(c, r)
        let label = r * VinylGeometry.labelToRecord
        let inner = r * VinylGeometry.innerGrooveToRecord
        let outer = r * VinylGeometry.outerGrooveToRecord
        let black = look.colour.isBlackVinyl
        if black {
            let tone = ink.vinylRGB
            context.fill(
                disc,
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Color(tone.mixed(with: .black, 0.55)), location: 0),
                        .init(color: Color(tone.mixed(with: .black, 0.35)), location: 0.5),
                        .init(color: Color(tone.mixed(with: .black, 0.45)), location: 1),
                    ]), center: c, startRadius: label, endRadius: r))
        } else {
            PressingVinyl.body(&context, center: c, radius: r, label: label, tone: ink.vinylRGB, free: true)
        }
        // The grooves, as seven sheen rings: a cut, and a lit lip just outside it.
        for i in 0..<7 {
            let q = inner + (outer - inner) * (CGFloat(i) + 0.5) / 7
            context.stroke(
                PressingPaint.circle(c, q), with: .color(black ? .white.opacity(0.07) : .black.opacity(0.26)),
                lineWidth: max(0.17, r * 0.018))
            context.stroke(
                PressingPaint.circle(c, q + r * 0.014), with: .color(.white.opacity(0.09)), lineWidth: 0.17)
        }
        // The lamp's two streaks across the grooves.
        var lit = context
        lit.clip(to: PressingPaint.circle(c, outer).subtracting(PressingPaint.circle(c, label)))
        lit.fill(disc, with: RecordLight.streaks(center: c, near: 0.42, far: 0.26, spread: 1.5))
        // The rim's bevel.
        context.stroke(
            PressingPaint.circle(c, r - 0.7 * line),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.34), .white.opacity(0.06), .white.opacity(0.18)]),
                startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)),
            lineWidth: max(0.24, line))
    }

    /// The label's own light: a faint matte sheen, its edge standing a hair proud of the dead wax, and the hole's
    /// edge.
    private func light(_ context: inout GraphicsContext, _ c: CGPoint, _ labelRadius: CGFloat) {
        let paper = PressingPaint.circle(c, labelRadius)
        var sheen = context
        sheen.clip(to: paper)
        sheen.fill(paper, with: RecordLight.streaks(center: c, near: 0.16, far: 0.06, spread: 1.6))
        context.stroke(
            paper,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.3), .black.opacity(0.38)]),
                startPoint: CGPoint(x: c.x - labelRadius, y: c.y - labelRadius),
                endPoint: CGPoint(x: c.x + labelRadius, y: c.y + labelRadius)), lineWidth: max(0.17, 0.6 * line))
        context.stroke(
            PressingPaint.circle(c, size / 2 * VinylGeometry.spindleHoleToRecord),
            with: .color(.black.opacity(0.35)), lineWidth: max(0.17, 0.6 * line))
    }
}

/// A playlist as a square cover, for wherever a square is needed: the covers of its first four albums in a 2 × 2
/// grid with hairline cream gaps, and the pressing's badge where they meet. Fewer albums repeat across the grid; one
/// fills it; none prints the guilloché paper. Square; the caller sizes and clips it. Decorative.
struct PressingCoverMosaic: View {
    let look: PressingLook
    /// The longest side to decode each cover at, in pixels.
    var pixels: Int = 300
    @Environment(\.isMonochrome) private var mono

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            PressingMosaicArt(look: look, side: side, pixels: pixels, mono: mono)
                .equatable()
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct PressingMosaicArt: View, Equatable {
    let look: PressingLook
    let side: CGFloat
    let pixels: Int
    let mono: Bool

    /// The four tiles, in reading order: two covers cross over (A B / B A), three repeat the first (A B / C A).
    private var tiles: [String] {
        let covers = look.covers
        switch covers.count {
        case 0, 1: return covers
        case 2: return [covers[0], covers[1], covers[1], covers[0]]
        case 3: return [covers[0], covers[1], covers[2], covers[0]]
        default: return Array(covers.prefix(4))
        }
    }

    var body: some View {
        let ink = PressingInk(colour: look.colour, monochrome: mono)
        let tiles = tiles
        let gap = max(0.5, side * 0.009)
        let cell = (side - gap) / 2
        ZStack {
            Canvas { context, canvas in
                let rect = CGRect(origin: .zero, size: canvas)
                context.fill(Path(rect), with: .color(ink.paper))
                context.grain(DeckGrain.speckle, in: rect, opacity: 0.1)
                if tiles.isEmpty {
                    var paper = context
                    paper.clip(to: Path(rect))
                    PressingPaint.guilloche(
                        &paper, center: CGPoint(x: rect.midX, y: rect.midY), inner: side * 0.17, outer: side * 0.5,
                        colour: ink.vinyl, line: max(0.3, side * 0.004))
                }
            }
            if tiles.count == 1 {
                ArtworkView(albumID: tiles[0], artwork: nil, pixels: pixels)
                    .frame(width: side, height: side)
                    .clipped()
                    .id(tiles[0])
            } else {
                ForEach(PressingSlot.slots(tiles), id: \.id) { slot in
                    let (index, albumID) = (slot.index, slot.albumID)
                    ArtworkView(albumID: albumID, artwork: nil, pixels: pixels)
                        .frame(width: cell, height: cell)
                        .clipped()
                        .position(
                            x: index % 2 == 0 ? cell / 2 : side - cell / 2, y: index < 2 ? cell / 2 : side - cell / 2)
                }
            }
            Canvas { context, canvas in
                let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                if !tiles.isEmpty {
                    // A soft vignette toward the badge and the edges, as on the label, so the tiles read as one print.
                    context.fill(
                        Path(CGRect(origin: .zero, size: canvas)),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: .black.opacity(0.2), location: 0.18),
                                .init(color: .clear, location: 0.34),
                                .init(color: .clear, location: 0.72),
                                .init(color: .black.opacity(0.16), location: 1),
                            ]), center: c, startRadius: 0, endRadius: side * 0.72))
                    context.grain(DeckGrain.speckle, in: CGRect(origin: .zero, size: canvas), opacity: 0.06)
                }
                PressingPaint.badge(
                    &context, look: look, center: c, radius: side * 0.15, hole: 0, ink: ink, mono: mono)
            }
        }
        .frame(width: side, height: side)
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
