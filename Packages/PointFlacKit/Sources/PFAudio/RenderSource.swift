import Synchronization

/// The real-time end of the pipeline: the output's render callback pulls client-format audio from here, and the
/// pipeline's decode thread fills it.
///
/// The ring holds 32-bit words: Float32 bit patterns or Int32 samples, whichever the plan's client format is, so one
/// type serves both clients and `render` is a plain copy. One `RenderSource` serves one output configuration; at a
/// format change the pipeline replaces it while the output is stopped, carrying `renderedFrames` over so the count
/// stays continuous.
///
/// ## Real-time safety
/// `render(into:frames:)` touches only the preallocated ring and atomics. It does not allocate, lock, log or cause
/// ARC traffic: it reaches the ring through an unretained reference, kept alive by `ring`. Events are not emitted
/// from here; the decode thread compares `renderedFrames` with its boundary markers instead.
///
/// ## Flushing while the render thread runs
/// `SampleRing.reset()` is unsafe while the consumer runs, so the producer never calls it while the output is
/// started. To drop buffered audio it bumps `flushRequested` after its last write and waits. The next `render` sees
/// the new generation, calls `ring.discardReadable()` (consumer side, so safe), acknowledges in
/// `flushAcknowledged`, and outputs silence for that callback. The producer's release store of the generation comes
/// after its ring writes, and render's acquire load of it comes before the discard, so the discard covers every word
/// written before the request. The producer's acquire load of the acknowledgement then orders the discard before
/// anything it writes next.
///
/// ## Underruns
/// `render` counts the frames of silence it fills because the ring ran dry mid-stream (`underrunFrames`), with a few
/// atomic loads and stores and no clock or lock, so the count is real-time safe. Deliberate silence is not counted:
/// flushes, seek holds, the start-up before this source's first real frame, and the end of the stream once the
/// producer has marked it (`markEndOfStream`). What remains is audio that should have been there: a decode thread or
/// file read too slow, and the short gap after a seek before the new position's audio arrives.
///
/// ## Seek holds
/// A flush needs the decode thread, which may take a few milliseconds to notice a seek, and the audio before the seek
/// must not keep playing meanwhile. So `seek(toFrame:)` first places a hold (`seeksRequested` += 1). While
/// `seeksRequested != seeksServed`, `render` outputs silence without touching the ring. The decode thread flushes
/// and only then releases the holds up to the ticket it read together with the seek request, under the same lock.
/// A hold placed after that ticket (a newer seek) stays in force until that seek is served too.
public final class RenderSource: @unchecked Sendable {
    public let channels: Int
    private let ring: SampleRing<UInt32>
    /// `ring`, unretained, so `render` reaches it without retain/release. The strong `ring` keeps it alive.
    private let unretainedRing: Unmanaged<SampleRing<UInt32>>
    /// Real frames rendered so far, including those of the sources this one replaced. Written only by `render`.
    private let rendered: Atomic<Int64>
    /// Written only by the producer.
    private let flushRequested = Atomic<UInt64>(0)
    /// Written by `render`, or by the producer while the output is stopped.
    private let flushAcknowledged = Atomic<UInt64>(0)
    /// Bumped by `seek(toFrame:)` callers, under the pipeline's lock.
    private let seeksRequested: Atomic<UInt64>
    /// Written only by the producer.
    private let seeksServed: Atomic<UInt64>
    /// Frames of silence filled because the ring ran dry mid-stream, including those of the sources this one replaced.
    /// Written only by `render`.
    private let underruns: Atomic<Int64>
    /// `renderedFrames` when this source was made: until `render` passes it, the ring is still filling (start-up).
    private let startFrames: Int64
    /// Set by the producer after the last audio it will write for now (the end of the queue, or a drain before a
    /// format change); cleared by its next write.
    private let endOfStream = Atomic<Bool>(false)

    /// - Parameters:
    ///   - capacityFrames: ring size in frames (rounded up to a power of two in samples).
    ///   - renderedFrames: the count to continue from, so markers keyed by rendered frame stay valid.
    ///   - previous: the source this one replaces. Its seek holds carry over, so a seek placed during a format
    ///     change is still held. Pass it only while neither source is being rendered.
    init(channels: Int, capacityFrames: Int, renderedFrames: Int64, inheritingHoldsFrom previous: RenderSource?) {
        precondition(channels > 0 && capacityFrames > 0, "RenderSource needs channels and capacity")
        self.channels = channels
        let ring = SampleRing<UInt32>(capacity: capacityFrames * channels)
        self.ring = ring
        unretainedRing = .passUnretained(ring)
        rendered = Atomic(renderedFrames)
        startFrames = renderedFrames
        underruns = Atomic(previous?.underrunFrames ?? 0)
        seeksRequested = Atomic(previous?.seeksRequested.load(ordering: .acquiring) ?? 0)
        seeksServed = Atomic(previous?.seeksServed.load(ordering: .acquiring) ?? 0)
    }

    /// Real frames rendered so far: underrun and hold silence is not counted. `position` and the track events derive
    /// from this.
    public var renderedFrames: Int64 {
        rendered.load(ordering: .acquiring)
    }

    /// Frames of silence rendered because the ring ran dry mid-stream (see "Underruns"). Any thread; read-only.
    public var underrunFrames: Int64 {
        underruns.load(ordering: .acquiring)
    }

    /// Render thread only, one call at a time; real-time safe.
    ///
    /// Writes `frames` × `channels` interleaved 32-bit samples to `buffer`, which must have room for them. What the
    /// ring cannot supply is zero-filled (silence in both client formats). Returns the frames of real audio, which
    /// are always a prefix of the buffer.
    public func render(into buffer: UnsafeMutableRawPointer, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let count = frames * channels
        let words = buffer.bindMemory(to: UInt32.self, capacity: count)
        let flush = flushRequested.load(ordering: .acquiring)
        if flush != flushAcknowledged.load(ordering: .relaxed) {
            unretainedRing._withUnsafeGuaranteedRef { $0.discardReadable() }
            flushAcknowledged.store(flush, ordering: .releasing)
            words.update(repeating: 0, count: count)
            return 0
        }
        if seeksRequested.load(ordering: .acquiring) != seeksServed.load(ordering: .acquiring) {
            words.update(repeating: 0, count: count)
            return 0
        }
        let got = unretainedRing._withUnsafeGuaranteedRef {
            $0.read(into: UnsafeMutableBufferPointer(start: words, count: count))
        }
        if got < count {
            (words + got).update(repeating: 0, count: count - got)
        }
        let real = got / channels
        let before = rendered.load(ordering: .relaxed)
        if real > 0 {
            rendered.store(before + Int64(real), ordering: .releasing)
        }
        if real < frames, before > startFrames, !endOfStream.load(ordering: .acquiring) {
            underruns.store(underruns.load(ordering: .relaxed) + Int64(frames - real), ordering: .releasing)
        }
        return real
    }

    // MARK: Producer side (the decode thread)

    /// Whole frames the ring can take right now.
    var writableFrames: Int {
        ring.availableToWrite / channels
    }

    /// Writes as many whole frames of `words` as fit and returns how many words it wrote. Partial frames are never
    /// written, so the render side always reads whole frames.
    func write(_ words: UnsafeBufferPointer<UInt32>) -> Int {
        if endOfStream.load(ordering: .relaxed) { endOfStream.store(false, ordering: .releasing) }
        let fit = min(words.count, ring.availableToWrite) / channels * channels
        guard fit > 0 else { return 0 }
        return ring.write(UnsafeBufferPointer(rebasing: words[0..<fit]))
    }

    /// Producer only: everything to be written for now is written (the end of the queue, or before a drain for a
    /// format change), so from here the ring running dry is the stream's end, not an underrun. The next `write`
    /// clears it.
    func markEndOfStream() {
        endOfStream.store(true, ordering: .releasing)
    }

    /// Asks `render` to drop everything buffered. Call after the last write of the audio to drop; returns the
    /// generation to wait for with `isFlushAcknowledged(_:)`.
    func requestFlush() -> UInt64 {
        let generation = flushRequested.load(ordering: .relaxed) &+ 1
        flushRequested.store(generation, ordering: .releasing)
        return generation
    }

    func isFlushAcknowledged(_ generation: UInt64) -> Bool {
        flushAcknowledged.load(ordering: .acquiring) >= generation
    }

    /// Empties the ring outright. Only while the output is stopped, when no `render` call can run.
    func flushWhileStopped() {
        ring.reset()
        flushAcknowledged.store(flushRequested.load(ordering: .relaxed), ordering: .releasing)
    }

    // MARK: Seek holds

    /// Any thread, under the pipeline's lock: `render` plays silence from now until the seek is served.
    func holdForSeek() {
        seeksRequested.wrappingAdd(1, ordering: .acquiringAndReleasing)
    }

    /// The newest hold. Read under the pipeline's lock, together with the seek request it covers.
    var seekHoldTicket: UInt64 {
        seeksRequested.load(ordering: .acquiring)
    }

    /// Producer only, after the flush: releases the holds up to `ticket`. A newer hold stays in force.
    func releaseSeekHolds(through ticket: UInt64) {
        seeksServed.store(ticket, ordering: .releasing)
    }
}
