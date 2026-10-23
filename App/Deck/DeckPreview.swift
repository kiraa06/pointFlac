import PFDesign
import SwiftUI

/// A still, non-interactive picture of the whole deck in `design`, with a record in `recordStyle`, for the Customize
/// deck picker. It draws exactly what the player draws, at any size, with the needle resting a little way into side A.
///
/// PLACEHOLDER: the deck-rendering task replaces this body with the real renderer. The signature is fixed: the picker
/// task builds against it and must not edit this file.
struct DeckPreview: View {
    let design: DeckDesign
    let recordStyle: RecordStyle
    /// The album whose label (and, for a picture disc, whole record) is shown; nil draws a generated label.
    var album: AlbumCard?

    @Environment(\.isMonochrome) private var mono
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = DeckColors(monochrome: mono, dark: scheme == .dark)
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: w * 0.07, style: .continuous).fill(colors(design.plinthBase))
                Circle().fill(Color.black)
                    .frame(width: w * 0.66, height: w * 0.66)
                    .offset(x: w * 0.08, y: w * 0.08)
            }
        }
        .aspectRatio(360.0 / 330.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
