import Synchronization

/// A lock-free single-producer/single-consumer (SPSC) ring buffer of trivially copyable samples.
///
/// The decode thread calls ``write(_:)`` and the real-time render callback calls ``read(into:)``.
/// The read path never allocates, locks, makes syscalls, or touches ARC or Swift arrays.
///
/// ## Index scheme
/// `head` (total elements ever written) and `tail` (total elements ever read) are monotonically increasing
/// `Int` counters. They are never wrapped; physical slots are `index & mask` where `mask = capacity - 1`
/// (capacity is a power of two). Then `head - tail` is the fill level, `0` means empty and `capacity` means
/// full, so every slot is usable and full is distinguishable from empty. A 64-bit counter cannot overflow
/// in practice. Only the producer stores `head`; only the consumer stores `tail`.
///
/// ## Memory ordering
/// The producer copies data, then publishes it with a `.releasing` store to `head`. The consumer's
/// `.acquiring` load of `head` therefore sees the copied data. Symmetrically the consumer finishes copying
/// out before its `.releasing` store to `tail`, so the producer's `.acquiring` load of `tail` guarantees the
/// slots it overwrites have been fully read.
///
/// ## Thread safety
/// `@unchecked Sendable` is sound only under SPSC discipline: exactly one thread calls `write` and exactly
/// one (other) thread calls `read`, concurrently at most. The storage is plain unsynchronised memory, and
/// the two sides touch disjoint slot ranges, handed over by the atomic indices.
public final class SampleRing<Element: BitwiseCopyable>: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Element>
    private let capacity: Int
    private let mask: Int
    private let head = Atomic<Int>(0)  // written by the producer
    private let tail = Atomic<Int>(0)  // written by the consumer

    /// Creates a ring holding at least `capacity` elements; the size is rounded up to a power of two.
    public init(capacity requested: Int) {
        precondition(requested > 0 && requested <= 1 << 62, "SampleRing capacity out of range")
        var size = 1
        while size < requested { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = UnsafeMutablePointer<Element>.allocate(capacity: size)
    }

    deinit {
        // Element is BitwiseCopyable, so there is nothing to deinitialize.
        storage.deallocate()
    }

    /// Elements currently readable, clamped to `0...capacity`.
    ///
    /// Only meaningful when called by the producer or the consumer thread; from any other thread (or
    /// across a `reset()`) the two index loads are not a consistent snapshot.
    public var availableToRead: Int {
        used(head: head.load(ordering: .acquiring), tail: tail.load(ordering: .acquiring))
    }

    /// Free slots currently writable, clamped to `0...capacity`. Same caller restriction as ``availableToRead``.
    public var availableToWrite: Int {
        capacity - availableToRead
    }

    @inline(__always)
    private func used(head h: Int, tail t: Int) -> Int {
        min(max(h - t, 0), capacity)
    }

    /// Testing only: forces raw index values to simulate a `reset()` that raced the consumer. Never call in production.
    internal func _setIndicesForTesting(head h: Int, tail t: Int) {
        head.store(h, ordering: .releasing)
        tail.store(t, ordering: .releasing)
    }

    /// Producer only. Copies as many of `src` as fit and returns the count written.
    public func write(_ src: UnsafeBufferPointer<Element>) -> Int {
        guard let base = src.baseAddress, !src.isEmpty else { return 0 }
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .acquiring)
        // Clamp so a stale tail (reset racing the consumer) can never make us write past the allocation.
        let count = min(src.count, capacity - used(head: h, tail: t))
        guard count > 0 else { return 0 }
        let start = h & mask
        let first = min(count, capacity - start)
        (storage + start).update(from: base, count: first)
        if count > first {
            storage.update(from: base + first, count: count - first)
        }
        head.store(h + count, ordering: .releasing)
        return count
    }

    /// Consumer only; real-time safe. Copies up to `dst.count` elements and returns the count read.
    public func read(into dst: UnsafeMutableBufferPointer<Element>) -> Int {
        guard let base = dst.baseAddress, !dst.isEmpty else { return 0 }
        let t = tail.load(ordering: .acquiring)
        let h = head.load(ordering: .acquiring)
        // Locals only: an assertion that read `capacity` would capture, and so retain, the ring in a debug build.
        let used = h - t
        let limit = capacity
        assert(used >= 0 && used <= limit, "SampleRing index invariant violated")
        let count = min(dst.count, max(used, 0))
        guard count > 0 else { return 0 }
        let start = t & mask
        let first = min(count, capacity - start)
        base.update(from: storage + start, count: first)
        if count > first {
            (base + first).update(from: storage, count: count - first)
        }
        tail.store(t + count, ordering: .releasing)
        return count
    }

    /// Consumer only; real-time safe. Drops up to `count` readable elements, the ones `read(into:)` would copy next,
    /// without copying them, and returns how many it dropped.
    public func skip(_ count: Int) -> Int {
        let t = tail.load(ordering: .acquiring)
        let h = head.load(ordering: .acquiring)
        let n = min(count, max(h - t, 0))
        guard n > 0 else { return 0 }
        tail.store(t + n, ordering: .releasing)
        return n
    }

    /// Consumer only; real-time safe. Drops everything currently readable by advancing `tail` to `head`.
    /// Unlike ``reset()`` this is safe while the producer is writing.
    public func discardReadable() {
        let h = head.load(ordering: .acquiring)
        tail.store(h, ordering: .releasing)
    }

    /// Empties the ring. Valid only while both the producer and the consumer are stopped.
    public func reset() {
        head.store(0, ordering: .releasing)
        tail.store(0, ordering: .releasing)
    }
}
