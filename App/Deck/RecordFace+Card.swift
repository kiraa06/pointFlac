import PFDesign
import SwiftUI

extension RecordFace {
    /// The record a card is pressed as: a playlist's custom pressing when the card carries one (whatever the record
    /// style: a pressing's colour is its identity), else the album's record in `style`. Every place that draws a card's
    /// record builds it here (the deck, the cover's peeking record, the hand-off's record in flight, the Customize deck
    /// preview), so what flies is what lands.
    static func face(for card: AlbumCard, side: String, bands: [CGFloat], style: RecordStyle) -> RecordFace {
        if let look = card.pressing {
            return RecordFace(pressing: look, side: side, bands: bands)
        }
        return RecordFace(album: card, side: side, bands: bands, style: style)
    }
}
