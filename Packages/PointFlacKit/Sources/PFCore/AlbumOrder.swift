import Foundation

/// How the shelf galaxy orders its albums.
public enum AlbumSort: String, CaseIterable, Sendable {
    case mostPlayed, recentlyPlayed, newestRelease, lastAdded, hiResFirst

    public var title: String {
        switch self {
        case .mostPlayed: "Most played"
        case .recentlyPlayed: "Recently played"
        case .newestRelease: "Newest release"
        case .lastAdded: "Last added"
        case .hiResFirst: "Hi-res first"
        }
    }

    /// The albums' IDs in this sort's order. Every tie is broken last by ID, so the order never shuffles between
    /// layouts. `fellBack` is true when Most played had no listens to go by and used Last added instead.
    public static func ordered(_ keys: [AlbumOrderKey], by sort: AlbumSort) -> (ids: [String], fellBack: Bool) {
        let fellBack = sort == .mostPlayed && keys.allSatisfy { $0.listens == 0 }
        let effective: AlbumSort = fellBack ? .lastAdded : sort
        return (keys.sorted { effective.precedes($0, $1) }.map(\.id), fellBack)
    }

    private func precedes(_ a: AlbumOrderKey, _ b: AlbumOrderKey) -> Bool {
        switch self {
        case .mostPlayed:
            if a.listens != b.listens { return a.listens > b.listens }
            if a.lastListened != b.lastListened { return Self.later(a.lastListened, b.lastListened) }
            if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
        case .recentlyPlayed:
            if a.lastListened != b.lastListened { return Self.later(a.lastListened, b.lastListened) }
            if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
        case .newestRelease:
            if a.year != b.year { return (a.year ?? .min) > (b.year ?? .min) }
            let title = a.title.localizedStandardCompare(b.title)
            if title != .orderedSame { return title == .orderedAscending }
        case .lastAdded:
            if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
        case .hiResFirst:
            if a.bits != b.bits { return a.bits > b.bits }
            if a.rate != b.rate { return a.rate > b.rate }
            let title = a.title.localizedStandardCompare(b.title)
            if title != .orderedSame { return title == .orderedAscending }
        }
        return a.id < b.id
    }

    /// Later dates first, a missing date after every date.
    private static func later(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (let a?, let b?): a > b
        case (_?, nil): true
        default: false
        }
    }
}

/// What an album is ordered by: the few values `AlbumSort` looks at, so the order is a pure function.
public struct AlbumOrderKey: Sendable {
    public var id: String
    public var title: String
    public var year: Int?
    public var addedAt: Date
    public var listens: Int
    public var lastListened: Date?
    public var bits: Int
    public var rate: Int

    public init(
        id: String, title: String, year: Int?, addedAt: Date, listens: Int, lastListened: Date?, bits: Int, rate: Int
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.addedAt = addedAt
        self.listens = listens
        self.lastListened = lastListened
        self.bits = bits
        self.rate = rate
    }
}
