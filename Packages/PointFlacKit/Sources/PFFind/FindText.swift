import Foundation

/// Text normalisation shared by every part of the smart search.
///
/// People type "bjork & the sugarcubes", MusicBrainz says "Björk and The Sugarcubes", and a stranger's folder says
/// "Bjork_and_the_Sugarcubes". All three have to compare equal, so every comparison in `PFFind` goes through
/// ``fold(_:)`` first: diacritics, case, width, `&` versus "and" and punctuation stop mattering.
public enum FindText {
    /// Words that carry no identity on their own. They are ignored when deciding whether two names match, and
    /// dropped from Soulseek queries when enough distinctive words remain.
    public static let stopwords: Set<String> = [
        "the", "a", "an", "and", "of", "or", "to", "in", "on", "at", "by", "for", "from", "vs", "feat", "ft",
        "featuring",
    ]

    /// Letters that Unicode decomposition does not reduce to ASCII but that people type without the mark.
    private static let letterFolds: [Character: String] = [
        "ø": "o", "æ": "ae", "œ": "oe", "ß": "ss", "ł": "l", "đ": "d", "ð": "d", "þ": "th", "ı": "i",
    ]

    /// The comparison form of `text`: accent-free, lower-case, `&` and `+` spelled "and", apostrophes removed so
    /// "Don't" and "Dont" agree, every other punctuation mark a single space.
    public static func fold(_ text: String) -> String {
        let base = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(base.unicodeScalars.count)
        var lastWasSpace = true
        func appendSpace() {
            if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        for character in base {
            if let replacement = letterFolds[character] {
                out.append(contentsOf: replacement.unicodeScalars)
                lastWasSpace = false
                continue
            }
            if character == "&" || character == "+" {
                appendSpace()
                out.append(contentsOf: "and".unicodeScalars)
                lastWasSpace = false
                appendSpace()
                continue
            }
            if character == "'" || character == "’" || character == "`" {
                continue
            }
            if character.isLetter || character.isNumber {
                for scalar in character.unicodeScalars where !scalar.properties.isDiacritic {
                    out.append(scalar)
                }
                lastWasSpace = false
            } else {
                appendSpace()
            }
        }
        if out.last == " " {
            out.removeLast()
        }
        return String(out)
    }

    /// The folded words of `text`.
    public static func tokens(_ text: String) -> [String] {
        fold(text).split(separator: " ").map(String.init)
    }

    /// `tokens` without stopwords, unless that would leave nothing ("The The" stays "the the").
    public static func significantTokens(_ tokens: [String]) -> [String] {
        let kept = tokens.filter { !stopwords.contains($0) }
        return kept.isEmpty ? tokens : kept
    }

    /// `name` without a leading English article, so "The Beatles" and "Beatles" agree.
    public static func withoutLeadingArticle(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for article in ["The ", "the ", "THE "] where trimmed.hasPrefix(article) && trimmed.count > article.count {
            return String(trimmed.dropFirst(article.count))
        }
        return trimmed
    }

    /// `title` without a featured-artist credit: "Feel Good Inc. (feat. De La Soul)", "Song ft. X", "Song featuring
    /// X". Folder names spell these a dozen ways, so a query is safer without them.
    public static func withoutFeaturing(_ title: String) -> String {
        var result = title
        // Bracketed credits anywhere: "(feat. X)", "[ft X]", "(with X)".
        if let regex = try? Regex(#"\s*[\(\[]\s*(?i:feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#) {
            result = result.replacing(regex, with: "")
        }
        // A bare credit runs to the end of the title: "Song feat. X & Y".
        if let regex = try? Regex(#"\s+(?i:feat\.?|ft\.?|featuring)\s.*$"#) {
            result = result.replacing(regex, with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// `title` without edition noise: bracketed groups ("(Remastered 2011)", "[Deluxe Edition]") and a trailing
    /// " - 2011 Remaster" style suffix. Strangers' folders rarely carry the same edition words.
    public static func withoutParentheticals(_ title: String) -> String {
        var result = title
        if let regex = try? Regex(#"\s*[\(\[][^\)\]]*[\)\]]"#) {
            result = result.replacing(regex, with: "")
        }
        let editionWords = #"remaster|version|edit|mix|live|mono|stereo|deluxe|edition|anniversary|bonus"#
        if let regex = try? Regex(#"\s+[-–—]\s+[^-–—]*(?i:"# + editionWords + #")[^-–—]*$"#) {
            result = result.replacing(regex, with: "")
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title.trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// The core of a title for matching: no featured credit, no edition noise.
    public static func coreTitle(_ title: String) -> String {
        withoutParentheticals(withoutFeaturing(title))
    }
}
