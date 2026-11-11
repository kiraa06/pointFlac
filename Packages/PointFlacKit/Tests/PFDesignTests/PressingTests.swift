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

    @Test("an emoji-only name gives its first character")
    func emoji() {
        #expect(PressingMonogram.letters("🔥🔥🔥") == "🔥")
        #expect(PressingMonogram.letters("🌊") == "🌊")
        #expect(PressingMonogram.letters("🌊 waves") == "🌊W")
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
