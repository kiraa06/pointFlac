import Dispatch
import Foundation
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

    @Test func concurrentProducerConsumerIsExact() {
        let total = 2_000_000
        let ring = SampleRing<Int32>(capacity: 16_384)
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
                    let chunk = min(rng.next(in: 1...4096), total - next)
                    let written = ring.write(UnsafeBufferPointer(rebasing: src[next..<(next + chunk)]))
                    next += written
                    if written == 0 { sched_yield() }
                }
            }
            producerDone.signal()
        }

        let consumer = Thread {
            var rng = SplitMix64(state: 0xB0B)
            var scratch = [Int32](repeating: 0, count: 4096)
            var expected: Int32 = 0
            var got = 0
            scratch.withUnsafeMutableBufferPointer { buf in
                while got < total, !abort.load(ordering: .relaxed) {
                    let chunk = rng.next(in: 1...4096)
                    let n = ring.read(into: UnsafeMutableBufferPointer(rebasing: buf[0..<chunk]))
                    if n == 0 {
                        sched_yield()
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

        let start = ContinuousClock.now
        producer.start()
        consumer.start()
        let deadline = DispatchTime.now() + .seconds(5)
        let producerFinished = producerDone.wait(timeout: deadline) == .success
        let consumerFinished = consumerDone.wait(timeout: deadline) == .success
        abort.store(true, ordering: .relaxed)  // timeout guard: unblock a stuck thread so CI never hangs
        let elapsed = ContinuousClock.now - start

        #expect(producerFinished && consumerFinished, "producer/consumer did not finish within 5 s")
        #expect(mismatches.load(ordering: .relaxed) == 0)
        #expect(consumed.load(ordering: .relaxed) == total)
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }
}
