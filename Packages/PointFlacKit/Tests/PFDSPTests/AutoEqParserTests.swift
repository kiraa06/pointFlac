import Foundation
import Testing

@testable import PFDSP

/// The parser for an AutoEq `ParametricEQ.txt`, the Equalizer APO format the user imports.
@Suite("AutoEq parser")
struct AutoEqParserTests {
    /// A file in AutoEq's published layout: a preamp line and ten filters, LSC first and HSC last.
    static let sample = """
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 4.5 dB Q 0.70
        Filter 2: ON PK Fc 170 Hz Gain -2.3 dB Q 1.47
        Filter 3: ON PK Fc 666 Hz Gain 0.4 dB Q 1.44
        Filter 4: ON PK Fc 1400 Hz Gain -1.3 dB Q 2.18
        Filter 5: ON PK Fc 3050 Hz Gain 2.8 dB Q 3.10
        Filter 6: ON PK Fc 5275 Hz Gain 3.1 dB Q 3.96
        Filter 7: ON PK Fc 7619 Hz Gain -3.3 dB Q 4.48
        Filter 8: ON PK Fc 9200 Hz Gain 1.0 dB Q 5.00
        Filter 9: ON PK Fc 12500 Hz Gain -0.7 dB Q 2.00
        Filter 10: ON HSC Fc 10000 Hz Gain 2.2 dB Q 0.70
        """

    @Test("a real-format file of ten filters and a preamp parses exactly")
    func parsesSample() throws {
        let r = try AutoEqParser.parse(Self.sample)
        #expect(r.preampDb == -6.2)
        #expect(r.bands.count == 10)
        #expect(r.bands[0] == EQBand(type: .lowShelf, frequency: 105, gainDb: 4.5, q: 0.7))
        #expect(r.bands[1] == EQBand(type: .peak, frequency: 170, gainDb: -2.3, q: 1.47))
        #expect(r.bands[6] == EQBand(type: .peak, frequency: 7619, gainDb: -3.3, q: 4.48))
        #expect(r.bands[9] == EQBand(type: .highShelf, frequency: 10_000, gainDb: 2.2, q: 0.7))
    }

    @Test("CRLF line endings, trailing whitespace and blank lines are fine")
    func toleratesLayout() throws {
        let text =
            "Preamp: -3 dB  \r\n\r\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0 \t\r\n"
            + "Filter 2: ON PK Fc 200 Hz Gain 2 dB Q 2\r\n"
        let r = try AutoEqParser.parse(text)
        #expect(r.preampDb == -3)
        #expect(r.bands.map(\.frequency) == [100, 200])
    }

    @Test("an OFF filter is skipped")
    func skipsOff() throws {
        let text = """
            Preamp: -1.0 dB
            Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0
            Filter 2: OFF PK Fc 200 Hz Gain 2 dB Q 1.0
            Filter 3: ON PK Fc 300 Hz Gain 3 dB Q 1.0
            """
        let r = try AutoEqParser.parse(text)
        #expect(r.bands.map(\.frequency) == [100, 300])
    }

    @Test("every AutoEq filter type maps onto the model")
    func mapsTypes() throws {
        let text = """
            Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0
            Filter 2: ON LSC Fc 100 Hz Gain 1 dB Q 0.7
            Filter 3: ON HSC Fc 100 Hz Gain 1 dB Q 0.7
            Filter 4: ON LS Fc 100 Hz Gain 1 dB Q 0.7
            Filter 5: ON HS Fc 100 Hz Gain 1 dB Q 0.7
            Filter 6: ON LP Fc 100 Hz Q 0.7
            Filter 7: ON HP Fc 100 Hz Q 0.7
            Filter 8: ON NO Fc 100 Hz Q 5
            """
        let r = try AutoEqParser.parse(text)
        #expect(
            r.bands.map(\.type)
                == [.peak, .lowShelf, .highShelf, .lowShelf, .highShelf, .lowPass, .highPass, .notch])
        // Types without a gain keep 0 dB, and a missing preamp is 0.
        #expect(r.bands[5].gainDb == 0)
        #expect(r.preampDb == 0)
    }

    @Test("a decimal point is always a point, whatever the device locale")
    func localeIndependent() throws {
        let r = try AutoEqParser.parse("Preamp: -6.25 dB\nFilter 1: ON PK Fc 1000.5 Hz Gain -0.5 dB Q 0.75")
        #expect(r.preampDb == -6.25)
        #expect(r.bands[0].frequency == 1000.5)
        // A comma is not a decimal separator in this format.
        #expect(throws: AutoEqParser.ParseError.unsupportedLine(1)) { try AutoEqParser.parse("Preamp: -6,25 dB") }
    }

    @Test("a malformed line throws with its 1-based number")
    func malformedLine() {
        let text = "Preamp: -1 dB\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0\nFilter 2: ON PK Fc abc Hz Gain 1 dB Q 1.0"
        #expect(throws: AutoEqParser.ParseError.unsupportedLine(3)) { try AutoEqParser.parse(text) }
    }

    @Test("unknown filter types, unknown lines and missing fields throw")
    func unsupported() {
        let bad: [(String, Int)] = [
            ("Filter 1: ON XX Fc 100 Hz Gain 1 dB Q 1.0", 1),
            ("Preamp: -1 dB\nGraphicEQ: 100 1; 200 2", 2),
            ("Filter 1: ON PK Fc 100 Hz Q 1.0", 1),  // a peak needs a gain
            ("Filter 1: ON PK Gain 1 dB Q 1.0", 1),  // and a frequency
            ("Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0 Bogus", 1),
            ("Filter 1: ON PK Fc nan Hz Gain 1 dB Q 1.0", 1),
            ("Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 0", 1),
            ("Preamp: loud dB", 1),
        ]
        for (text, line) in bad {
            #expect(throws: AutoEqParser.ParseError.unsupportedLine(line), "\(text)") { try AutoEqParser.parse(text) }
        }
    }

    @Test("more than 20 filters throws tooManyBands, and exactly 20 is fine")
    func bandLimit() throws {
        func file(_ n: Int) -> String {
            (1...n).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1 dB Q 1.0" }.joined(separator: "\n")
        }
        #expect(try AutoEqParser.parse(file(20)).bands.count == 20)
        #expect(throws: AutoEqParser.ParseError.tooManyBands) { try AutoEqParser.parse(file(21)) }
    }
}
