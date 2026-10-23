import PFDesign
import SwiftUI

/// Everything that decides how a record looks, and nothing that changes per frame. The deck, the hand-off's record
/// in flight, the cover's peeking record and the Customize deck previews all draw from it, so what flies is what
/// lands.
struct RecordFace: Equatable {
    let albumID: String
    let artwork: Data?
    let title: String
    let artist: String
    /// The side's letter, for the label: "A", "B".
    let side: String
    /// Track-gap radii, as fractions of the record's radius.
    let bands: [CGFloat]
    let style: RecordStyle

    init(album: AlbumCard, side: String, bands: [CGFloat], style: RecordStyle) {
        albumID = album.id
        artwork = album.artwork
        title = album.title
        artist = album.artist
        self.side = side
        self.bands = bands
        self.style = style
    }

    /// A generated record with no album behind it (the Customize deck preview with nothing loaded).
    init(placeholderStyle style: RecordStyle) {
        albumID = "pointflac"
        artwork = nil
        title = "pointFlac"
        artist = "Side One"
        side = "A"
        bands = [0.86, 0.74, 0.6]
        self.style = style
    }

    /// Covers can be large: two faces of the same album compare by their art's size, not byte by byte, since the deck
    /// compares faces every frame.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.albumID == b.albumID && a.artwork?.count == b.artwork?.count && a.title == b.title && a.artist == b.artist
            && a.side == b.side && a.bands == b.bands && a.style == b.style
    }

    /// A side's track gaps as radii, fractions of the record's: the groove runs at an even pitch from the outer
    /// groove (the side's start) to the inner one (its end), so a gap sits at the radius its time puts it. The same
    /// for every arm, since it is a property of the record.
    static func bands(for timeline: SideTimeline) -> [CGFloat] {
        guard timeline.total > 0 else { return [] }
        let outer = VinylGeometry.outerGrooveToRecord
        let inner = VinylGeometry.innerGrooveToRecord
        return timeline.starts.dropFirst().map { outer - (outer - inner) * $0 / timeline.total }
    }

    /// The label's curved rim text.
    var rimText: String {
        "SIDE \(side) · \(title.uppercased()) · \(artist.uppercased()) · 33⅓ RPM · STEREO"
    }

    /// The etched matrix number in the dead wax.
    var matrix: String {
        let code = albumID.filter { $0.isLetter || $0.isNumber }.prefix(4).uppercased()
        return "PFL-\(code.isEmpty ? "0000" : code)-\(side)1"
    }
}

/// A 12-inch record seen from above, in true proportions (`VinylGeometry`): black vinyl with the art on its label
/// (the default), translucent coloured vinyl, or a picture disc.
///
/// Only what is printed turns with `angle` (the label, its rim text, the etched matrix, a picture disc's art). The
/// grooves are concentric, so they look the same at every angle and stay put; so do the light streaks on them, which
/// a real deck's lamp holds still while the record turns under it. That is what makes black vinyl look calm at
/// 33⅓. Each layer is drawn once; per frame the print is only rotated.
struct RecordView: View {
    let face: RecordFace
    let diameter: CGFloat
    /// Clockwise, in degrees.
    var angle: Double = 0
    @Environment(\.isMonochrome) private var mono

    var body: some View {
        ZStack {
            RecordContactShadow(diameter: diameter).equatable()
            if face.style == .picture {
                PictureArt(face: face, diameter: diameter).equatable()
                    .rotationEffect(.degrees(angle))
            }
            RecordGrooves(face: face, diameter: diameter, tint: tint).equatable()
            if face.style != .picture {
                RecordLabel(face: face, diameter: diameter).equatable()
                    .rotationEffect(.degrees(angle))
            }
            RecordLight(diameter: diameter, picture: face.style == .picture).equatable()
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    /// Coloured vinyl's tint, from the album's palette: greys in Monochrome, like everything the album tints.
    private var tint: Color? {
        guard face.style == .coloured else { return nil }
        let palette = ArtPalette(seed: face.albumID)
        return mono ? palette.monochrome().base : palette.base
    }
}

/// The record's rim resting on the mat: a tight dark line where it touches and a little soft shade beyond.
private struct RecordContactShadow: View, Equatable {
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = diameter / 2
            var soft = context
            soft.addFilter(.blur(radius: 2.5))
            soft.stroke(
                Path(ellipseIn: CGRect(x: c.x - r + 1, y: c.y - r + 2, width: r * 2, height: r * 2)),
                with: .color(.black.opacity(0.35)), lineWidth: 3)
            context.stroke(
                Path(ellipseIn: CGRect(x: c.x - r - 0.2, y: c.y - r + 0.3, width: r * 2 + 0.4, height: r * 2 + 0.4)),
                with: .color(.black.opacity(0.5)), lineWidth: 0.8)
        }
        .frame(width: diameter + 16, height: diameter + 16)
        .allowsHitTesting(false)
    }
}

/// The vinyl and its grooves, which do not turn: fine concentric rings of slightly varying brightness from the inner
/// to the outer groove, smooth darker gaps between tracks, the lead-in bead at the rim and the glossy dead wax inside.
/// The two light streaks are lit into the grooves themselves, so a track gap shows as a dark break across the
/// streak, as it does under a real lamp.
private struct RecordGrooves: View, Equatable {
    let face: RecordFace
    let diameter: CGFloat
    let tint: Color?

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.face.albumID == b.face.albumID && a.face.bands == b.face.bands && a.face.style == b.face.style
            && a.diameter == b.diameter && a.tint == b.tint
    }

    var body: some View {
        Canvas { context, size in
            draw(&context, CGPoint(x: size.width / 2, y: size.height / 2), diameter / 2)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    private func draw(_ context: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        func circle(_ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        }
        let disc = circle(r)
        let label = r * VinylGeometry.labelToRecord
        let inner = r * VinylGeometry.innerGrooveToRecord
        let outer = r * VinylGeometry.outerGrooveToRecord
        let picture = face.style == .picture
        // The vinyl.
        if let tint {
            // Translucent: the platter shows faintly through, denser toward the rim where light crosses more vinyl.
            context.fill(
                disc,
                with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.4), tint.opacity(0.48), tint.opacity(0.62)]), center: c,
                    startRadius: label, endRadius: r))
            context.fill(disc, with: .color(.black.opacity(0.16)))
            // Light piping through the vinyl glows at its edge.
            context.stroke(circle(r - 1.6), with: .color(tint.opacity(0.28)), lineWidth: 2)
        } else if !picture {
            context.fill(
                disc,
                with: .radialGradient(
                    Gradient(colors: [Color(white: 0.055), Color(white: 0.075), Color(white: 0.06)]), center: c,
                    startRadius: label, endRadius: r))
        }
        // Grooves: one ring every ~0.75 pt, each a little brighter or darker, and each track a little different (its
        // level changes how densely the groove is cut). Gaps are left smooth.
        let gap = max(0.9, r * 0.008)
        let gaps = face.bands.map { $0 * r }.filter { $0 > inner + gap && $0 < outer - gap }
        let edges = [inner] + gaps.sorted() + [outer]
        var random = SeededRandom(face.albumID + face.style.rawValue)
        let levels = edges.map { _ in random.range(0.78, 1.28) }
        var rings: [(radius: CGFloat, alpha: Double)] = []
        let pitch = max(0.55, r * 0.0058)
        var radius = inner
        while radius <= outer {
            if !gaps.contains(where: { abs($0 - radius) < gap }) {
                let track = (edges.lastIndex { $0 <= radius } ?? 0)
                rings.append((radius, random.range(0.022, 0.06) * levels[min(track, levels.count - 1)]))
            }
            radius += pitch * random.range(0.85, 1.15)
        }
        // On black vinyl a groove shows as a faint light ring; on a picture disc or coloured vinyl, as a darker one
        // with a lighter edge.
        let clear = picture || tint != nil
        for ring in rings {
            if clear {
                context.stroke(circle(ring.radius), with: .color(.black.opacity(ring.alpha * 2.4)), lineWidth: 0.45)
                context.stroke(
                    circle(ring.radius + 0.35), with: .color(.white.opacity(ring.alpha * 0.9)), lineWidth: 0.3)
            } else {
                context.stroke(circle(ring.radius), with: .color(.white.opacity(ring.alpha)), lineWidth: 0.45)
            }
        }
        // The gaps: smooth, so a shade darker and glossier than the grooves either side.
        for g in gaps {
            context.stroke(circle(g), with: .color(.black.opacity(picture ? 0.3 : 0.4)), lineWidth: gap * 1.4)
        }
        // The streaks, lit into the grooves: the same rings far brighter, kept only inside two wedges that face the
        // light (top left) and its opposite.
        context.drawLayer { layer in
            for ring in rings {
                layer.stroke(circle(ring.radius), with: .color(.white.opacity(min(1, ring.alpha * 10))), lineWidth: 0.5)
            }
            layer.blendMode = .destinationIn
            layer.fill(
                disc, with: RecordLight.streaks(center: c, near: picture ? 0.55 : 0.9, far: picture ? 0.4 : 0.62))
        }
        // A broad, faint gloss over the grooved area, in the same wedges.
        context.drawLayer { layer in
            layer.clip(to: circle(outer).subtracting(circle(inner)))
            layer.fill(disc, with: RecordLight.streaks(center: c, near: 0.07, far: 0.05, spread: 1.8))
        }
        // The dead wax: smooth vinyl between the last groove and the label, with the wide run-out spiral and the
        // locked groove, and a crisper glint than the grooves get.
        if !picture {
            for (i, f) in [0.985, 0.965, 0.94].enumerated() {
                context.stroke(
                    circle(inner * f), with: .color(.white.opacity(0.05 - Double(i) * 0.01)), lineWidth: 0.4)
            }
            let locked = label + (inner - label) * 0.28
            context.stroke(circle(locked), with: .color(.white.opacity(0.12)), lineWidth: 0.45)
            context.drawLayer { layer in
                layer.clip(to: circle(inner - 0.5).subtracting(circle(label + 0.5)))
                layer.fill(disc, with: RecordLight.streaks(center: c, near: 0.2, far: 0.12, spread: 0.55))
            }
        }
        // The lead-in: a couple of wide spiral turns, then the raised bead of the rim, its edge catching the light.
        for f in [0.4, 0.75] {
            context.stroke(
                circle(outer + (r - outer) * f), with: .color(.white.opacity(picture ? 0.12 : 0.05)), lineWidth: 0.4)
        }
        context.stroke(circle(outer + 0.4), with: .color(.black.opacity(0.4)), lineWidth: 0.6)
        context.stroke(
            circle(r - 0.7),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.3), .white.opacity(0.06), .white.opacity(0.16)]),
                startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)),
            lineWidth: 1)
    }
}

/// What is printed and turns with the record: the label (the album's art, clipped to a circle) with its curved rim
/// text, and the matrix number etched in the dead wax.
private struct RecordLabel: View, Equatable {
    let face: RecordFace
    let diameter: CGFloat

    var body: some View {
        let label = diameter * VinylGeometry.labelToRecord
        ZStack {
            // 300 px: the label is under 100 pt across, and the shelf already decodes this size for the hand-off.
            ArtworkView(albumID: face.albumID, artwork: face.artwork, pixels: 300)
                .frame(width: label, height: label)
                .clipShape(Circle())
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                RecordPrint.label(&context, face: face, center: c, recordRadius: diameter / 2)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}

/// A picture disc's art, across the whole record.
private struct PictureArt: View, Equatable {
    let face: RecordFace
    let diameter: CGFloat

    var body: some View {
        ZStack {
            ArtworkView(albumID: face.albumID, artwork: face.artwork, pixels: 900)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = diameter / 2
                // The clear vinyl the print is sealed in: a thin clear rim and a clear ring round the spindle.
                let hub = r * 0.07
                context.stroke(
                    Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)),
                    with: .color(.white.opacity(0.35)), lineWidth: 0.6)
                RecordPrint.arc(
                    &context, face.matrix, center: c, radius: r * 0.955, size: max(2.2, r * 0.022),
                    color: .white.opacity(0.4), start: 200, monospaced: true)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}

/// The light that stays put over the record: a softer, weaker sheen on the paper label (matte, so it barely
/// catches the lamp), and the spindle hole.
private struct RecordLight: View, Equatable {
    let diameter: CGFloat
    let picture: Bool

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = diameter / 2
            let label = r * VinylGeometry.labelToRecord
            let paper = Path(ellipseIn: CGRect(x: c.x - label, y: c.y - label, width: label * 2, height: label * 2))
            if !picture {
                context.drawLayer { layer in
                    layer.clip(to: paper)
                    layer.fill(paper, with: Self.streaks(center: c, near: 0.1, far: 0.06, spread: 1.6))
                }
                // The label's edge sits a hair proud of the dead wax.
                context.stroke(
                    paper,
                    with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.28), .black.opacity(0.35)]),
                        startPoint: CGPoint(x: c.x - label, y: c.y - label),
                        endPoint: CGPoint(x: c.x + label, y: c.y + label)), lineWidth: 0.6)
            } else {
                let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                context.fill(disc, with: Self.streaks(center: c, near: 0.12, far: 0.08, spread: 1.2))
            }
            let hole = r * VinylGeometry.spindleHoleToRecord
            let punched = Path(ellipseIn: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2))
            context.fill(
                punched,
                with: .radialGradient(
                    Gradient(colors: [.black, Color(white: 0.08)]), center: c, startRadius: 0, endRadius: hole))
            context.stroke(punched, with: .color(.white.opacity(0.25)), lineWidth: 0.4)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    /// Two soft wedges of light at fixed screen angles: one toward the lamp at the top left, brighter, and one
    /// opposite. `spread` widens them. The wedges never turn with the record.
    static func streaks(center: CGPoint, near: Double, far: Double, spread: Double = 1) -> GraphicsContext.Shading {
        let half = 0.045 * spread
        let toward = 0.625  // 225°: up and to the left.
        let away = 0.125  // 45°: down and to the right.
        func wedge(_ at: Double, _ alpha: Double) -> [Gradient.Stop] {
            [
                .init(color: .white.opacity(0), location: at - half * 2),
                .init(color: .white.opacity(alpha * 0.55), location: at - half * 0.6),
                .init(color: .white.opacity(alpha), location: at),
                .init(color: .white.opacity(alpha * 0.55), location: at + half * 0.6),
                .init(color: .white.opacity(0), location: at + half * 2),
            ]
        }
        let stops =
            [Gradient.Stop(color: .white.opacity(0), location: 0)] + wedge(away, far) + wedge(toward, near)
            + [Gradient.Stop(color: .white.opacity(0), location: 1)]
        return .conicGradient(Gradient(stops: stops), center: center, angle: .zero)
    }
}

/// Type that runs round the record.
enum RecordPrint {
    /// The label's print over the art: a darker printed band at the rim, so the rim text reads on any art; the text
    /// itself in small caps; a fine raised edge; and the matrix number etched in the dead wax outside.
    static func label(_ context: inout GraphicsContext, face: RecordFace, center c: CGPoint, recordRadius r: CGFloat) {
        let label = r * VinylGeometry.labelToRecord
        let disc = Path(ellipseIn: CGRect(x: c.x - label, y: c.y - label, width: label * 2, height: label * 2))
        context.fill(
            disc,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.66), .init(color: .black.opacity(0.42), location: 0.8),
                    .init(color: .black.opacity(0.5), location: 1),
                ]), center: c, startRadius: 0, endRadius: label))
        arc(
            &context, face.rimText, center: c, radius: label * 0.855, size: max(2.4, label * 0.098),
            color: .white.opacity(0.9), start: -90, smallCaps: true)
        let hub = label * 0.13
        context.stroke(
            Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)),
            with: .color(.white.opacity(0.3)), lineWidth: 0.4)
        let inner = r * VinylGeometry.innerGrooveToRecord
        arc(
            &context, face.matrix, center: c, radius: label + (inner - label) * 0.62, size: max(2, r * 0.021),
            color: .white.opacity(0.24), start: 150, monospaced: true)
    }

    /// `text` laid round a circle of `radius`, its middle at `start` degrees (−90 is the top), reading clockwise. Too
    /// long a text shrinks to fit the circle. In small caps, each word's first letter is a size larger.
    static func arc(
        _ context: inout GraphicsContext, _ text: String, center c: CGPoint, radius: CGFloat, size: CGFloat,
        color: Color, start: Double, smallCaps: Bool = false, monospaced: Bool = false
    ) {
        let chars = Array(text)
        func glyphs(_ size: CGFloat) -> [(GraphicsContext.ResolvedText, CGFloat)] {
            var initial = true
            return chars.map { ch in
                let big = !smallCaps || initial || !ch.isLetter
                initial = !(ch.isLetter || ch.isNumber)
                let s = big ? size : size * 0.8
                let font: Font =
                    monospaced
                    ? .system(size: s, weight: .medium, design: .monospaced)
                    : .system(size: s, weight: .semibold, design: .default)
                let resolved = context.resolve(Text(String(ch)).font(font).foregroundStyle(color))
                let width = resolved.measure(in: CGSize(width: 200, height: 200)).width
                return (resolved, width + size * 0.16)
            }
        }
        var size = size
        var laid = glyphs(size)
        let room = 2 * .pi * radius * 0.94
        let total = laid.reduce(0) { $0 + $1.1 }
        if total > room {
            size *= room / total
            laid = glyphs(size)
        }
        let length = laid.reduce(0) { $0 + $1.1 }
        var angle = start * .pi / 180 - Double(length / radius) / 2
        for (glyph, width) in laid {
            let a = angle + Double(width / radius) / 2
            var g = context
            g.translateBy(x: c.x, y: c.y)
            g.rotate(by: .radians(a + .pi / 2))
            g.draw(glyph, at: CGPoint(x: 0, y: -radius), anchor: .center)
            angle += Double(width / radius)
        }
    }
}
