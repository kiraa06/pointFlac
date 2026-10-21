import Foundation
import PFDownloads
import Testing

@testable import PFArchive

@Suite("Friday Drops")
struct FridayDropsTests {
    static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test("weeks are ISO weeks on UTC, whatever the local time zone")
    func weeks() {
        // Sunday 23:30 UTC is already Monday morning in India, but still the old week on the shelf.
        #expect(DropWeek(containing: Self.date("2026-10-25T23:30:00Z")) == DropWeek(year: 2026, week: 43))
        #expect(DropWeek(containing: Self.date("2026-10-26T00:30:00Z")) == DropWeek(year: 2026, week: 44))
        // 1 January 2027 is a Friday in ISO week 53 of 2026.
        #expect(DropWeek(containing: Self.date("2027-01-01T12:00:00Z")) == DropWeek(year: 2026, week: 53))
        #expect(DropWeek(year: 2026, week: 7).description == "2026-W07")
    }

    @Test("the pick depends only on the pool and the week, not on the order the Archive lists items in")
    func determinism() {
        let pool = (0..<50).map { "netlabel-release-\($0)" }
        let week = DropWeek(year: 2026, week: 43)
        let first = FridayDrops.order(pool, week: week)
        #expect(FridayDrops.order(pool.reversed(), week: week) == first)
        #expect(FridayDrops.order(pool.shuffled(), week: week) == first)
        #expect(FridayDrops.order(pool + pool.prefix(5), week: week) == first, "duplicates do not shift the pick")
        #expect(Set(first) == Set(pool))
        #expect(FridayDrops.order(pool, week: DropWeek(year: 2026, week: 44)).prefix(10) != first.prefix(10))
        // Pinned so a change to the generator or shuffle, which would reshuffle every listener's shelf, is noticed.
        #expect(
            FridayDrops.order(["a", "b", "c", "d", "e"], week: DropWeek(year: 2026, week: 43)) == [
                "e", "a", "c", "d", "b",
            ])
        var reference = SplitMix64(seed: 0)
        #expect(reference.next() == 0xE220_A839_7B1D_CDAF, "SplitMix64's published first output for seed 0")
    }

    static func poolJSON(_ identifiers: [String]) -> Data {
        let docs = identifiers.map {
            [
                "identifier": $0, "title": "Release \($0)", "collection": "netlabels",
                "licenseurl": "http://creativecommons.org/licenses/by-nc-sa/3.0/",
            ]
        }
        let body: [String: Any] = ["response": ["numFound": docs.count, "start": 0, "docs": docs]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func stubbedShelf(_ network: StubNetwork, pool: [String], empty: Set<String>) {
        network.route("/advancedsearch.php") { _ in .success(.json(Self.poolJSON(pool))) }
        let album = loadFixture("metadata-atrio.json")
        let missing = loadFixture("metadata-missing.json")
        network.route("/metadata/") { request in
            let identifier = request.url?.lastPathComponent ?? ""
            return .success(.json(empty.contains(identifier) ? missing : album))
        }
    }

    @Test("a shelf holds ten confirmed FLAC albums with licences, and is reused for the rest of the week")
    func shelfAndSnapshot() async throws {
        let scratch = try Scratch()
        let network = StubNetwork()
        let pool = (0..<30).map { "label-\($0)" }
        stubbedShelf(network, pool: pool, empty: ["label-3", "label-7", "label-11", "label-19"])
        let snapshot = scratch.url.appending(path: "drops.json")
        let clock = Locked(Self.date("2026-10-23T09:00:00Z"))
        let drops = FridayDrops(provider: network.provider(), snapshotFile: snapshot, now: { clock.value })

        let shelf = try await drops.shelf()
        #expect(shelf.week == DropWeek(year: 2026, week: 43))
        #expect(shelf.drops.count == FridayDrops.shelfSize)
        #expect(Set(shelf.drops.map(\.id)).isDisjoint(with: ["label-3", "label-7", "label-11", "label-19"]))
        #expect(shelf.drops.allSatisfy { $0.licence == "CC BY-NC-ND 3.0" && $0.tracks.count == 4 })
        #expect(shelf.drops.allSatisfy { drop in drop.tracks.allSatisfy { $0.detail["identifier"] == drop.id } })
        let expected = FridayDrops.order(pool, week: shelf.week).filter {
            !["label-3", "label-7", "label-11", "label-19"].contains($0)
        }
        #expect(shelf.drops.map(\.id) == Array(expected.prefix(10)))

        // Later the same week: the saved shelf comes back without touching the network, even if the pool changed.
        let requestsBefore = network.requests.withLock { $0.count }
        clock.update { $0 = Self.date("2026-10-25T23:59:00Z") }
        let again = try await FridayDrops(provider: network.provider(), snapshotFile: snapshot, now: { clock.value })
            .shelf()
        #expect(again == shelf)
        #expect(network.requests.withLock { $0.count } == requestsBefore)

        // A new UTC week picks again.
        clock.update { $0 = Self.date("2026-10-26T00:01:00Z") }
        let next = try await drops.shelf()
        #expect(next.week == DropWeek(year: 2026, week: 44))
        #expect(next.drops.map(\.id) != shelf.drops.map(\.id))
    }

    @Test("offline at the start of a week, last week's shelf is kept rather than showing nothing")
    func offlineKeepsLastShelf() async throws {
        let scratch = try Scratch()
        let network = StubNetwork()
        stubbedShelf(network, pool: (0..<12).map { "label-\($0)" }, empty: [])
        let snapshot = scratch.url.appending(path: "drops.json")
        let clock = Locked(Self.date("2026-10-23T09:00:00Z"))
        let drops = FridayDrops(provider: network.provider(), snapshotFile: snapshot, now: { clock.value })
        let shelf = try await drops.shelf()

        network.route("/") { _ in .failure(URLError(.notConnectedToInternet)) }
        clock.update { $0 = Self.date("2026-10-30T09:00:00Z") }
        #expect(try await drops.shelf() == shelf)

        let fresh = FridayDrops(
            provider: network.provider(), snapshotFile: scratch.url.appending(path: "none.json"), now: { clock.value })
        await #expect(throws: ArchiveError.offline) { _ = try await fresh.shelf() }
    }

    @Test("a short shelf is never saved for the week: last week's stays, and the next load tries again")
    func shortShelfNotSaved() async throws {
        let scratch = try Scratch()
        let network = StubNetwork()
        let pool = (0..<12).map { "label-\($0)" }
        stubbedShelf(network, pool: pool, empty: [])
        let snapshot = scratch.url.appending(path: "drops.json")
        let clock = Locked(Self.date("2026-10-23T09:00:00Z"))
        let drops = FridayDrops(provider: network.provider(), snapshotFile: snapshot, now: { clock.value })
        let lastWeek = try await drops.shelf()
        #expect(lastWeek.drops.count == 10)
        let savedBytes = try Data(contentsOf: snapshot)

        // Next week only two items answer with FLAC.
        let thin = StubNetwork()
        stubbedShelf(thin, pool: pool, empty: Set(pool.dropFirst(2)))
        clock.update { $0 = Self.date("2026-10-30T09:00:00Z") }
        let next = FridayDrops(provider: thin.provider(), snapshotFile: snapshot, now: { clock.value })
        #expect(try await next.shelf() == lastWeek)
        #expect(try Data(contentsOf: snapshot) == savedBytes, "the snapshot is not overwritten")

        // The next load asks the Archive again rather than trusting a cached thin pick.
        let before = thin.requests.withLock { $0.count }
        _ = try await next.shelf()
        #expect(thin.requests.withLock { $0.count } > before)

        // With nothing saved at all, the short pick is shown but still not saved.
        let fresh = scratch.url.appending(path: "fresh.json")
        let first = try await FridayDrops(provider: thin.provider(), snapshotFile: fresh, now: { clock.value }).shelf()
        #expect(first.drops.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }
}
