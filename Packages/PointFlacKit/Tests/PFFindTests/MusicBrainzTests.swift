import Foundation
import Synchronization
import Testing

@testable import PFFind

@Suite struct MusicBrainzQueryTests {
    @Test func splitQueryCoversEveryTitleArtistSplit() throws {
        let query = try #require(MusicBrainzQuery.releaseGroup("The Mountain Gorillaz", partial: false))
        #expect(query.hasPrefix("releasegroup:(the AND mountain~1 AND gorillaz~1) OR artist:("))
        #expect(query.contains("(releasegroup:(the AND mountain~1) AND artist:(gorillaz~1))"))
        #expect(query.contains("(artist:(the AND mountain~1) AND releasegroup:(gorillaz~1))"))
        // "the" alone is not a meaningful side of a split.
        #expect(!query.contains("releasegroup:(the) AND"))
        #expect(!query.contains("artist:(the) AND"))
    }

    @Test func lastWordIsAPrefixWhileTyping() throws {
        let query = try #require(MusicBrainzQuery.artist("Gorill", partial: true))
        #expect(query == "artist:(gorill*) OR alias:(gorill*) OR sortname:(gorill*)")
    }

    @Test func foldsAndDropsOperatorWords() throws {
        let query = try #require(MusicBrainzQuery.artist("Simon & Garfunkel", partial: false))
        let group = "(simon~1 AND garfunkel~1)"
        #expect(query == "artist:\(group) OR alias:\(group) OR sortname:\(group)")
        #expect(MusicBrainzQuery.artist("  &  ", partial: false) == nil)
    }

    @Test func longQueriesSkipTheSplits() throws {
        let query = try #require(
            MusicBrainzQuery.recording("one two three four five six seven", partial: false))
        #expect(!query.contains(" AND artist:"))
    }

    @Test func escapesLuceneSpecials() {
        #expect(MusicBrainzQuery.escape("a:b(c)") == #"a\:b\(c\)"#)
    }
}

@Suite struct MusicBrainzDecodingTests {
    @Test func decodesRecordedReleaseGroupSearch() throws {
        let response = try JSONDecoder().decode(
            MB.SearchResponse.self, from: fixture("mb-release-group-the-mountain-gorillaz"))
        let group = try #require(response.releaseGroups?.first)
        #expect(group.title == "The Mountain")
        #expect(group.primaryType == "Album")
        #expect(group.firstReleaseDate == "2026-02-27")
        #expect(group.artistCredit?.first?.artist.name == "Gorillaz")
        let suggestion = MusicBrainzRegistry.suggestion(releaseGroup: group)
        #expect(suggestion.kind == .album)
        #expect(suggestion.subtitle == "Gorillaz · 2026 · Album")
        #expect(suggestion.entity.releaseGroupID == group.id)
        #expect(suggestion.entity.artistAliases.contains("Gorilaz"))
        #expect(!suggestion.entity.artistAliases.contains("ゴリラズ"))
    }

    @Test func picksTheUsualTrackCount() throws {
        let response = try JSONDecoder().decode(MB.SearchResponse.self, from: fixture("mb-release-the-mountain"))
        #expect(MusicBrainzRegistry.usualTrackCount(response.releases ?? []) == 15)
    }

    @Test func dedupesRecordingVersionsAndPrefersTheStudioAlbum() throws {
        let response = try JSONDecoder().decode(
            MB.SearchResponse.self, from: fixture("mb-recording-feel-good-inc"))
        let rows = MusicBrainzRegistry.suggestions(from: response, entity: .recording)
        let titles = rows.map { "\($0.title)|\($0.entity.artistCredit ?? "")" }
        #expect(Set(titles).count == titles.count)
        let first = try #require(rows.first)
        #expect(first.entity.artist == "Gorillaz")
        #expect(first.entity.artistCredit == "Gorillaz featuring De La Soul")
    }

    @Test func artistSuggestionsCarryAliasesAndSortNames() throws {
        let response = try JSONDecoder().decode(MB.SearchResponse.self, from: fixture("mb-artist-bjork"))
        let first = try #require(response.artists?.first.map(MusicBrainzRegistry.suggestion(artist:)))
        #expect(first.title == "Björk")
        #expect(first.entity.artistAliases.contains("Bjørk"))
    }
}

@Suite struct MusicBrainzClientTests {
    @Test func sendsTheUserAgentAndCachesInMemory() async throws {
        let stub = StubMusicBrainz { _ in (200, [:], try fixture("mb-artist-gorill-prefix")) }
        let client = stub.client()
        let first = try await client.search(.artist, query: "artist:(gorill*)")
        let second = try await client.search(.artist, query: "artist:(gorill*)")
        #expect(first.artists?.first?.name == "Gorillaz")
        #expect(second.artists?.first?.name == "Gorillaz")
        #expect(stub.requestCount == 1)
        let userAgent = stub.requests.withLock { $0.first?.userAgent }
        #expect(userAgent == "pointFlac/0.2 ( https://github.com/kiraa06/pointFlac )")
        let url = try #require(stub.requests.withLock { $0.first?.url })
        #expect(url.path == "/ws/2/artist")
        #expect(url.query?.contains("fmt=json") == true)
    }

    @Test func diskCacheServesARepeatAcrossClients() async throws {
        let folder = TemporaryDirectory()
        let stub = StubMusicBrainz { _ in (200, [:], try fixture("mb-artist-gorill-prefix")) }
        _ = try await stub.client(disk: DiskCache(directory: folder.url)).search(.artist, query: "q")
        let fresh = stub.client(disk: DiskCache(directory: folder.url))
        _ = try await fresh.search(.artist, query: "q")
        #expect(stub.requestCount == 1)
        #expect(await fresh.networkRequests == 0)
        #expect(await fresh.cachedSearch(.artist, query: "q")?.artists?.isEmpty == false)
    }

    @Test func requestsAreSpacedByTheBucket() async throws {
        let stub = StubMusicBrainz { _ in (200, [:], try fixture("mb-artist-gorill-prefix")) }
        let client = stub.client(interval: .milliseconds(150))
        for index in 0..<3 {
            _ = try await client.search(.artist, query: "query \(index)")
        }
        let stamps = stub.requests.withLock { $0.map(\.at) }
        #expect(stamps.count == 3)
        for (earlier, later) in zip(stamps, stamps.dropFirst()) {
            #expect(later - earlier >= .milliseconds(130))
        }
    }

    @Test func retriesAfterBusyThenSucceeds() async throws {
        let calls = Counter()
        let stub = StubMusicBrainz { _ in
            if calls.increment() == 1 {
                return (503, ["Retry-After": "0.05"], try fixture("mb-503-busy"))
            }
            return (200, [:], try fixture("mb-artist-gorill-prefix"))
        }
        let response = try await stub.client().search(.artist, query: "q")
        #expect(response.artists?.first?.name == "Gorillaz")
        #expect(stub.requestCount == 2)
    }

    @Test func staysBusyAfterRetriesWithoutACache() async throws {
        let stub = StubMusicBrainz { _ in (503, [:], try fixture("mb-503-busy")) }
        await #expect(throws: MusicBrainzError.busy) {
            _ = try await stub.client(busyRetries: 1).search(.artist, query: "q")
        }
        #expect(stub.requestCount == 2)
    }

    @Test func servesStaleCacheWhenOffline() async throws {
        let folder = TemporaryDirectory()
        let disk = DiskCache(directory: folder.url, timeToLive: 0)
        let online = StubMusicBrainz { _ in (200, [:], try fixture("mb-artist-gorill-prefix")) }
        let url = online.client().searchURL(.artist, query: "q", limit: 8)
        // Pre-seed the cache under the offline stub's URL: same query, different host.
        let offline = StubMusicBrainz { _ in throw URLError(.notConnectedToInternet) }
        let offlineURL = offline.client().searchURL(.artist, query: "q", limit: 8)
        disk.write(try fixture("mb-artist-gorill-prefix"), for: offlineURL.absoluteString)
        #expect(url != offlineURL)
        let response = try await offline.client(disk: disk).search(.artist, query: "q")
        #expect(response.artists?.first?.name == "Gorillaz")
        await #expect(throws: MusicBrainzError.offline) {
            _ = try await offline.client(disk: disk).search(.artist, query: "never cached")
        }
    }

    @Test func cancellingAbandonsTheInFlightRequest() async throws {
        let stub = StubMusicBrainz { _ in
            try await Task.sleep(for: .seconds(5))
            return (200, [:], try fixture("mb-artist-gorill-prefix"))
        }
        let client = stub.client()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await client.search(.artist, query: "slow") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func refusesOversizedResponses() async throws {
        let stub = StubMusicBrainz { _ in (200, [:], Data(repeating: 0x20, count: 4096)) }
        let client = MusicBrainzClient(
            configuration: .init(baseURL: stub.baseURL, maxResponseBytes: 1024), session: stub.session,
            bucket: TokenBucket(interval: .milliseconds(1)), disk: nil)
        await #expect(throws: MusicBrainzError.self) {
            _ = try await client.search(.artist, query: "big")
        }
    }
}

/// A thread-safe call counter for stub routes.
final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() -> Int {
        value.withLock { count in
            count += 1
            return count
        }
    }
}
