import PFCore
import PFDesign
import SwiftUI

/// Everything that decides how a playlist's pressing looks (spec §3): its colour, its title, the covers its label is
/// made from and how many songs it holds. Nothing in it changes per frame, so a pressing is drawn once and only turned.
struct PressingLook: Hashable, Sendable {
    let title: String
    let colour: PressingColour
    /// Up to 6 distinct album IDs, in playlist order: the covers of the label's wedges. Empty draws the guilloché
    /// paper of an empty playlist.
    let coverAlbumIDs: [String]
    let songCount: Int
    let isFavourites: Bool
    /// The playlist's ID: `favourites`, or a lower-case UUID.
    let id: String

    /// The most covers a label shows.
    static let maxCovers = 6

    /// The covers the label draws: the first six.
    var covers: [String] { Array(coverAlbumIDs.prefix(Self.maxCovers)) }

    /// "NO SONGS YET", "1 SONG", "24 SONGS" (spec §8.5).
    var countText: String {
        switch songCount {
        case ...0: "NO SONGS YET"
        case 1: "1 SONG"
        default: "\(songCount) SONGS"
        }
    }

    /// The label's curved rim text: `FAVOURITES · 24 SONGS · SIDE A · 33⅓ RPM`, or `DEMOS · NO SONGS YET · SIDE A ·
    /// 33⅓ RPM` for an empty playlist.
    func rimText(side: String) -> String {
        "\(title.uppercased()) · \(countText) · SIDE \(side) · 33⅓ RPM"
    }

    /// The matrix etched in the dead wax: `PFL-FAV-A1`, or `PFL-MIX-<first 4 of the ID>-A1`.
    func matrix(side: String) -> String {
        if isFavourites { return "PFL-FAV-\(side)1" }
        let code = id.filter { $0.isLetter || $0.isNumber }.prefix(4).uppercased()
        return "PFL-MIX-\(code.isEmpty ? "0000" : code)-\(side)1"
    }

    /// The deck display's idle line: `FAVOURITES·24 SONGS`.
    var displayText: String { "\(title.uppercased())·\(countText)" }

    /// The badge's letters, for a playlist that is not Favourites (Favourites draws a heart).
    var monogram: String { PressingMonogram.letters(title) }
}

/// A pressing's colours as drawn: the vinyl, the ink its badge and rule are printed in, the cream paper and the dark
/// rim-text ink. In Monochrome the pressing colour turns to the grey of matching luma, as the vinyl does; the paper
/// and its black ink stay as printed, and the covers keep their colour.
struct PressingInk: Equatable {
    /// The vinyl's tint.
    let vinyl: Color
    /// The same, as components, for the shades the vinyl is mixed from.
    let vinylRGB: PressingRGB
    /// The pressing colour as printed on the cream paper: Amber and Citrine are darkened 30 % toward the rim text's
    /// ink (spec §8.4), so the heart, monogram and ring still print on the cream.
    let print: Color
    /// The label's cream paper, `#F2EBDD`.
    let paper: Color
    /// The rim text's dark ink, `#2B2A27`.
    let text: Color

    static let paperRGB = PressingRGB(0xF2EBDD)
    static let textRGB = PressingRGB(0x2B2A27)
    /// The warm brown of the paper's fibres and shading.
    static let fibre = PressingRGB(0x785F3C)

    init(colour: PressingColour, monochrome: Bool) {
        let tone = monochrome ? PressingRGB(colour.hex).grey : PressingRGB(colour.hex)
        vinylRGB = tone
        vinyl = Color(tone)
        let light = colour == .amber || colour == .citrine
        print = Color(light ? tone.mixed(with: Self.textRGB, 0.3) : tone)
        paper = Color(Self.paperRGB)
        text = Color(Self.textRGB)
    }
}

extension Color {
    init(_ rgb: PressingRGB, opacity: Double = 1) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b, opacity: opacity)
    }
}

/// A gamma-encoded sRGB colour, for the few sums the pressing does on its colours.
struct PressingRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// The grey of the same Rec. 709 luma: Monochrome's twin.
    var grey: PressingRGB {
        let y = Luma.grey(r: r, g: g, b: b)
        return PressingRGB(r: y, g: y, b: y)
    }

    static let black = PressingRGB(r: 0, g: 0, b: 0)
    static let white = PressingRGB(r: 1, g: 1, b: 1)

    /// Mixed toward `other` by `amount` (0 keeps this colour, 1 gives `other`).
    func mixed(with other: PressingRGB, _ amount: Double) -> PressingRGB {
        PressingRGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
    }
}

extension PressingColour {
    /// Onyx is black vinyl: pressed and lit exactly as the deck's own black records are.
    var isBlackVinyl: Bool { self == .onyx }
}
