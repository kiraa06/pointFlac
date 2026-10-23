import Foundation
import Testing

@testable import PFCore

private func key(
    _ id: String, title: String? = nil, year: Int? = nil, added: Double = 0, listens: Int = 0,
    last: Double? = nil, bits: Int = 16, rate: Int = 44100
) -> AlbumOrderKey {
    AlbumOrderKey(
        id: id, title: title ?? id, year: year, addedAt: Date(timeIntervalSince1970: added), listens: listens,
        lastListened: last.map { Date(timeIntervalSince1970: $0) }, bits: bits, rate: rate)
}

@Test func mostPlayedOrdersByListensThenRecencyThenAdded() {
    let keys = [
        key("a", added: 1, listens: 2, last: 10),
        key("b", added: 2, listens: 5, last: 5),
        key("c", added: 3, listens: 2, last: 20),
        key("d", added: 4, listens: 2, last: nil),
        key("e", added: 5, listens: 2, last: nil),
    ]
    let result = AlbumSort.ordered(keys, by: .mostPlayed)
    #expect(result.ids == ["b", "c", "a", "e", "d"])
    #expect(!result.fellBack)
}

@Test func fallsBackToLastAddedWithNoListens() {
    let keys = [key("a", added: 1), key("b", added: 3), key("c", added: 2)]
    let result = AlbumSort.ordered(keys, by: .mostPlayed)
    #expect(result.ids == ["b", "c", "a"])
    #expect(result.fellBack)
    #expect(!AlbumSort.ordered(keys, by: .lastAdded).fellBack)
}

@Test func recentlyPlayedPutsNeverPlayedLast() {
    let keys = [
        key("a", added: 1, last: 10), key("b", added: 5), key("c", added: 2, last: 30), key("d", added: 9),
    ]
    #expect(AlbumSort.ordered(keys, by: .recentlyPlayed).ids == ["c", "a", "d", "b"])
}

@Test func newestReleasePutsNoYearLastAndBreaksTiesByTitle() {
    let keys = [
        key("a", title: "Beta", year: 2001), key("b", title: "Alpha", year: 2001), key("c", title: "Zed", year: 2020),
        key("d", title: "Nothing", year: nil),
    ]
    #expect(AlbumSort.ordered(keys, by: .newestRelease).ids == ["c", "b", "a", "d"])
}

@Test func lastAddedIsNewestFirst() {
    let keys = [key("a", added: 1), key("b", added: 9), key("c", added: 5)]
    #expect(AlbumSort.ordered(keys, by: .lastAdded).ids == ["b", "c", "a"])
}

@Test func hiResFirstOrdersByBitsThenRateThenTitle() {
    let keys = [
        key("a", title: "Cee", bits: 24, rate: 96000), key("b", title: "Bee", bits: 16, rate: 44100),
        key("c", title: "Aye", bits: 24, rate: 192000), key("d", title: "Dee", bits: 24, rate: 96000),
    ]
    #expect(AlbumSort.ordered(keys, by: .hiResFirst).ids == ["c", "a", "d", "b"])
}

@Test func tiesAreStableByID() {
    let keys = ["z", "m", "a"].map { key($0, title: "Same", year: 2000, added: 1, listens: 1, last: 1) }
    for sort in AlbumSort.allCases {
        #expect(AlbumSort.ordered(keys, by: sort).ids == ["a", "m", "z"], "\(sort)")
        #expect(AlbumSort.ordered(keys.reversed(), by: sort).ids == ["a", "m", "z"], "\(sort)")
    }
}

@Test func titlesAreHumanReadable() {
    #expect(
        AlbumSort.allCases.map(\.title) == [
            "Most played", "Recently played", "Newest release", "Last added", "Hi-res first",
        ])
}
