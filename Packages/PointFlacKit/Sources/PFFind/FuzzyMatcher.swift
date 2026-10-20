/// Fuzzy, word-level similarity between what someone typed and a candidate name.
///
/// Whole-string edit distance punishes extra words that do not matter ("Gorillaz - The Mountain (2026) [FLAC]"
/// against "the mountain"), so the matcher scores each typed word against its best candidate word instead, then
/// rewards covering the candidate. The result is in 0…1 and is comparable across candidates for the same query.
public enum FuzzyMatcher {
    /// How well `query` matches `candidate`, in 0…1.
    ///
    /// - Parameter queryIsPartial: the last typed word may be unfinished ("gorill"), so a prefix counts as a match.
    public static func score(query: String, candidate: String, queryIsPartial: Bool = false) -> Double {
        score(
            queryTokens: FindText.tokens(query), candidateTokens: FindText.tokens(candidate),
            lastIsPartial: queryIsPartial)
    }

    /// ``score(query:candidate:queryIsPartial:)`` over already-folded tokens, so hot loops fold once.
    public static func score(queryTokens: [String], candidateTokens: [String], lastIsPartial: Bool) -> Double {
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }
        // "acdc" against "AC/DC", "beegees" against "Bee Gees": compare with the spaces squeezed out.
        if queryTokens.joined() == candidateTokens.joined() {
            return 0.97
        }
        let queryWords = FindText.significantTokens(queryTokens)
        let candidateWords = FindText.significantTokens(candidateTokens)
        let partialIndex = lastIsPartial && queryWords.last == queryTokens.last ? queryWords.count - 1 : -1
        var weighted = 0.0
        var totalWeight = 0.0
        var covered = Set<Int>()
        for (index, word) in queryWords.enumerated() {
            var best = 0.0
            var bestIndex = -1
            for (candidateIndex, candidateWord) in candidateWords.enumerated() {
                let value = tokenScore(word, candidateWord, partial: index == partialIndex)
                if value > best {
                    best = value
                    bestIndex = candidateIndex
                }
            }
            let weight = Double(min(max(word.count, 2), 8))
            weighted += best * weight
            totalWeight += weight
            if best >= 0.7, bestIndex >= 0 {
                covered.insert(bestIndex)
            }
        }
        let average = weighted / totalWeight
        let coverage = Double(covered.count) / Double(candidateWords.count)
        return average * 0.8 + coverage * 0.2 * average
    }

    /// One typed word against one candidate word.
    static func tokenScore(_ query: String, _ candidate: String, partial: Bool) -> Double {
        if query == candidate { return 1 }
        let queryLength = query.count
        if candidate.hasPrefix(query) {
            if partial { return 0.9 }
            if queryLength >= 3 { return 0.7 }
        }
        if queryLength >= 4 {
            let limit = queryLength >= 8 ? 2 : 1
            if let distance = editDistance(query, candidate, limit: limit) {
                return distance == 1 ? 0.8 : 0.7
            }
            // An unfinished word with one typo in it: "gorrill" while typing "Gorillaz". The typo may have added or
            // dropped a letter, so compare against the candidate's prefixes one shorter and one longer too.
            if partial, candidate.count > queryLength - 1 {
                for length in (queryLength - 1)...(queryLength + 1) where length <= candidate.count {
                    if editDistance(query, String(candidate.prefix(length)), limit: 1) != nil { return 0.72 }
                }
            }
        }
        if queryLength >= 3, candidate.contains(query) { return 0.5 }
        return 0
    }

    /// Optimal-string-alignment distance (Levenshtein plus adjacent transpositions), or nil once it exceeds `limit`.
    /// Bounded so the common case, two unrelated words, costs almost nothing.
    public static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int? {
        let a = Array(lhs.unicodeScalars)
        let b = Array(rhs.unicodeScalars)
        if abs(a.count - b.count) > limit { return nil }
        if a.isEmpty { return b.count <= limit ? b.count : nil }
        if b.isEmpty { return a.count <= limit ? a.count : nil }
        var previousPrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return nil }
            (previousPrevious, previous, current) = (previous, current, previousPrevious)
        }
        let distance = previous[b.count]
        return distance <= limit ? distance : nil
    }
}
