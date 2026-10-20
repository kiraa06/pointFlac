import Foundation
import PFDownloads
import os

/// One album on the Friday Drops shelf.
public struct FridayDrop: Sendable, Hashable, Codable, Identifiable {
    /// The Archive identifier.
    public var id: String
    public var title: String
    public var artist: String?
    /// e.g. "CC BY-NC-SA 4.0", shown on the record.
    public var licence: String
    public var licenceURL: String
    public var pageURL: String
    /// The album's FLAC files, ready for `DownloadManager.enqueue`. No claim limit (spec §4.7).
    public var tracks: [RemoteTrack]
}

/// An ISO-8601 week in UTC, the unit the shelf changes on.
public struct DropWeek: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public var year: Int
    public var week: Int

    public init(year: Int, week: Int) {
        self.year = year
        self.week = week
    }

    /// The week containing `date`, on UTC so every listener sees the same shelf at the same moment.
    public init(containing date: Date) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        self.init(year: parts.yearForWeekOfYear ?? 1970, week: parts.weekOfYear ?? 1)
    }

    public static func < (lhs: DropWeek, rhs: DropWeek) -> Bool { (lhs.year, lhs.week) < (rhs.year, rhs.week) }

    public var description: String { String(format: "%04d-W%02d", year, week) }

    /// The seed for this week's pick.
    var seed: UInt64 { UInt64(year) * 100 + UInt64(week) }
}

/// A week's shelf as it was first loaded that week.
public struct DropShelf: Sendable, Hashable, Codable {
    public var week: DropWeek
    public var drops: [FridayDrop]
}

/// The Friday Drops shelf: ten Creative Commons netlabel albums a week (spec §4.7).
///
/// The pick is a pure function of the candidate pool and the UTC week number, so everyone sees the same albums in a
/// given week regardless of the order the Archive lists them in. Because the Archive's pool changes over time, the
/// first shelf loaded each week is saved and reused for the rest of that week.
public actor FridayDrops {
    public static let shelfSize = 10
    /// Candidate netlabel releases considered each week, most downloaded first.
    static let poolSize = 300
    /// Metadata requests one refresh may spend confirming albums really contain FLAC.
    static let maxChecks = 25

    static let poolQuery =
        "collection:netlabels AND mediatype:audio AND format:(Flac OR \"24bit Flac\")"
        + " AND licenseurl:*creativecommons.org*"

    private let provider: ArchiveProvider
    private let snapshotFile: URL?
    private let now: @Sendable () -> Date
    private static let log = Logger(subsystem: "io.github.kiraa06.pointflac", category: "archive")

    public init(provider: ArchiveProvider, snapshotFile: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.provider = provider
        self.snapshotFile = snapshotFile
        self.now = now
    }

    /// A shelf shorter than this is never saved: it would stand for the whole week.
    public static let minimumToSave = shelfSize / 2

    /// This week's shelf: the saved snapshot if it is from this week, otherwise a fresh pick that is then saved.
    /// Offline at the start of a week, the last saved shelf is returned so the shelf is never empty.
    ///
    /// A pick with fewer than `minimumToSave` albums (the Archive half answering, most checks failing) is not saved,
    /// so the next load tries again instead of showing a thin shelf all week. Meanwhile the last saved shelf is
    /// shown if there is one, otherwise the short pick, unsaved.
    public func shelf() async throws -> DropShelf {
        let week = DropWeek(containing: now())
        let saved = loadSnapshot()
        if let saved, saved.week == week { return saved }
        do {
            let fresh = try await pick(for: week)
            guard fresh.drops.count >= Self.minimumToSave else {
                Self.log.info("friday drops: only \(fresh.drops.count, privacy: .public) albums; not saving")
                return saved ?? fresh
            }
            save(fresh)
            return fresh
        } catch {
            if let saved, !(error is CancellationError) {
                Self.log.info("friday drops: refresh failed, keeping \(saved.week.description, privacy: .public)")
                return saved
            }
            throw error
        }
    }

    func pick(for week: DropWeek) async throws -> DropShelf {
        let client = provider.client
        let base = provider.configuration.baseURL
        guard let url = ArchiveQuery.searchURL(base: base, query: Self.poolQuery, rows: Self.poolSize) else {
            throw ArchiveError.badResponse("bad pool query")
        }
        let page = try await client.json(SearchResponse.self, from: url, limit: client.limits.maxSearchJSONBytes)
        let pool = page.response.docs.filter { doc in
            guard ArchiveQuery.isValidIdentifier(doc.identifier),
                let licence = ArchiveLicence.classify(licenseURL: doc.licenseurl?.first, collections: [])
            else { return false }
            return licence != .etree
        }.map(\.identifier)

        var drops: [FridayDrop] = []
        for identifier in Self.order(pool, week: week).prefix(Self.maxChecks) {
            guard drops.count < Self.shelfSize else { break }
            let tracks = try await ArchiveProvider.tracks(for: identifier, client: client, base: base)
            guard let first = tracks.first, let licence = first.detail["licence"], licence != ArchiveLicence.etree.name
            else { continue }
            drops.append(
                FridayDrop(
                    id: identifier, title: first.detail["itemTitle"] ?? first.album ?? identifier,
                    artist: first.artist, licence: licence, licenceURL: first.detail["licenceURL"] ?? "",
                    pageURL: "https://archive.org/details/\(identifier)", tracks: tracks))
        }
        return DropShelf(week: week, drops: drops)
    }

    /// The week's order over the pool: a Fisher-Yates shuffle of the sorted identifiers, seeded by the week.
    /// Sorting first makes the result independent of the order the Archive returned them in.
    static func order(_ pool: [String], week: DropWeek) -> [String] {
        var items = Array(Set(pool)).sorted()
        var generator = SplitMix64(seed: week.seed)
        guard items.count > 1 else { return items }
        for index in stride(from: items.count - 1, to: 0, by: -1) {
            let other = Int(generator.next() % UInt64(index + 1))
            items.swapAt(index, other)
        }
        return items
    }

    private func loadSnapshot() -> DropShelf? {
        guard let snapshotFile, let data = try? Data(contentsOf: snapshotFile), data.count < 8 << 20 else { return nil }
        return try? JSONDecoder().decode(DropShelf.self, from: data)
    }

    private func save(_ shelf: DropShelf) {
        guard let snapshotFile else { return }
        do {
            try FileManager.default.createDirectory(
                at: snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(shelf).write(to: snapshotFile, options: .atomic)
        } catch {
            Self.log.error("friday drops: could not save the shelf: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// A small, fixed, platform-independent generator, so a week's pick never depends on the Swift runtime's own
/// random number generator.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
