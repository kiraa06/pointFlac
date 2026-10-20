/// The one-edit typo rule (spec §4.6, §5.5): tokens of four or more letters may be one substitution, insertion,
/// deletion or adjacent transposition away from a word, or from the start of one, since the user is still typing.
enum SearchMatching {
    /// Typo tolerance starts at this many letters; shorter tokens have too many neighbours to be useful.
    static let minimumTypoLength = 4

    /// Whether `query` is within one edit of `word` or of a prefix of `word`, but not an exact prefix of it (that is a
    /// prefix match, ranked above a typo).
    static func prefixWithinOneEdit(_ query: [UInt32], _ word: [UInt32]) -> Bool {
        query.withUnsafeBufferPointer { q in
            word.withUnsafeBufferPointer { w in prefixWithinOneEdit(q, w) }
        }
    }

    /// The same over buffers, for the vocabulary scan, which runs once per keystroke over every word in the library.
    static func prefixWithinOneEdit(_ q: UnsafeBufferPointer<UInt32>, _ w: UnsafeBufferPointer<UInt32>) -> Bool {
        let m = q.count
        let n = w.count
        guard m >= minimumTypoLength, n >= m - 1 else { return false }
        var i = 0
        while i < m, i < n, q[i] == w[i] { i += 1 }
        if i == m { return false }  // an exact prefix
        // Substitution at i: the rest of the query continues the word.
        if n >= m, matches(q, from: i + 1, w, from: i + 1, count: m - i - 1) { return true }
        // An extra letter in the query at i.
        if matches(q, from: i + 1, w, from: i, count: m - i - 1) { return true }
        // A letter missing from the query at i.
        if n >= m + 1, matches(q, from: i, w, from: i + 1, count: m - i) { return true }
        // Two adjacent letters swapped.
        if i + 1 < m, n >= m, q[i] == w[i + 1], q[i + 1] == w[i],
            matches(q, from: i + 2, w, from: i + 2, count: m - i - 2)
        {
            return true
        }
        return false
    }

    @inline(__always)
    private static func matches(
        _ q: UnsafeBufferPointer<UInt32>, from qStart: Int, _ w: UnsafeBufferPointer<UInt32>, from wStart: Int,
        count: Int
    ) -> Bool {
        guard count > 0 else { return true }
        guard wStart + count <= w.count, qStart + count <= q.count else { return false }
        var k = 0
        while k < count {
            if q[qStart + k] != w[wStart + k] { return false }
            k += 1
        }
        return true
    }
}
