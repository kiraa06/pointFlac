import PFDesign
import SwiftUI

/// A still, non-interactive picture of the whole deck in `design`, with a record in `recordStyle`, for the Customize
/// deck picker. It draws exactly what the player draws, at any size, with the needle resting a little way into side A.
///
/// The deck is laid out at the player's own size and scaled to fit, so every detail keeps its proportions, and it is
/// flattened into one layer drawn at the size it shows, so a grid of previews stays light.
struct DeckPreview: View {
    let design: DeckDesign
    let recordStyle: RecordStyle
    /// The album whose label (and, for a picture disc, whole record) is shown; nil draws a generated label.
    var album: AlbumCard?

    @Environment(\.isMonochrome) private var mono
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    /// The player's deck on a 402-point-wide phone.
    static let reference = CGSize(width: 378, height: DeckLayout.height(forWidth: 378))

    var body: some View {
        let theme = Theme.look(stage: .deck, dark: scheme == .dark, monochrome: mono)
        let paint = DeckPaint(design: design, theme: theme)
        let layout = DeckLayout(size: Self.reference, design: design)
        GeometryReader { proxy in
            let scale = proxy.size.width / Self.reference.width
            DeckStill(paint: paint, layout: layout, face: face(layout))
                .frame(width: Self.reference.width, height: Self.reference.height)
                // Rendered at the resolution it is shown at, not the reference's, so fine lines stay crisp.
                .environment(\.displayScale, max(1, displayScale * scale))
                .drawingGroup()
                .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(Self.reference.width / Self.reference.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func face(_ layout: DeckLayout) -> RecordFace {
        guard let album else { return RecordFace(placeholderStyle: recordStyle) }
        return RecordFace(album: album, side: "A", bands: [0.86, 0.73, 0.6, 0.48], style: recordStyle)
    }
}

/// The deck with nothing moving: the same pieces the player composes, with the record at a fixed turn, the needle
/// down a little way into the side and the lamps lit.
private struct DeckStill: View {
    let paint: DeckPaint
    let layout: DeckLayout
    let face: RecordFace

    var body: some View {
        let position = layout.travel.position(forFraction: 0.12)
        ZStack(alignment: .topLeading) {
            DeckPlinth(paint: paint, layout: layout, live: false)
            DeckControls(paint: paint, layout: layout)
            DeckPlatter(paint: paint, layout: layout)
            ArmFurniture(paint: paint, layout: layout)
            StrobeCreep(paint: paint, layout: layout, phase: 0)
                .position(layout.recordCenter)
            RecordView(face: face, diameter: layout.recordRadius * 2, angle: 28)
                .position(layout.recordCenter)
            DeckSpindle(paint: paint, layout: layout)
            arm(position)
            DeckLamps(paint: paint, layout: layout, playing: true)
            if paint.design.controls == .dj {
                let key = DeckStartStop.frame(layout)
                StartStopKey(paint: paint, playing: true)
                    .frame(width: key.width, height: key.height)
                    .position(x: key.midX, y: key.midY)
            }
            let screen = DeckScreen.frame(in: layout.size)
            DeckDisplay(lines: lines, paint: paint)
                .frame(width: screen.width, height: screen.height)
                .position(x: screen.midX, y: screen.midY)
            if paint.design.plinth == .lacquer {
                LidReflection(paint: paint, layout: layout)
            }
        }
    }

    @ViewBuilder
    private func arm(_ position: Double) -> some View {
        if let arm = layout.pivoted {
            let m = ArmMetrics(arm: arm)
            let anchor = UnitPoint(x: 0.5, y: m.top / m.height)
            let center = CGPoint(x: arm.pivot.x, y: arm.pivot.y - m.top + m.height / 2)
            CueLever(paint: paint, arm: arm, lift: 0)
            ArmBody(paint: paint, arm: arm, silhouette: true, blur: 1.2)
                .opacity(0.5)
                .rotationEffect(.degrees(position), anchor: anchor)
                .offset(x: 2, y: 3)
                .position(center)
            ArmBody(paint: paint, arm: arm, silhouette: false)
                .rotationEffect(.degrees(position), anchor: anchor)
                .position(center)
            ArmCap(paint: paint, arm: arm)
        } else if let arm = layout.linear {
            let stylus = layout.needle(at: position)
            LinearRailView(paint: paint, layout: layout)
            CarriageBody(paint: paint, arm: arm, silhouette: true, blur: 1.2)
                .opacity(0.5)
                .position(x: stylus.x + 2, y: stylus.y + 3)
            CarriageBody(paint: paint, arm: arm, silhouette: false)
                .position(stylus)
        }
    }

    private var lines: [String] {
        ["A1 \(face.title.uppercased())·\(face.artist.uppercased())", "0:42  33⅓  96K/24"]
    }
}
