import PFCore
import PFDesign
import SwiftUI
import UIKit

extension PlaylistCard {
    /// What a playlist's card ID starts with: `playlist:favourites`.
    static let cardPrefix = "playlist:"

    /// The card ID the player knows playlist `id` by.
    static func cardID(_ id: String) -> String { cardPrefix + id }

    /// The playlist behind card ID `cardID`, or nil when it is an album's.
    static func playlistID(fromCard cardID: String) -> String? {
        cardID.hasPrefix(cardPrefix) ? String(cardID.dropFirst(cardPrefix.count)) : nil
    }

    /// "0 songs", "1 song", "24 songs".
    static func songs(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }

    /// Its song count in words, as the strip's second line says it.
    var countText: String { Self.songs(songCount) }

    /// What VoiceOver calls its disc (spec §6).
    var accessibilityLabel: String { "\(name), playlist, \(countText)" }

    /// The words for the songs' total time: "28 min", "1 hr 4 min".
    func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}

extension AlbumCard {
    /// The playlist this card plays, or nil for an album.
    var playlistID: String? { pressing?.id ?? PlaylistCard.playlistID(fromCard: id) }

    /// A playlist's card as it was put on the deck, with the playlist's name and colour as they are now: a rename or a
    /// new colour shows on the deck at once, while the songs it was cued with (and so its label's covers and count)
    /// stay until it is cued again. An album's card, or a playlist since deleted, is returned as it is.
    func restyled(from playlists: [PlaylistCard]) -> AlbumCard {
        guard let look = pressing, let live = playlists.first(where: { $0.id == look.id }),
            live.name != look.title || live.colour != look.colour
        else { return self }
        let fresh = PressingLook(
            title: live.name, colour: live.colour, coverAlbumIDs: look.coverAlbumIDs, songCount: look.songCount,
            isFavourites: look.isFavourites, id: look.id)
        return AlbumCard(
            id: id, title: live.name, artist: artist, year: year, artwork: artwork, trackCount: trackCount,
            bestFormat: bestFormat, addedAt: addedAt, listens: listens, lastListened: lastListened, bestBits: bestBits,
            bestRate: bestRate, pressing: fresh)
    }
}

extension PressingLook {
    /// A playlist being made: its name (or the default it will get), its colour, and the covers of the songs it will
    /// start with.
    static func draft(name: String, colour: PressingColour, covers: [String], songCount: Int) -> PressingLook {
        PressingLook(
            title: name, colour: colour, coverAlbumIDs: covers, songCount: songCount, isFavourites: false,
            id: "draft")
    }

    /// A bare pressing in `colour`, for the colour swatches: guilloché paper, no title.
    static func swatch(_ colour: PressingColour) -> PressingLook {
        PressingLook(title: "", colour: colour, coverAlbumIDs: [], songCount: 0, isFavourites: false, id: "swatch")
    }
}

extension PressingColour {
    /// The colour itself, for the interface around a pressing (the Create and Play buttons, the heart): its grey of the
    /// same luma under Monochrome, as the vinyl turns.
    func ui(monochrome: Bool) -> Color {
        let rgb = PressingRGB(hex)
        return Color(monochrome ? rgb.grey : rgb)
    }

    /// Light enough that white type on it would not read: Citrine and Smoke take dark type.
    var wantsDarkInk: Bool { self == .citrine || self == .smoke }
}

extension ArtPalette {
    /// A pressing's palette: the glow and the wash a playlist tints the player with, all in its pressing colour's hue,
    /// so Favourites lights the deck ruby. Smoke and Onyx, which have next to no hue, give quiet greys.
    init(pressing colour: PressingColour) {
        let rgb = PressingRGB(colour.hex)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).getHue(
            &hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let h = Double(hue)
        let s = Double(saturation)
        func shifted(_ x: Double) -> Double { (h + x + 1).truncatingRemainder(dividingBy: 1) }
        self.init(
            base: Color(hue: h, saturation: min(s, 0.82), brightness: max(Double(brightness), 0.78)),
            deep: Color(hue: shifted(-0.02), saturation: min(s, 0.8), brightness: 0.5),
            night: Color(hue: shifted(-0.04), saturation: min(s, 0.75), brightness: 0.24),
            sun: Color(hue: shifted(0.05), saturation: min(s, 0.6), brightness: 0.96),
            sea: Color(hue: shifted(-0.06), saturation: min(s, 0.72), brightness: 0.68),
            line: Color(hue: h, saturation: min(s, 0.85), brightness: 0.62))
    }

    /// The palette a record tints the player with: a playlist's pressing colour, or the album's own.
    static func record(_ album: AlbumCard?) -> ArtPalette {
        if let look = album?.pressing { return ArtPalette(pressing: look.colour) }
        return ArtPalette(seed: album?.id ?? "pointflac")
    }
}
