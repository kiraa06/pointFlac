import Foundation
import Testing

@testable import PFDesign

@Suite("Pressing colours")
struct PressingColourTests {
    @Test("eight colours, in the picker's order, with the spec's names and hex values")
    func catalogue() {
        #expect(PressingColour.allCases == [.ruby, .amber, .citrine, .jade, .ocean, .violet, .smoke, .onyx])
        #expect(
            PressingColour.allCases.map(\.name) == [
                "Ruby", "Amber", "Citrine", "Jade", "Ocean", "Violet", "Smoke", "Onyx",
            ])
        #expect(
            PressingColour.allCases.map(\.hex) == [
                0xC2203A, 0xE08A1E, 0xD9B43A, 0x1E9E74, 0x1F6FB8, 0x7A4FD1, 0x8C8F96, 0x1A1A1E,
            ])
    }

    @Test("the stored ID is the lower-case case name, and Favourites is Ruby")
    func ids() {
        #expect(PressingColour.ruby.rawValue == "ruby")
        #expect(PressingColour(rawValue: "ocean") == .ocean)
        #expect(PressingColour(rawValue: "teal") == nil)
        #expect(PressingColour.favouritesDefault == .ruby)
    }

    @Test(
        "a new playlist takes the next colour in the rotation: Amber, Jade, Ocean, Violet, Citrine, Smoke, Onyx, Ruby")
    func rotation() {
        #expect(PressingColour.next(after: []) == .amber)
        #expect(PressingColour.next(after: [.ruby]) == .amber)
        #expect(PressingColour.next(after: [.ruby, .amber]) == .jade)
        #expect(PressingColour.next(after: [.ruby, .amber, .jade]) == .ocean)
        #expect(PressingColour.next(after: [.ruby, .amber, .jade, .ocean]) == .violet)
        #expect(PressingColour.next(after: [.ruby, .amber, .jade, .ocean, .violet]) == .citrine)
        #expect(PressingColour.next(after: [.ruby, .amber, .jade, .ocean, .violet, .citrine]) == .smoke)
        #expect(PressingColour.next(after: [.ruby, .amber, .jade, .ocean, .violet, .citrine, .smoke]) == .onyx)
        #expect(PressingColour.next(after: [.amber, .jade, .ocean, .violet, .citrine, .smoke, .onyx]) == .ruby)
    }

    @Test("colours in use are skipped wherever they sit, and order of use does not matter")
    func skipping() {
        #expect(PressingColour.next(after: [.jade, .ruby]) == .amber)
        #expect(PressingColour.next(after: [.amber, .ocean, .ruby]) == .jade)
        #expect(PressingColour.next(after: [.violet, .jade, .amber, .ruby, .ocean]) == .citrine)
        #expect(PressingColour.next(after: [.amber, .amber, .jade]) == .ocean)
    }

    @Test("with every colour in use, the least-used one, ties broken by rotation order (spec §8.6)")
    func allInUse() {
        let all = PressingColour.allCases
        #expect(PressingColour.next(after: all) == .amber)
        #expect(PressingColour.next(after: all + [.amber]) == .jade)
        #expect(PressingColour.next(after: all + [.jade]) == .amber)
        #expect(PressingColour.next(after: all + [.amber, .jade]) == .ocean)
        #expect(PressingColour.next(after: all + [.amber, .ocean, .ocean]) == .jade)
        #expect(PressingColour.next(after: all + [.amber, .jade, .ocean, .violet, .citrine, .smoke, .onyx]) == .ruby)
        #expect(PressingColour.next(after: all + all) == .amber)
    }
}

@Suite("Pressing monogram")
struct PressingMonogramTests {
    @Test("the initials of the first two words, upper-cased")
    func initials() {
        #expect(PressingMonogram.letters("Late Night Drives") == "LN")
        #expect(PressingMonogram.letters("gym") == "G")
        #expect(PressingMonogram.letters("  road  trip 2026") == "RT")
        #expect(PressingMonogram.letters("sunday\tmorning\ncoffee") == "SM")
        #expect(PressingMonogram.letters("2026 summer") == "2S")
    }

    @Test("a word's initial is its first letter or digit, past any leading punctuation")
    func punctuation() {
        #expect(PressingMonogram.letters("(live) sessions") == "LS")
        #expect(PressingMonogram.letters("“quiet” hours") == "QH")
    }

    @Test("words with no letter or digit are skipped: an ampersand or a dash is not an initial")
    func symbolWords() {
        #expect(PressingMonogram.letters("Rock & Roll") == "RR")
        #expect(PressingMonogram.letters("Me - Time") == "MT")
        #expect(PressingMonogram.letters("& more") == "M")
        #expect(PressingMonogram.letters("🌊 waves") == "W")
    }

    @Test("a name with no letter or digit at all gives its first characters, so an emoji name still has a mark")
    func emoji() {
        #expect(PressingMonogram.letters("🔥🔥🔥") == "🔥")
        #expect(PressingMonogram.letters("🌊") == "🌊")
        #expect(PressingMonogram.letters("🔥 🌊 ✨") == "🔥🌊")
    }

    @Test("Favourites gets its letter like any name: the heart is the badge's, never the monogram's")
    func favourites() {
        #expect(PressingMonogram.letters("Favourites") == "F")
    }

    @Test("a blank name gives no letters")
    func blank() {
        #expect(PressingMonogram.letters("") == "")
        #expect(PressingMonogram.letters("   ") == "")
    }
}

@Suite("Pressing IDs")
struct PressingIDTests {
    @Test("a playlist's own ID loses one leading playlist: prefix, so a card's ID can be passed as well")
    func bare() {
        #expect(PressingID.bare("favourites") == "favourites")
        #expect(PressingID.bare("playlist:favourites") == "favourites")
        #expect(PressingID.bare("playlist:7c3e9b1a-52d0") == "7c3e9b1a-52d0")
        #expect(PressingID.bare("playlist:playlist:x") == "playlist:x")
    }

    @Test("the card ID is playlist:<bare id>, never doubled")
    func card() {
        #expect(PressingID.card("favourites") == "playlist:favourites")
        #expect(PressingID.card("playlist:favourites") == "playlist:favourites")
    }

    @Test("the matrix: PFL-FAV-A1 for Favourites, PFL-MIX-<first 4 of the bare ID>-A1 otherwise")
    func matrix() {
        #expect(PressingID.matrix(id: "favourites", isFavourites: true, side: "A") == "PFL-FAV-A1")
        #expect(PressingID.matrix(id: "playlist:favourites", isFavourites: true, side: "B") == "PFL-FAV-B1")
        let uuid = "7c3e9b1a-52d0-4f8e-a1c2-9e7d3b5f0a14"
        #expect(PressingID.matrix(id: uuid, isFavourites: false, side: "A") == "PFL-MIX-7C3E-A1")
        #expect(PressingID.matrix(id: "playlist:" + uuid, isFavourites: false, side: "B") == "PFL-MIX-7C3E-B1")
        #expect(PressingID.matrix(id: "playlist:", isFavourites: false, side: "A") == "PFL-MIX-0000-A1")
    }
}

@Suite("Pressing rim text")
struct PressingRimTests {
    @Test("the count reads NO SONGS YET, 1 SONG, 24 SONGS (spec §8.5)")
    func count() {
        #expect(PressingRim.count(0) == "NO SONGS YET")
        #expect(PressingRim.count(1) == "1 SONG")
        #expect(PressingRim.count(24) == "24 SONGS")
        #expect(
            PressingRim.text(title: "Favourites", songs: 24, side: "A") == "FAVOURITES · 24 SONGS · SIDE A · 33⅓ RPM")
        #expect(PressingRim.text(title: "Demos", songs: 0, side: "B") == "DEMOS · NO SONGS YET · SIDE B · 33⅓ RPM")
    }

    /// One unit per character: enough to test the fitting without a font.
    private func width(_ text: String) -> Double { Double(text.count) }

    @Test("a title that fits at four-fifths size or more is kept whole")
    func fits() {
        let full = PressingRim.text(title: "Late Night Drives", songs: 6, side: "A")
        let room = width(full) * 0.85
        #expect(PressingRim.fitted(title: "Late Night Drives", songs: 6, side: "A", room: room, width: width) == full)
    }

    @Test("a 60-character title is cut short with an ellipsis rather than shrunk below four-fifths size")
    func longTitle() {
        let title = String(repeating: "Long Name ", count: 6)
        #expect(title.count == 60)
        let room = 64.0
        let fitted = PressingRim.fitted(title: title, songs: 24, side: "A", room: room, width: width)
        #expect(fitted.hasSuffix(" · 24 SONGS · SIDE A · 33⅓ RPM"))
        #expect(fitted.hasPrefix("LONG NAME LONG"))
        #expect(fitted.contains("… · 24 SONGS"))
        #expect(!fitted.contains(" … "))
        #expect(width(fitted) <= room / 0.8)
        #expect(width(fitted) >= room / 0.8 - 2)
    }

    @Test("with no room for any of the title, the ellipsis stands for it")
    func noRoom() {
        let fitted = PressingRim.fitted(title: "Anything", songs: 3, side: "A", room: 10, width: width)
        #expect(fitted == "… · 3 SONGS · SIDE A · 33⅓ RPM")
    }
}

@Suite("Pressing covers")
struct PressingCoversTests {
    @Test("the label's covers: repeats dropped, the first occurrence kept, then the first six")
    func distinct() {
        #expect(
            PressingCovers.distinct(["a", "b", "a", "c", "b", "d", "e", "f", "g"]) == ["a", "b", "c", "d", "e", "f"])
        #expect(PressingCovers.distinct(["x", "x", "x"]) == ["x"])
        #expect(PressingCovers.distinct([]) == [])
        #expect(PressingCovers.maximum == 6)
    }
}
