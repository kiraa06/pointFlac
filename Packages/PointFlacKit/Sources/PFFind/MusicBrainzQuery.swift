import Foundation

/// Builds MusicBrainz search queries (Lucene syntax) from what someone typed.
///
/// The key trick is the **field split**. A person types "the mountain gorillaz": title words and artist words mixed,
/// in any order. Searching either field alone fails (the artist field finds every Gorillaz album named "Gorillaz").
/// So one request asks for every split of the words into a title part and an artist part, in both orders, plus the
/// whole phrase as a title and as an artist:
///
///     releasegroup:(the AND mountain AND gorillaz) OR artist:(the AND mountain AND gorillaz)
///     OR (releasegroup:(the AND mountain) AND artist:(gorillaz)) OR (artist:(the AND mountain) AND releasegroup:(gorillaz))
///     OR …
///
/// Recorded 2026-10-21: that single request returns exactly *The Mountain* by Gorillaz, and the same shape with
/// `radiohed~1` returns *OK Computer* by Radiohead first. One request per entity matters: MusicBrainz allows one per
/// second.
public enum MusicBrainzQuery {
    /// Above this many words the split clauses would multiply; long queries search the whole phrase only.
    public static let maximumSplitWords = 6

    /// The folded, escaped query terms for `text`. While typing, the last word is a prefix (`gorill*`); finished
    /// words of five letters or more also match one typo (`radiohed~1`).
    public static func terms(_ text: String, partial: Bool) -> [String] {
        // Lower-case "and", "or" and "not" are dropped: they carry nothing and some parsers read them as operators.
        let words = FindText.tokens(text).filter { !["and", "or", "not"].contains($0) }
        return words.enumerated().map { index, word in
            let escaped = escape(word)
            if partial, index == words.count - 1 {
                return word.count >= 2 ? escaped + "*" : escaped
            }
            return word.count >= 5 ? escaped + "~1" : escaped
        }
    }

    /// An artist search: name, alias or sort name ("Beatles, The").
    public static func artist(_ text: String, partial: Bool) -> String? {
        let words = terms(text, partial: partial)
        guard !words.isEmpty else { return nil }
        let group = "(" + words.joined(separator: " AND ") + ")"
        return "artist:\(group) OR alias:\(group) OR sortname:\(group)"
    }

    /// A release-group (album) search over every title/artist split.
    public static func releaseGroup(_ text: String, partial: Bool) -> String? {
        split(text, titleField: "releasegroup", partial: partial)
    }

    /// A recording (track) search over every title/artist split.
    public static func recording(_ text: String, partial: Bool) -> String? {
        split(text, titleField: "recording", partial: partial)
    }

    /// The releases of one release group, which carry track counts.
    public static func releases(ofReleaseGroup id: String) -> String {
        "rgid:" + escape(id)
    }

    /// The split query described on the type.
    static func split(_ text: String, titleField: String, partial: Bool) -> String? {
        let words = terms(text, partial: partial)
        guard !words.isEmpty else { return nil }
        func group(_ part: ArraySlice<String>) -> String { "(" + part.joined(separator: " AND ") + ")" }
        let all = words[...]
        var clauses = ["\(titleField):\(group(all))", "artist:\(group(all))"]
        if words.count > 1, words.count <= maximumSplitWords {
            for cut in 1..<words.count {
                let head = words[..<cut]
                let tail = words[cut...]
                // A side made only of stopwords ("the") matches half the database; skip that split.
                guard isMeaningful(head), isMeaningful(tail) else { continue }
                clauses.append("(\(titleField):\(group(head)) AND artist:\(group(tail)))")
                clauses.append("(artist:\(group(head)) AND \(titleField):\(group(tail)))")
            }
        }
        return clauses.joined(separator: " OR ")
    }

    private static func isMeaningful(_ part: ArraySlice<String>) -> Bool {
        part.contains { term in
            let bare = term.trimmingCharacters(in: CharacterSet(charactersIn: "*~1"))
            return !FindText.stopwords.contains(bare)
        }
    }

    /// Escapes Lucene's special characters. Folded words are already alphanumeric; this is defence in depth.
    static func escape(_ term: String) -> String {
        let specials: Set<Character> = [
            "+", "-", "&", "|", "!", "(", ")", "{", "}", "[", "]", "^", "\"", "~", "*", "?", ":", "\\", "/",
        ]
        var out = ""
        for character in term {
            if specials.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
