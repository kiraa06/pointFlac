import Foundation

/// How search sees text (spec §5.5): folded for case, accents and width, split into words on whitespace, with
/// punctuation dropped.
///
/// A word with punctuation inside it is indexed whole and in pieces: "AC/DC" gives `acdc`, `ac` and `dc`, and
/// "Don't" gives `dont`, `don` and `t`, so "acdc", "ac/dc", "dc", "dont" and "don't" all find it. A query word is
/// only ever used whole ("ac/dc" → `acdc`).
///
/// Tokens are arrays of Unicode scalar values: comparisons, prefixes and edit distances then count what a person
/// counts as a letter for Latin, Greek and Cyrillic, without `String`'s cost in the per-keystroke loop.
public enum TextFolding {
    public typealias Token = [UInt32]

    /// A word of `text`: its whole folded form, its pieces when punctuation split it, and its place among the words.
    struct Word {
        var joined: Token
        var pieces: [Token]
    }

    /// Case-, diacritic- and width-insensitive. ASCII takes a fast path that gives what Foundation's folding gives.
    public static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Letters and digits count; everything else separates.
    @inline(__always)
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x80 {
            return (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A)
        }
        let properties = scalar.properties
        return properties.isAlphabetic || properties.numericType != nil
    }

    /// The words of `text`, folded.
    static func words(_ text: String) -> [Word] {
        var words: [Word] = []
        var joined: Token = []
        var pieces: [Token] = []
        var piece: Token = []
        func endPiece() {
            if !piece.isEmpty {
                pieces.append(piece)
                piece = []
            }
        }
        func endWord() {
            endPiece()
            if !joined.isEmpty {
                words.append(Word(joined: joined, pieces: pieces.count > 1 ? pieces : []))
            }
            joined = []
            pieces = []
        }
        for scalar in fold(text).unicodeScalars {
            if isWordScalar(scalar) {
                joined.append(scalar.value)
                piece.append(scalar.value)
            } else if scalar.properties.isWhitespace {
                endWord()
            } else {
                endPiece()
            }
        }
        endWord()
        return words
    }

    /// The tokens of a query: one per word, whole.
    public static func queryTokens(_ text: String) -> [Token] {
        words(text).map(\.joined)
    }

    // MARK: Highlights

    /// The ranges of `text` that `query` matched: the matched prefix of each word or piece (all of it for an exact
    /// or a typo match). Computed only for the hits a search returns, never for the whole library.
    public static func highlights(in text: String, query: [Token]) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            // Skip to the next word.
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            highlightWord(text, index..<end, query: query, into: &ranges)
            index = end
        }
        return merged(ranges)
    }

    /// One word of `text` (no whitespace inside): folds it character by character, so a folded prefix maps back to
    /// the characters it came from.
    private static func highlightWord(
        _ text: String, _ word: Range<String.Index>, query: [Token], into ranges: inout [Range<String.Index>]
    ) {
        // Most words of a hit did not match: rule them out from one fold of the whole word before folding it
        // character by character.
        let whole = words(String(text[word]))
        guard
            whole.contains(where: { candidate in
                query.contains { token in
                    hasPrefix(candidate.joined, token) || SearchMatching.prefixWithinOneEdit(token, candidate.joined)
                        || candidate.pieces.contains { hasPrefix($0, token) }
                        || substringOffset(of: token, in: candidate.joined) != nil
                }
            })
        else { return }
        // Each character's folded word scalars, and where the character ends.
        var joined: Token = []
        var ends: [(foldedCount: Int, end: String.Index)] = []
        var pieceStarts: [Int] = [0]  // indexes into `ends` where a piece begins
        var character = word.lowerBound
        var lastWasWord = true
        while character < word.upperBound {
            let next = text.index(after: character)
            let folded = fold(String(text[character..<next])).unicodeScalars.filter(isWordScalar)
            if folded.isEmpty {
                if lastWasWord, !ends.isEmpty { pieceStarts.append(ends.count) }
                lastWasWord = false
            } else {
                joined.append(contentsOf: folded.map(\.value))
                lastWasWord = true
            }
            ends.append((joined.count, next))
            character = next
        }
        guard !joined.isEmpty else { return }

        /// The characters that hold folded scalars `[base, base + count)`.
        func range(base: Int, count: Int) -> Range<String.Index>? {
            var lower: String.Index?
            var previous = 0
            var startOfCharacter = word.lowerBound
            for (foldedCount, end) in ends {
                if lower == nil, foldedCount > previous, foldedCount > base { lower = startOfCharacter }
                if let lower, foldedCount >= base + count { return lower..<end }
                previous = foldedCount
                startOfCharacter = end
            }
            return nil
        }

        for token in query {
            if hasPrefix(joined, token) || SearchMatching.prefixWithinOneEdit(token, joined) {
                let count = hasPrefix(joined, token) ? token.count : min(token.count, joined.count)
                if let r = range(base: 0, count: count) { ranges.append(r) }
                continue
            }
            if let offset = substringOffset(of: token, in: joined) {
                if let r = range(base: offset, count: token.count) { ranges.append(r) }
                continue
            }
            // A piece: "dc" in "AC/DC".
            for start in pieceStarts where start > 0 {
                let base = ends[start - 1].foldedCount
                let piece = Array(joined[base...])
                if hasPrefix(piece, token), let r = range(base: base, count: token.count) {
                    ranges.append(r)
                }
            }
        }
    }

    /// Where `token` (3+ letters) occurs inside `word` after its first letter, as search's substring tier matches it.
    static func substringOffset(of token: Token, in word: Token) -> Int? {
        guard token.count >= SearchMatching.minimumSubstringLength, word.count > token.count else { return nil }
        for offset in 1...(word.count - token.count) where word[offset] == token[0] {
            if word[offset..<offset + token.count].elementsEqual(token) { return offset }
        }
        return nil
    }

    static func hasPrefix(_ word: Token, _ prefix: Token) -> Bool {
        word.count >= prefix.count && word.starts(with: prefix)
    }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<String.Index>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
