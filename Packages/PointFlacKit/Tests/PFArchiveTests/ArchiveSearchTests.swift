import Foundation
import PFDownloads
import Synchronization
import Testing

@testable import PFArchive

@Suite("Archive search")
struct ArchiveSearchTests {
    /// The recorded search page plus each item's recorded or synthesised metadata.
    func stubbedArchive() -> StubNetwork {
        let network = StubNetwork()
        network.route("/advancedsearch.php", fixture: "advancedsearch-search.json")
        network.route("/metadata/dusty-sense", fixture: "metadata-dusty-sense.json")
        network.route("/metadata/001netlabel.com-14_Atrio-Serenade_Devocion-Indomita", fixture: "metadata-atrio.json")
        network.route("/metadata/gd1977-05-08.sbd.example", fixture: "metadata-etree-mixed.json")
        network.route("/metadata/claims-cc-but-not", fixture: "metadata-no-licence.json")
        network.route("/metadata/gone-item", fixture: "metadata-missing.json")
        return network
    }

    func collect(_ provider: ArchiveProvider, _ query: String) async throws -> [[RemoteTrack]] {
        var batches: [[RemoteTrack]] = []
        for try await batch in provider.search(query) { batches.append(batch) }
        return batches
    }

    @Test("only open-licence items with original FLAC files are offered, one batch per item")
    func searchFiltersEverything() async throws {
        let network = stubbedArchive()
        let batches = try await collect(network.provider(), "ambient")
        let identifiers = Set(batches.compactMap { $0.first?.detail["identifier"] })
        #expect(
            identifiers == [
                "dusty-sense", "001netlabel.com-14_Atrio-Serenade_Devocion-Indomita", "gd1977-05-08.sbd.example",
            ])
        #expect(batches.allSatisfy { batch in batch.allSatisfy { $0.fileName.hasSuffix(".flac") } })

        // Items without an open licence in the search answer never cost a metadata request.
        let paths = network.paths()
        #expect(!paths.contains { $0.contains("commercial-album-rip") || $0.contains("rights-reserved-item") })
        #expect(!paths.contains { $0.contains("etc") })
        #expect(paths.filter { $0 == "/metadata/dusty-sense" }.count == 1, "duplicates are fetched once")
    }

    @Test("the search request carries the filters and a descriptive User-Agent on every request")
    func requestShape() async throws {
        let network = stubbedArchive()
        _ = try await collect(network.provider(), "dusty sense")
        let requests = network.requests.withLock { $0 }
        #expect(!requests.isEmpty)
        #expect(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "User-Agent") == "pointFlac/0.2 (+https://github.com/kiraa06/pointFlac)"
            })
        let search = try #require(requests.first { $0.url?.path() == "/advancedsearch.php" })
        let query = URLComponents(url: search.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "q"
        }
        #expect(query?.value == "(\"dusty\" \"sense\") AND \(ArchiveQuery.filters)")
    }

    @Test("a recorded single-file item maps to one 24-bit track with its licence and checksum")
    func dustySense() async throws {
        let network = stubbedArchive()
        let batches = try await collect(network.provider(), "dusty")
        let track = try #require(batches.flatMap { $0 }.first { $0.detail["identifier"] == "dusty-sense" })
        #expect(track.id == "archive:dusty-sense/dusty-sense.flac")
        #expect(track.provider == "archive")
        #expect(track.fileName == "dusty-sense.flac")
        #expect(track.sizeBytes == 3_553_564)
        #expect(track.bitsPerSample == 24)
        #expect(track.sampleRate == nil)
        #expect(track.detail["licence"] == "CC0 1.0")
        #expect(track.detail["md5"] == "625d98745d9994f019e3558b4f84cab5")
    }

    @Test("a recorded album keeps its four FLAC originals in track order and drops MP3s and fingerprints")
    func album() async throws {
        let network = stubbedArchive()
        let batches = try await collect(network.provider(), "atrio")
        let tracks = try #require(
            batches.first { $0.first?.detail["identifier"] == "001netlabel.com-14_Atrio-Serenade_Devocion-Indomita" })
        #expect(tracks.map(\.detail["track"]) == ["1", "2", "3", "4"])
        #expect(tracks[0].title == "Vientos Eternos (Version Extendida)")
        #expect(tracks[0].artist == "Atrio Serenade")
        #expect(tracks[0].album == "Devoción Indómita")
        #expect(tracks.allSatisfy { $0.bitsPerSample == nil }, "plain Flac does not say its bit depth")
        #expect(tracks.allSatisfy { $0.detail["licence"] == "CC BY-NC-ND 3.0" })
    }

    @Test("file selection drops zips, derivatives, unsafe paths and files without size or MD5")
    func fileSelection() async throws {
        let network = stubbedArchive()
        let batches = try await collect(network.provider(), "dead")
        let tracks = try #require(batches.first { $0.first?.detail["identifier"] == "gd1977-05-08.sbd.example" })
        #expect(tracks.map(\.detail["path"]) == ["gd77-05-08d1t01.flac", "disc2/gd77-05-08d2t02 Scarlet.flac"])
        #expect(tracks[1].fileName == "gd77-05-08d2t02 Scarlet.flac")
        #expect(tracks[1].bitsPerSample == 24)
        #expect(tracks.allSatisfy { $0.detail["licence"] == ArchiveLicence.etree.name })
    }

    @Test("IDs are stable across searches")
    func stableIDs() async throws {
        let network = stubbedArchive()
        let first = try await collect(network.provider(), "x").flatMap { $0 }.map(\.id).sorted()
        let second = try await collect(network.provider(), "x").flatMap { $0 }.map(\.id).sorted()
        #expect(first == second)
        #expect(Set(first).count == first.count)
    }

    @Test("being offline fails the search with a clear error")
    func offline() async throws {
        let network = StubNetwork()
        network.route("/") { _ in .failure(URLError(.notConnectedToInternet)) }
        await #expect(throws: ArchiveError.offline) { _ = try await collect(network.provider(), "x") }
    }

    @Test("a server error on the search page fails the search")
    func serverError() async throws {
        let network = StubNetwork()
        network.route("/advancedsearch.php") { _ in .success(StubReply(status: 500)) }
        await #expect(throws: ArchiveError.http(500)) { _ = try await collect(network.provider(), "x") }
    }

    @Test("a busy Archive is honoured: Retry-After is waited out and the request repeated once")
    func retryAfter() async throws {
        let network = stubbedArchive()
        let calls = AtomicCounter()
        network.route("/advancedsearch.php") { _ in
            calls.increment() == 1
                ? .success(StubReply(status: 429, headers: ["Retry-After": "0"]))
                : .success(.json(loadFixture("advancedsearch-search.json")))
        }
        let batches = try await collect(network.provider(), "x")
        #expect(!batches.isEmpty)
        #expect(calls.value == 2)
    }

    @Test("requests are spaced by the minimum interval")
    func pacing() async throws {
        let network = stubbedArchive()
        let stamps = TimeStamps()
        network.route("/metadata/") { _ in
            stamps.record()
            return .success(.json(loadFixture("metadata-missing.json")))
        }
        _ = try await collect(network.provider(interval: .milliseconds(60)), "x")
        let gaps = stamps.gaps()
        #expect(gaps.count >= 3)
        #expect(gaps.allSatisfy { $0 >= .milliseconds(50) }, "gaps: \(gaps)")
    }

    @Test("JSON larger than the cap is refused without being decoded")
    func jsonCap() async throws {
        let network = StubNetwork()
        network.route("/big") { _ in .success(.json(Data(repeating: 0x20, count: 10_000))) }
        var limits = ArchiveClient.Limits()
        limits.minRequestInterval = .zero
        let client = ArchiveClient(
            base: network.base, session: ArchiveClient.makeSession(protocolClasses: [StubURLProtocol.self]),
            limits: limits)
        await #expect(throws: ArchiveError.tooLarge) {
            _ = try await client.json(SearchResponse.self, from: network.base.appending(path: "big"), limit: 1000)
        }
    }

    @Test("an empty query makes no request at all")
    func emptyQuery() async throws {
        let network = stubbedArchive()
        #expect(try await collect(network.provider(), "  \n ").isEmpty)
        #expect(network.paths().isEmpty)
    }
}

final class AtomicCounter: Sendable {
    private let count = Mutex(0)
    func increment() -> Int {
        count.withLock {
            $0 += 1
            return $0
        }
    }
    var value: Int { count.withLock { $0 } }
}

final class TimeStamps: Sendable {
    private let stamps = Mutex<[ContinuousClock.Instant]>([])
    func record() { stamps.withLock { $0.append(.now) } }
    func gaps() -> [Duration] {
        let sorted = stamps.withLock { $0 }.sorted()
        return zip(sorted.dropFirst(), sorted).map { $0 - $1 }
    }
}
