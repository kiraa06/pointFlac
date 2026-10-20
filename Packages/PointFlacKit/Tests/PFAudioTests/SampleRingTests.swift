import Dispatch
import Foundation
import PFTestSupport
import Synchronization
import Testing

@testable import PFAudio

/// Deterministic PRNG (splitmix64) so chunk-size sequences, and therefore failures, reproduce.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

private func write(_ ring: SampleRing<Int32>, _ values: [Int32]) -> Int {
    values.withUnsafeBufferPointer { ring.write($0) }
}

private func read(_ ring: SampleRing<Int32>, count: Int) -> [Int32] {
    var out = [Int32](repeating: -1, count: count)
    let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    return Array(out.prefix(n))
}

/// How long a stress run may take before it counts as hung: a deadlocked ring would otherwise hang CI. A hang guard,
/// not a performance check. Both runs take about 0.5 s: 2,000,000 elements in a debug simulator build, 10,000,000
/// spinning in the release stage. On the first GitHub run, short of CPU beside the other suites on a 3-vCPU runner, the
/// debug run moved 318,488 elements in 5 s, a pace that needs about 31 s for them all; ×3 under CI (`LatencyBudget`),
/// this covers that pace about twice over.
private let stressHangGuard: Duration = .seconds(20)

private func runStress(total: Int, capacity: Int, chunks: ClosedRange<Int>, spin: Bool) async {
    let ring = SampleRing<Int32>(capacity: capacity)
    let abort = Atomic<Bool>(false)
    let producerDone = DispatchSemaphore(value: 0)
    let consumerDone = DispatchSemaphore(value: 0)
    let mismatches = Atomic<Int>(0)
    let consumed = Atomic<Int>(0)

    let producer = Thread {
        var rng = SplitMix64(state: 0xA11CE)
        let source = (0..<total).map { Int32($0) }
        var next = 0
        source.withUnsafeBufferPointer { src in
            while next < total, !abort.load(ordering: .relaxed) {
                let chunk = min(rng.next(in: chunks), total - next)
                let written = ring.write(UnsafeBufferPointer(rebasing: src[next..<(next + chunk)]))
                next += written
                if written == 0 && !spin { sched_yield() }
            }
        }
        producerDone.signal()
    }

    let consumer = Thread {
        var rng = SplitMix64(state: 0xB0B)
        var scratch = [Int32](repeating: 0, count: chunks.upperBound)
        var expected: Int32 = 0
        var got = 0
        scratch.withUnsafeMutableBufferPointer { buf in
            while got < total, !abort.load(ordering: .relaxed) {
                let chunk = rng.next(in: chunks)
                let n = ring.read(into: UnsafeMutableBufferPointer(rebasing: buf[0..<chunk]))
                if n == 0 {
                    if !spin { sched_yield() }
                    continue
                }
                for i in 0..<n {
                    if buf[i] != expected { mismatches.add(1, ordering: .relaxed) }
                    expected &+= 1
                }
                got += n
                consumed.store(got, ordering: .relaxed)
            }
        }
        consumerDone.signal()
    }

    // The decode thread, the ring's real producer, runs at this QoS. At the default one, a loaded runner serves the
    // pair after the decode threads of the suites running alongside.
    producer.qualityOfService = .userInitiated
    consumer.qualityOfService = .userInitiated

    let hangGuard = LatencyBudget.scaled(stressHangGuard)
    let start = ContinuousClock.now
    producer.start()
    consumer.start()
    // The wait blocks a thread of its own, never a cooperative-pool thread: this task suspends until the wait ends.
    let finished = await withCheckedContinuation { (finished: CheckedContinuation<Bool, Never>) in
        Thread {
            let deadline = DispatchTime.now() + .milliseconds(Int(hangGuard / .milliseconds(1)))
            let producerFinished = producerDone.wait(timeout: deadline) == .success
            let consumerFinished = consumerDone.wait(timeout: deadline) == .success
            abort.store(true, ordering: .relaxed)  // timeout guard: unblock a stuck thread so CI never hangs
            finished.resume(returning: producerFinished && consumerFinished)
        }.start()
    }
    let elapsed = ContinuousClock.now - start

    #expect(
        finished, "producer/consumer did not finish within \(LatencyBudget.describe(stressHangGuard)); took \(elapsed)")
    #expect(mismatches.load(ordering: .relaxed) == 0)
    #expect(consumed.load(ordering: .relaxed) == total)
}

// NOTE on Thread Sanitizer: TSan cannot observe this ring's storage handoff. The element copies go through
// memmove, which is not instrumented against the atomic indices, so a missing barrier yields no TSan report
// (a fully `.relaxed` ring is TSan-clean). The memory ordering is verified by review and by disassembly
// (ldapr/stlr on arm64). `smallRingOrderingStress` in the release stage is a regression net, not a proof.
@Suite struct SampleRingTests {
    @Test func wrapsAroundPreservingOrder() {
        let ring = SampleRing<Int32>(capacity: 8)
        #expect(write(ring, Array(0..<6)) == 6)
        #expect(read(ring, count: 4) == [0, 1, 2, 3])
        // 2 stored + 6 more fills exactly 8 slots and straddles the physical end of the buffer.
        #expect(write(ring, Array(6..<12)) == 6)
        #expect(ring.availableToRead == 8)
        #expect(ring.availableToWrite == 0)
        #expect(read(ring, count: 8) == Array(4..<12))
        #expect(ring.availableToRead == 0)
    }

    @Test func writeReturnsPartialWhenFull() {
        let ring = SampleRing<Int32>(capacity: 8)
        #expect(write(ring, Array(0..<10)) == 8)
        #expect(ring.availableToWrite == 0)
        #expect(write(ring, [99]) == 0)
        #expect(read(ring, count: 16) == Array(0..<8))
    }

    @Test func capacityRoundsUpToPowerOfTwo() {
        let ring = SampleRing<Int32>(capacity: 5)
        #expect(ring.availableToWrite == 8)
    }

    @Test func resetEmptiesTheRing() {
        let ring = SampleRing<Int32>(capacity: 8)
        _ = write(ring, [1, 2, 3])
        ring.reset()
        #expect(ring.availableToRead == 0)
        #expect(ring.availableToWrite == 8)
    }

    @Test func discardReadableDropsOnlyBufferedData() {
        let ring = SampleRing<Int32>(capacity: 16)
        #expect(write(ring, Array(0..<10)) == 10)
        ring.discardReadable()
        #expect(ring.availableToRead == 0)
        #expect(write(ring, [100, 101, 102]) == 3)
        #expect(read(ring, count: 16) == [100, 101, 102])
    }

    @Test func staleTailNeverLetsWriteExceedCapacity() {
        let capacity = 16
        let ring = SampleRing<Int32>(capacity: capacity)
        let big = [Int32](repeating: 7, count: 100)

        // Tail ahead of head (a reset() that raced the consumer): used clamps to 0, never negative.
        ring._setIndicesForTesting(head: 10, tail: 14)
        #expect(ring.availableToRead == 0)
        #expect(ring.availableToWrite <= capacity)
        #expect(ring.availableToWrite == capacity)
        let written = write(ring, big)
        #expect(written <= capacity)
        #expect(written == capacity - 0)

        // Head ahead of tail by more than capacity: used clamps to capacity, so nothing may be written.
        ring._setIndicesForTesting(head: 100, tail: 10)
        #expect(ring.availableToRead == capacity)
        #expect(ring.availableToWrite == 0)
        #expect(write(ring, big) == 0)
    }

    @Test func concurrentProducerConsumerIsExact() async {
        await runStress(total: 2_000_000, capacity: 16_384, chunks: 1...4096, spin: false)
    }
}

/// Regression test for a missing release on the `head` publish (or acquire on its load). A tiny ring with tiny
/// chunks and pure spinning maximises the chance that the consumer observes a new `head` before the data.
/// Only reliable in an optimized build, so it skips itself in debug; `scripts/test.sh` runs it with `-c release`.
@Suite struct SampleRingOrderingTests {
    @Test(.enabled(if: !_isDebugAssertConfiguration(), "needs an optimized build"))
    func smallRingOrderingStress() async {
        await runStress(total: 10_000_000, capacity: 16, chunks: 1...4, spin: true)
    }
}
