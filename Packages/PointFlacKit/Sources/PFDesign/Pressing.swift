/// A playlist's pressing colour: the tint of its vinyl and the ink of its badge (spec §3, "Pressing colours"). The
/// raw value is what the library stores.
public enum PressingColour: String, CaseIterable, Sendable {
    case ruby, amber, citrine, jade, ocean, violet, smoke, onyx

    /// The colour Favourites is pressed in until the user picks another.
    public static let favouritesDefault = PressingColour.ruby

    /// The order a new playlist takes colours in: warm to cool, then the two quiet ones, Ruby last because Favourites
    /// already has it.
    static let rotation: [PressingColour] = [.amber, .jade, .ocean, .violet, .citrine, .smoke, .onyx, .ruby]

    /// The name the picker announces.
    public var name: String {
        switch self {
        case .ruby: "Ruby"
        case .amber: "Amber"
        case .citrine: "Citrine"
        case .jade: "Jade"
        case .ocean: "Ocean"
        case .violet: "Violet"
        case .smoke: "Smoke"
        case .onyx: "Onyx"
        }
    }

    /// The colour as 0xRRGGBB.
    public var hex: UInt32 {
        switch self {
        case .ruby: 0xC2203A
        case .amber: 0xE08A1E
        case .citrine: 0xD9B43A
        case .jade: 0x1E9E74
        case .ocean: 0x1F6FB8
        case .violet: 0x7A4FD1
        case .smoke: 0x8C8F96
        case .onyx: 0x1A1A1E
        }
    }

    /// The colour for a new playlist, given the colours the existing ones use: the first in the rotation that is
    /// free. When every colour is taken, the least-used one, ties going to the earliest in the rotation (spec §8.6).
    public static func next(after used: [PressingColour]) -> PressingColour {
        var uses: [PressingColour: Int] = [:]
        for colour in used { uses[colour, default: 0] += 1 }
        let fewest = rotation.map { uses[$0, default: 0] }.min() ?? 0
        return rotation.first { uses[$0, default: 0] == fewest } ?? .amber
    }
}

/// The letters on a playlist's centre badge.
public enum PressingMonogram {
    /// The initials of the name's first two words, upper-cased: "Late Night Drives" is "LN". A word's initial is its
    /// first letter or digit, past any leading punctuation; a word with neither (an emoji) gives its first character.
    /// Never a heart for Favourites: the badge draws that itself.
    public static func letters(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        return words.map { word -> String in
            let initial = word.first(where: { $0.isLetter || $0.isNumber }) ?? word.first
            return initial.map { String($0).uppercased() } ?? ""
        }.joined()
    }
}
