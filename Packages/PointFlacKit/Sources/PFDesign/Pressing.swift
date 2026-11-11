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
    /// first letter or digit, past any leading punctuation, and a word with neither ("&", "-", an emoji) is skipped,
    /// so "Rock & Roll" is "RR". A name with no letter or digit anywhere keeps its first characters, so an emoji name
    /// still has a mark. Never a heart for Favourites: the badge draws that itself.
    public static func letters(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        func initial(_ word: Substring) -> Character? { word.first(where: { $0.isLetter || $0.isNumber }) }
        let lettered = words.compactMap(initial)
        let picked = lettered.isEmpty ? words.compactMap(\.first) : lettered
        return picked.prefix(2).map { String($0).uppercased() }.joined()
    }
}

/// A playlist's IDs as the pressing prints and plays them. The library's ID is `favourites` or a lower-case UUID; the
/// player knows the playlist as a card `playlist:<id>`. Either may be passed: one leading `playlist:` is dropped.
public enum PressingID {
    public static let prefix = "playlist:"

    /// The playlist's own ID.
    public static func bare(_ id: String) -> String {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    /// The card's ID: `playlist:<bare id>`.
    public static func card(_ id: String) -> String { prefix + bare(id) }

    /// The matrix etched in the dead wax: `PFL-FAV-A1`, or `PFL-MIX-<first 4 alphanumerics of the ID>-A1`, with the
    /// side's letter in place of the `A`.
    public static func matrix(id: String, isFavourites: Bool, side: String) -> String {
        if isFavourites { return "PFL-FAV-\(side)1" }
        let code = bare(id).filter { $0.isLetter || $0.isNumber }.prefix(4).uppercased()
        return "PFL-MIX-\(code.isEmpty ? "0000" : code)-\(side)1"
    }
}

/// The words curved round a pressing's label (spec §3, §8.5).
public enum PressingRim {
    /// "NO SONGS YET", "1 SONG", "24 SONGS".
    public static func count(_ songs: Int) -> String {
        switch songs {
        case ...0: "NO SONGS YET"
        case 1: "1 SONG"
        default: "\(songs) SONGS"
        }
    }

    /// `FAVOURITES · 24 SONGS · SIDE A · 33⅓ RPM`.
    public static func text(title: String, songs: Int, side: String) -> String {
        title.uppercased() + suffix(songs: songs, side: side)
    }

    /// The rim text as it fits round a circle with `room` for it, measured by `width`. The print may shrink to
    /// `minimumScale` of its size to fit; past that the title is cut short with an ellipsis instead, keeping as much
    /// of it as fits, so a long name never prints as specks.
    public static func fitted(
        title: String, songs: Int, side: String, room: Double, minimumScale: Double = 0.8,
        width: (String) -> Double
    ) -> String {
        let full = text(title: title, songs: songs, side: side)
        let limit = room / minimumScale
        if width(full) <= limit { return full }
        let letters = Array(title.uppercased())
        let tail = suffix(songs: songs, side: side)
        func cut(_ kept: Int) -> String {
            var head = letters.prefix(kept)
            while head.last?.isWhitespace == true { head.removeLast() }
            return String(head) + "…" + tail
        }
        // The longest cut that fits: the text grows with every letter kept.
        var low = 0
        var high = letters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if width(cut(middle)) <= limit { low = middle } else { high = middle - 1 }
        }
        return cut(low)
    }

    private static func suffix(songs: Int, side: String) -> String { " · \(count(songs)) · SIDE \(side) · 33⅓ RPM" }
}

/// The albums whose covers make a pressing's label.
public enum PressingCovers {
    /// The most wedges a label has.
    public static let maximum = 6

    /// The label's covers, in playlist order: each album once, at its first song, and no more than six.
    public static func distinct(_ albumIDs: [String]) -> [String] {
        var seen = Set<String>()
        var covers: [String] = []
        for id in albumIDs where seen.insert(id).inserted {
            covers.append(id)
            if covers.count == maximum { break }
        }
        return covers
    }
}
