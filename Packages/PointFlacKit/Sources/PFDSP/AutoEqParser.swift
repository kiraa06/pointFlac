import Foundation

/// Reads an AutoEq `ParametricEQ.txt` (the Equalizer APO layout) into a preamp and a band list.
///
/// ```
/// Preamp: -6.2 dB
/// Filter 1: ON PK Fc 105 Hz Gain -2.3 dB Q 0.70
/// ```
///
/// Types: `PK`, `LSC`/`LS`, `HSC`/`HS`, `LP`, `HP` and `NO`. `OFF` filters are skipped. The parser is strict about
/// anything it does not understand rather than guessing, and it never clamps: run `SoundSettings.clamped()` on the
/// result before it reaches the audio thread.
public enum AutoEqParser {
    public enum ParseError: Error, Equatable, Sendable {
        /// A line the parser does not recognise or cannot read; 1-based.
        case unsupportedLine(Int)
        /// More than `maxBands` filters are on.
        case tooManyBands
    }

    /// The model holds at most this many bands.
    public static let maxBands = 20

    /// Q for a filter whose line gives none (the Butterworth value).
    private static let defaultQ = 0.7071

    public static func parse(_ text: String) throws -> (preampDb: Double, bands: [EQBand]) {
        var preamp = 0.0
        var bands: [EQBand] = []
        // `split` on Character treats "\r\n" as one grapheme, so CRLF files need no special case; `newlines` also
        // covers a lone CR.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.unsupportedLine(number) }
            let head = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let tokens = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)

            if head == "preamp" {
                guard tokens.count == 2, tokens[1].lowercased() == "db", let v = decimal(tokens[0]) else {
                    throw ParseError.unsupportedLine(number)
                }
                preamp = v
            } else if isFilterHead(head) {
                guard let band = try filter(tokens, line: number) else { continue }
                bands.append(band)
                if bands.count > maxBands { throw ParseError.tooManyBands }
            } else {
                throw ParseError.unsupportedLine(number)
            }
        }
        return (preamp, bands)
    }

    /// "filter", "filter 3" or "filter3".
    private static func isFilterHead(_ head: String) -> Bool {
        guard head.hasPrefix("filter") else { return false }
        let rest = head.dropFirst("filter".count).trimmingCharacters(in: .whitespaces)
        return rest.allSatisfy(\.isASCII) && rest.allSatisfy(\.isNumber)
    }

    private static func filterType(_ code: String) -> FilterType? {
        switch code.uppercased() {
        case "PK": .peak
        case "LSC", "LS": .lowShelf
        case "HSC", "HS": .highShelf
        case "LP": .lowPass
        case "HP": .highPass
        case "NO": .notch
        default: nil
        }
    }

    /// `nil` for an OFF filter. Tokens are everything after the colon.
    private static func filter(_ tokens: [String], line: Int) throws -> EQBand? {
        let bad = ParseError.unsupportedLine(line)
        guard tokens.count >= 2 else { throw bad }
        let state = tokens[0].uppercased()
        guard state == "ON" || state == "OFF" else { throw bad }
        guard let type = filterType(tokens[1]) else { throw bad }

        var fc: Double?
        var gain: Double?
        var q: Double?
        var i = 2
        while i < tokens.count {
            let key = tokens[i].uppercased()
            guard i + 1 < tokens.count, let value = decimal(tokens[i + 1]) else { throw bad }
            i += 2
            switch key {
            case "FC":
                guard i < tokens.count, tokens[i].lowercased() == "hz", fc == nil else { throw bad }
                fc = value
                i += 1
            case "GAIN":
                guard i < tokens.count, tokens[i].lowercased() == "db", gain == nil else { throw bad }
                gain = value
                i += 1
            case "Q":
                guard q == nil else { throw bad }
                q = value
            default:
                throw bad
            }
        }
        guard let fc, fc > 0 else { throw bad }
        if let q, q <= 0 { throw bad }
        let needsGain = type == .peak || type == .lowShelf || type == .highShelf
        if needsGain && gain == nil { throw bad }
        if state == "OFF" { return nil }
        return EQBand(type: type, frequency: fc, gainDb: needsGain ? gain ?? 0 : 0, q: q ?? defaultQ)
    }

    /// A finite decimal with a point, whatever the device locale (`Double(_:)` never consults it).
    private static func decimal(_ s: String) -> Double? {
        guard let v = Double(s), v.isFinite else { return nil }
        return v
    }
}
