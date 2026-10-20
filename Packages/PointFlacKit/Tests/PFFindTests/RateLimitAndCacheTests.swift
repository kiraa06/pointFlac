import Foundation
import Testing

@testable import PFFind

@Suite struct TokenBucketTests {
    @Test func spacesRequestsByTheInterval() async throws {
        let bucket = TokenBucket(interval: .milliseconds(100))
        let clock = ContinuousClock()
        var stamps: [ContinuousClock.Instant] = []
        for _ in 0..<4 {
            try await bucket.acquire()
            stamps.append(clock.now)
        }
        for (earlier, later) in zip(stamps, stamps.dropFirst()) {
            #expect(later - earlier >= .milliseconds(90))
        }
        // The first slot is free: no initial wait.
        #expect(stamps[3] - stamps[0] < .milliseconds(600))
    }

    @Test func allowsABurstThenSpaces() async throws {
        let bucket = TokenBucket(interval: .milliseconds(100), burst: 3)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<3 { try await bucket.acquire() }
        #expect(clock.now - start < .milliseconds(60))
        try await bucket.acquire()
        #expect(clock.now - start >= .milliseconds(90))
    }

    @Test func concurrentWaitersNeverOverlap() async throws {
        let bucket = TokenBucket(interval: .milliseconds(60))
        let clock = ContinuousClock()
        let stamps = try await withThrowingTaskGroup(of: ContinuousClock.Instant.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await bucket.acquire()
                    return clock.now
                }
            }
            var all: [ContinuousClock.Instant] = []
            for try await stamp in group { all.append(stamp) }
            return all.sorted()
        }
        for (earlier, later) in zip(stamps, stamps.dropFirst()) {
            #expect(later - earlier >= .milliseconds(50))
        }
    }

    @Test func cancellationReturnsTheSlot() async throws {
        let bucket = TokenBucket(interval: .milliseconds(300))
        try await bucket.acquire()  // Takes the free slot; the next one is 300 ms out.
        let waiter = Task { try await bucket.acquire() }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        let result = await waiter.result
        #expect(throws: CancellationError.self) { try result.get() }
        // The cancelled waiter's slot went back, so the next caller waits for that slot, not one after it.
        let clock = ContinuousClock()
        let start = clock.now
        try await bucket.acquire()
        #expect(clock.now - start < .milliseconds(330))
    }

    @Test func penaltyHoldsTheNextRequestBack() async throws {
        let bucket = TokenBucket(interval: .milliseconds(10))
        await bucket.penalize(for: .milliseconds(150))
        let clock = ContinuousClock()
        let start = clock.now
        try await bucket.acquire()
        #expect(clock.now - start >= .milliseconds(130))
    }
}

@Suite struct CacheTests {
    @Test func lruEvictsTheLeastRecentlyUsed() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        #expect(cache.value(for: "a") == 1)  // "a" is now the most recent.
        cache.insert(3, for: "c")
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.count == 2)
    }

    @Test func diskCacheHonoursTimeToLiveAndServesStaleOnRequest() throws {
        let folder = TemporaryDirectory()
        let cache = DiskCache(directory: folder.url, timeToLive: 60)
        let written = Date(timeIntervalSince1970: 1_000_000)
        cache.write(Data("hello".utf8), for: "key", now: written)
        let fresh = try #require(cache.read("key", now: written.addingTimeInterval(30)))
        #expect(fresh.isFresh)
        #expect(String(decoding: fresh.data, as: UTF8.self) == "hello")
        #expect(cache.read("key", now: written.addingTimeInterval(120)) == nil)
        let stale = try #require(cache.read("key", allowStale: true, now: written.addingTimeInterval(120)))
        #expect(!stale.isFresh)
        #expect(cache.read("other") == nil)
    }

    @Test func diskCachePrunesOldestBeyondItsCap() throws {
        let folder = TemporaryDirectory()
        let cache = DiskCache(directory: folder.url, timeToLive: 3600, maxEntries: 3)
        let base = Date()
        for index in 0..<5 {
            cache.write(Data("\(index)".utf8), for: "k\(index)", now: base.addingTimeInterval(Double(index)))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(files.count == 3)
        #expect(cache.read("k0", allowStale: true) == nil)
        #expect(cache.read("k4", allowStale: true) != nil)
    }
}
