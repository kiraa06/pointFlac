import PFDesign
import SwiftUI

/// A still, non-interactive picture of the whole deck in `design`, with a record in `recordStyle`, for the Customize
/// deck picker. It draws exactly what the player draws, at any size, with the needle resting a little way into side A.
///
/// The deck is laid out at the player's own size and scaled to fit, so every detail keeps its proportions, and it is
/// flattened into one layer drawn at the size it shows, so a grid of previews stays light. Equatable on the design, the
/// style and the album: a picker redrawing for something else leaves its previews alone.
struct DeckPreview: View, Equatable {
    let design: DeckDesign
    let recordStyle: RecordStyle
    /// The album whose label (and, for a picture disc, whole record) is shown; nil draws a generated label.
    var album: AlbumCard?

    @Environment(\.isMonochrome) private var mono
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    /// The player's deck on a 402-point-wide phone.
    static let reference = CGSize(width: 378, height: DeckLayout.height(forWidth: 378))

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.design.id == b.design.id && a.recordStyle == b.recordStyle && a.album?.id == b.album?.id
    }

    var body: some View {
        let theme = Theme.look(stage: .deck, dark: scheme == .dark, monochrome: mono)
        GeometryReader { proxy in
            DeckStill(
                paint: DeckPaint(design: design, theme: theme),
                layout: DeckLayout(size: Self.reference, design: design),
                face: face, scale: proxy.size.width / Self.reference.width, displayScale: displayScale
            )
            .equatable()
        }
        .aspectRatio(Self.reference.width / Self.reference.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var face: RecordFace {
        guard let album else { return RecordFace(placeholderStyle: recordStyle) }
        return RecordFace(album: album, side: "A", bands: [0.86, 0.73, 0.6, 0.48], style: recordStyle)
    }
}

/// The deck with nothing moving, scaled to the preview: the player's layers (`DeckLayers`, `DeckMovingParts`) with the
/// record at a fixed turn, the needle down 12 % into the side and the lamps lit.
private struct DeckStill: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout
    let face: RecordFace
    let scale: CGFloat
    let displayScale: CGFloat

    var body: some View {
        DeckLayers(paint: paint, layout: layout, live: false, playing: true) {
            DeckMovingParts(
                paint: paint, layout: layout, strobePhase: 0, armPosition: layout.travel.position(forFraction: 0.12),
                lift: 0
            ) {
                RecordView(face: face, diameter: layout.recordRadius * 2, angle: 28)
                    .position(layout.recordCenter)
            }
        } front: {
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
        }
        .frame(width: layout.size.width, height: layout.size.height)
        // Rendered at the resolution it is shown at, not the reference's, so fine lines stay crisp.
        .environment(\.displayScale, max(1, displayScale * scale))
        .drawingGroup()
        .scaleEffect(scale, anchor: .topLeading)
    }

    private var lines: [String] {
        if face.placeholder { return ["SIDE \(face.side)  33⅓ RPM  STEREO", "0:42  33⅓  96K/24"] }
        return ["A1 \(face.title.uppercased())·\(face.artist.uppercased())", "0:42  33⅓  96K/24"]
    }
}
