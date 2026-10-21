import Foundation
import Testing

@testable import PFDSP

/// Importing a user's ParametricEQ.txt: the size cap before any read, the text encodings, the naming, and the
/// refusals the alert explains.
@Suite("AutoEq import")
struct AutoEqImportTests {
    static let file =
        "Preamp: -6.2 dB\nFilter 1: ON LSC Fc 105 Hz Gain 4.5 dB Q 0.70\nFilter 2: ON PK Fc 170 Hz Gain -2.3 dB Q 1.47\n"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AutoEqImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a file becomes a switched-on correction named after it and credited to it")
    func fromFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Sennheiser HD 650 ParametricEQ.txt")
        try Data(Self.file.utf8).write(to: url)
        let c = try AutoEqImport.correction(contentsOf: url).get()
        #expect(c.enabled)
        #expect(c.name == "Sennheiser HD 650")
        #expect(c.author.isEmpty)
        #expect(c.source == .autoEq(fileName: "Sennheiser HD 650 ParametricEQ.txt"))
        #expect(c.preampDb == -6.2)
        #expect(c.bands.count == 2)
    }

    @Test("a file over the cap is refused from its size, and data over it as well")
    func sizeCap() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "huge.txt")
        try Data(repeating: 0x20, count: AutoEqImport.maxBytes + 1).write(to: url)
        #expect(AutoEqImport.correction(contentsOf: url) == .failure(.tooLarge))
        let big = Data(repeating: 0x20, count: AutoEqImport.maxBytes + 1)
        #expect(AutoEqImport.correction(data: big, fileName: "x.txt") == .failure(.tooLarge))
        // Exactly at the cap is read (and here, being blank, has no filters).
        let edge = Data(repeating: 0x20, count: AutoEqImport.maxBytes)
        #expect(AutoEqImport.correction(data: edge, fileName: "x.txt") == .failure(.noFilters))
    }

    @Test("UTF-16 with a byte-order mark, either way round, and UTF-8 with one")
    func encodings() throws {
        var little = Data([0xFF, 0xFE])
        for unit in Self.file.utf16 { little.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        var big = Data([0xFE, 0xFF])
        for unit in Self.file.utf16 { big.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)]) }
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(Self.file.utf8)
        for data in [little, big, bom] {
            #expect(try AutoEqImport.correction(data: data, fileName: "a.txt").get().bands.count == 2)
        }
        #expect(AutoEqImport.correction(data: Data([0xC3, 0x28, 0x41]), fileName: "a.txt") == .failure(.notText))
    }

    @Test("an unreadable line is named and quoted, as the parser numbers it")
    func quotesTheLine() {
        let text =
            "\u{FEFF}# Sennheiser HD 600\r\nPreamp: -6.2 dB\r\nFilter 1: ON PK Fc 105 Hz Gain -2.3 dB Q 0.70\r\n"
            + "   GraphicEQ: 25 -1.2; 40 -0.9   \r\n"
        #expect(
            AutoEqImport.correction(data: Data(text.utf8), fileName: "a.txt")
                == .failure(.unsupportedLine(number: 4, text: "GraphicEQ: 25 -1.2; 40 -0.9")))
        let long = "Filter 1: ON XX " + String(repeating: "9", count: 200)
        let result = AutoEqImport.correction(data: Data(long.utf8), fileName: "a.txt")
        guard case .failure(.unsupportedLine(1, let quoted)) = result else {
            Issue.record("expected line 1 refused, got \(result)")
            return
        }
        #expect(quoted.count == 80)
    }

    @Test("no filters on, too many, and a file that can't be opened are refused")
    func refusals() {
        #expect(AutoEqImport.correction(data: Data("Preamp: -3 dB\n".utf8), fileName: "a.txt") == .failure(.noFilters))
        let many = (1...21).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        #expect(AutoEqImport.correction(data: Data(many.utf8), fileName: "a.txt") == .failure(.tooManyBands))
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.txt")
        guard case .failure(.unreadable) = AutoEqImport.correction(contentsOf: missing) else {
            Issue.record("a missing file was not refused as unreadable")
            return
        }
    }

    @Test("names drop the extension and AutoEq's ParametricEQ suffix")
    func names() {
        #expect(AutoEqImport.name(fromFileName: "Sennheiser HD 600 ParametricEQ.txt") == "Sennheiser HD 600")
        #expect(AutoEqImport.name(fromFileName: "HD 600_ParametricEQ.txt") == "HD 600")
        #expect(AutoEqImport.name(fromFileName: "my eq.txt") == "my eq")
        #expect(AutoEqImport.name(fromFileName: " ParametricEQ.txt") == "Imported correction")
    }
}
