import Foundation
import Testing

@testable import PFFind

@Suite struct TokenBucketTests {
    // Timing checks are cumulative from a start instant (slot k is never before start + k × interval), so a test
    // runner under load can only make them later, never fail them.
    @Test func spacesRequestsByTheInterval() async throws {
        let bucket = TokenBucket(interval: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        var stamps: [ContinuousClock.Instant] = []
        for _ in 0..<4 {
            try await bucket.acquire()
            stamps.append(clock.now)
        }
        for (index, stamp) in stamps.enumerated() {
            #expect(stamp - start >= .milliseconds(100 * index - 5))
        }
        // The first slot is free: no initial wait.
        // Generous: only a gross regression (a wait before the first request) fails this.
        #expect(stamps[0] - start < .seconds(1))
    }

    @Test func allowsABurstThenSpaces() async throws {
        let bucket = TokenBucket(interval: .milliseconds(500), burst: 3)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<3 { try await bucket.acquire() }
        #expect(clock.now - start < .milliseconds(450))
        try await bucket.acquire()
        #expect(clock.now - start >= .milliseconds(495))
    }

    @Test func concurrentWaitersNeverOverlap() async throws {
        let bucket = TokenBucket(interval: .milliseconds(60))
        let clock = ContinuousClock()
        let start = clock.now
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
        for (index, stamp) in stamps.enumerated() {
            #expect(stamp - start >= .milliseconds(60 * index - 5))
        }
    }

    @Test func cancellationReturnsTheSlot() async throws {
        // A minute between slots, so the waiter has to sleep however late a loaded machine runs it (with 800 ms, a
        // CI runner once started the waiter after its slot had come, and it never slept to be cancelled).
        let bucket = TokenBucket(interval: .seconds(60))
        try await bucket.acquire()  // Takes the free slot; the next one is a minute out.
        let reservedBefore = await bucket.nextSlotForTesting
        let waiter = Task { try await bucket.acquire() }
        // Wait (bounded) until the waiter has actually reserved its slot, then cancel it.
        let deadline = ContinuousClock.now + .seconds(5)
        while await bucket.nextSlotForTesting == reservedBefore, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await bucket.nextSlotForTesting == reservedBefore + .seconds(60))
        waiter.cancel()
        let result = await waiter.result
        #expect(throws: CancellationError.self) { try result.get() }
        // The cancelled waiter's slot went back: the next caller gets that slot, not the one after it.
        #expect(await bucket.nextSlotForTesting == reservedBefore)
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
