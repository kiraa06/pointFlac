import PFDesign
import SwiftUI

extension Color {
    /// A design colour given as 0xRRGGBB (`DeckDesign`).
    init(deckHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// A deck design's colours as the deck draws them: as designed, or as greys of matching luma in Monochrome. Only the
/// album's artwork keeps its colour there, as everywhere else in the app.
struct DeckColors {
    let monochrome: Bool
    let dark: Bool

    func callAsFunction(_ hex: UInt32) -> Color {
        let color = Color(deckHex: hex)
        return monochrome ? color.monochrome(dark: dark) : color
    }
}
