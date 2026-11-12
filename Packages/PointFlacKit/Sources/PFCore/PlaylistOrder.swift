/// A playlist's order after a reorder in the app, which lists only the songs the catalog has now.
public enum PlaylistOrder {
    /// The stored order, `stored`, after the songs the list shows were put in `shown`'s order. Songs the list leaves
    /// out (a file gone for now) keep their slots; the shown songs fill the other slots, in their new order. Nil when
    /// `shown` holds a song the playlist doesn't, or one song twice: the library's reorder would refuse it anyway.
    public static func reordered(stored: [String], shown: [String]) -> [String]? {
        let moved = Set(shown)
        guard moved.count == shown.count, moved.isSubset(of: Set(stored)) else { return nil }
        var next = shown.makeIterator()
        return stored.map { moved.contains($0) ? (next.next() ?? $0) : $0 }
    }
}
