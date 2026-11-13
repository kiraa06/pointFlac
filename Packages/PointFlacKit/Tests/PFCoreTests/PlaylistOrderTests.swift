import Testing

@testable import PFCore

@Test func reorderingEveryShownSongRewritesTheOrder() {
    #expect(PlaylistOrder.reordered(stored: ["a", "b", "c"], shown: ["c", "a", "b"]) == ["c", "a", "b"])
}

@Test func hiddenSongsKeepTheirSlots() {
    // "x" and "y" are gone for now (their files missing): the list shows a, b, c, and they stay where they were.
    let stored = ["a", "x", "b", "c", "y"]
    #expect(PlaylistOrder.reordered(stored: stored, shown: ["c", "b", "a"]) == ["c", "x", "b", "a", "y"])
}

@Test func anUnchangedOrderIsTheStoredOrder() {
    let stored = ["x", "a", "b"]
    #expect(PlaylistOrder.reordered(stored: stored, shown: ["a", "b"]) == stored)
}

@Test func aSongNotInThePlaylistIsRefused() {
    #expect(PlaylistOrder.reordered(stored: ["a", "b"], shown: ["b", "z"]) == nil)
}

@Test func aSongTwiceIsRefused() {
    #expect(PlaylistOrder.reordered(stored: ["a", "b", "c"], shown: ["b", "b", "a"]) == nil)
}

@Test func anEmptyPlaylistReordersToEmpty() {
    #expect(PlaylistOrder.reordered(stored: [], shown: []) == [])
    #expect(PlaylistOrder.reordered(stored: ["x"], shown: []) == ["x"])
}
