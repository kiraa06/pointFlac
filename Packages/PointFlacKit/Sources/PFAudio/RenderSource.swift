import PFDSP
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
/// `render(into:frames:)` touches only the preallocated ring, scratch and atomics, and the chain runner's own
/// preallocated state. It does not allocate, lock, log or cause ARC traffic: it reaches the ring, the scrub tap and the
/// chain runner through unretained references, kept alive by the strong ones beside them. Events are not emitted
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
///
/// ## The Sound chain
/// Whatever `render` produces, from the ring or the scrub voice, silence included, then runs through the pipeline's
/// `ChainRunner` before iOS gets it, so the chain is a filter on the output stream itself: EQ is part of the sound
/// while scrubbing too, and a seek's or a gap's silence lets the chain's look-ahead and filters ring out naturally. A
/// Float32 client's words are its samples, processed in place. An Int32 client's are converted through the scratch
/// buffer, and only where the runner is not idle; a word whose sample came back unchanged is kept as it was, so a
/// 32-bit word's low bits never take a Float32 round trip. In Pure the runner leaves every word alone: the output is
/// bit-identical to the path without it. The chain's latency (its look-ahead) delays the audio, so the last few
/// milliseconds before a format change, or a stop, stay in it unheard; `renderedFrames` still counts ring frames.
/// `lastBlockIsSilent` tells the output when a block with no real frames is silent all the same: with the chain at
/// work it may carry the chain's tail, so it is not. Known limitation: the runner takes Float32, so with a chain on,
/// an Int32 client's samples take a Float32 hop either side of the Float64 chain (over 140 dB down), and a scrub
/// voice on an Int32 client is converted to words before the chain and back.
///
/// ## Scrubbing
/// While a finger is on the record (`ScrubTap`), `render` plays the tap's `ScrubVoice` instead of the ring: the ring is
/// left alone (the decode thread waits on it, full) and `renderedFrames` stands still, but flush requests are still
/// acknowledged, so a seek can be served meanwhile. When a playing record is let go, the voice spins up to speed and
/// the player seeks the pipeline a little ahead of it; once that audio is in the ring and the needle reaches it, the
/// ring takes over with a short cross-fade, and counting resumes from there.
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
    /// The pipeline's scrub tap, unretained for `render`; `scrub` keeps it alive.
    private let scrub: ScrubTap?
    private let unretainedScrub: Unmanaged<ScrubTap>?
    /// The pipeline's Sound chain runner, one for all its sources, unretained for `render`; `sound` keeps it alive.
    private let sound: ChainRunner?
    private let unretainedSound: Unmanaged<ChainRunner>?
    /// Render thread only: whether the latest block is silence through and through, no real frames and no chain at
    /// work that could ring out into them. The output reads it right after `render`, on the same thread. Unchecked: a
    /// debug build's exclusivity check would allocate on the render thread's first call.
    @exclusivity(unchecked) private(set) var lastBlockIsSilent = true
    /// The client rate and sample format, which the scrub voice needs and the ring does not.
    private let clientRate: Int
    private let floatClient: Bool
    /// The voice's frames before they become client words. Preallocated for `scratchFrames`.
    private let scratch: UnsafeMutablePointer<Float>
    private static let scratchFrames = 4096
    /// The cross-fade from the voice to the ring at the handover, and the fade-out of a let-go stopped record.
    static let crossfadeSeconds = 0.006
    /// Frames decoded past the needle before the voice takes over from the ring.
    static let startAhead: Int64 = 2048
    static let fadeOutSeconds = 0.012

    /// - Parameters:
    ///   - capacityFrames: ring size in frames (rounded up to a power of two in samples).
    ///   - renderedFrames: the count to continue from, so markers keyed by rendered frame stay valid.
    ///   - previous: the source this one replaces. Its seek holds carry over, so a seek placed during a format
    ///     change is still held. Pass it only while neither source is being rendered.
    init(
        channels: Int, capacityFrames: Int, renderedFrames: Int64, inheritingHoldsFrom previous: RenderSource?,
        clientRate: Int = 0, floatClient: Bool = true, scrub: ScrubTap? = nil, sound: ChainRunner? = nil
    ) {
        precondition(channels > 0 && capacityFrames > 0, "RenderSource needs channels and capacity")
        self.channels = channels
        self.clientRate = clientRate
        self.floatClient = floatClient
        self.scrub = scrub
        unretainedScrub = scrub.map { .passUnretained($0) }
        self.sound = sound
        unretainedSound = sound.map { .passUnretained($0) }
        scratch = .allocate(capacity: Self.scratchFrames * channels)
        let ring = SampleRing<UInt32>(capacity: capacityFrames * channels)
        self.ring = ring
        unretainedRing = .passUnretained(ring)
        rendered = Atomic(renderedFrames)
        startFrames = renderedFrames
        underruns = Atomic(previous?.underrunFrames ?? 0)
        seeksRequested = Atomic(previous?.seeksRequested.load(ordering: .acquiring) ?? 0)
        seeksServed = Atomic(previous?.seeksServed.load(ordering: .acquiring) ?? 0)
        // Built here, off the render thread, so the voice's first use never builds it there.
        if scrub != nil { _ = ScrubKernel() }
        // Warms the Int32-to-Double conversion's witness table off the render thread: its first use calls into the
        // runtime once, and the Int32 chain path converts every sample.
        _ = int32Sample(0)
    }

    deinit {
        scratch.deallocate()
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
    /// ring cannot supply is zero-filled (silence in both client formats), then the whole block runs through the Sound
    /// chain, whose look-ahead and filters may ring out into that silence. Returns the frames of real audio, which are
    /// always a prefix of the buffer.
    ///
    /// No closure here captures a class reference, so a debug build does no reference counting either: the runner is
    /// reached through `Unmanaged`, by free functions given only pointers and integers.
    public func render(into buffer: UnsafeMutableRawPointer, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let words = buffer.bindMemory(to: UInt32.self, capacity: frames * channels)
        let real = produce(into: words, frames: frames)
        var silent = real == 0
        if let unretainedSound {
            // Read before the chain runs: an idle runner leaves the block as it is.
            if !soundIsIdle(unretainedSound) { silent = false }
            runSound(
                unretainedSound, on: buffer, frames: frames, channels: channels, floatClient: floatClient,
                scratch: scratch, scratchFrames: Self.scratchFrames)
        }
        lastBlockIsSilent = silent
        return real
    }

    /// The block before the Sound chain: the ring's words, the scrub voice's, or silence. Returns the real frames.
    private func produce(into words: UnsafeMutablePointer<UInt32>, frames: Int) -> Int {
        let count = frames * channels
        // The window is looked at first, without a closure that holds this source: only a scrub pays the debug
        // build's reference counting of `renderScrubbed` (a follow-up), not every call.
        if let unretainedScrub, scrubWindowIsOpen(unretainedScrub),
            let scrubbed = renderScrubbed(unretainedScrub, into: words, frames: frames)
        {
            return scrubbed
        }
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

    // MARK: The Sound chain (render thread)

    // MARK: Scrubbing (render thread)

    /// `renderScrub` with the tap. Its closure holds this source, which a debug build retains: that is why `produce`
    /// first checks the window without one.
    private func renderScrubbed(
        _ tap: Unmanaged<ScrubTap>, into words: UnsafeMutablePointer<UInt32>, frames: Int
    ) -> Int? {
        tap._withUnsafeGuaranteedRef { renderScrub($0, into: words, frames: frames) }
    }

    /// Plays the scrub voice for this call, or returns nil when no finger is on the record and the ring plays.
    private func renderScrub(_ tap: ScrubTap, into words: UnsafeMutablePointer<UInt32>, frames: Int) -> Int? {
        // Announce the read before looking at the window (sequentially consistent with `retireWindow`).
        tap.rendering.store(true, ordering: .sequentiallyConsistent)
        defer { tap.rendering.store(false, ordering: .releasing) }
        let state = tap.state
        let generation = tap.generation.load(ordering: .acquiring)
        let phase = ScrubTap.Phase(rawValue: tap.phase.load(ordering: .sequentiallyConsistent)) ?? .idle
        guard let rawWindow = tap.window.load(ordering: .sequentiallyConsistent), phase != .idle else {
            state.pointee.voice = nil
            return nil
        }
        // `begin` writes a new run's phase and hand before bumping the generation: if one began meanwhile, this call
        // still belongs to the old run, so it ignores the phase's commands; the next call starts the new run.
        let settled = tap.generation.load(ordering: .acquiring) == generation
        let ringAllowed = tap.ringAllowed.load(ordering: .acquiring)
        /// No voice to play: a playing record plays on from the ring; a paused one is silent (its ring holds the
        /// music at the old cue, which must never be heard).
        func withoutVoice() -> Int? {
            if ringAllowed { return nil }
            words.update(repeating: 0, count: frames * channels)
            return frames
        }
        let window = Unmanaged<ScrubWindow>.fromOpaque(rawWindow)
        return window._withUnsafeGuaranteedRef { window -> Int? in
            if state.pointee.generation != generation {
                state.pointee = ScrubRenderState(generation: generation)
            }
            // The voice belongs to the source it started on. A let-go at a track's end can carry the pipeline into
            // the next track in another format (channels or rate): that source plays the ring, the voice is done.
            if state.pointee.voice != nil,
                state.pointee.voiceChannels != channels || state.pointee.voiceClientRate != clientRate
            {
                state.pointee.voice = nil
                tap.handedOver.store(generation, ordering: .releasing)
                return withoutVoice()
            }
            if state.pointee.voice == nil, !state.pointee.started {
                guard clientRate > 0, (1...8).contains(channels), window.channels == channels else {
                    return withoutVoice()
                }
                // The voice starts where the ring would play next, at the speed the record turns, once the music
                // there is decoded. Until then (a few milliseconds) a playing record plays on from the ring, so the
                // hand's landing is seamless, and a paused one stays silent.
                let rendered = self.rendered.load(ordering: .relaxed)
                let sourcePerClient = Double(window.sourceRate) / Double(clientRate)
                let start =
                    Double(tap.anchorFrame.load(ordering: .relaxed))
                    + Double(rendered - tap.anchorRendered.load(ordering: .relaxed)) * sourcePerClient
                let speed = Double(bitPattern: tap.startSpeedBits.load(ordering: .relaxed))
                window.head.store(Int64(start.rounded(.down)), ordering: .releasing)
                let valid = window.valid
                let needle = Int64(start.rounded(.down))
                let behind = Int64(ScrubKernel.reach(cutoff: ScrubKernel.cutoff(forAdvance: 1))) + 1
                guard needle - behind >= valid.lowerBound, needle + Self.startAhead < valid.upperBound else {
                    return withoutVoice()
                }
                state.pointee.started = true
                state.pointee.start = start
                state.pointee.voiceChannels = channels
                state.pointee.voiceClientRate = clientRate
                state.pointee.voice = ScrubVoice(
                    channels: channels, sourceRate: Double(window.sourceRate), outputRate: Double(clientRate),
                    at: start, speed: speed)
                // A playing record's ring played on while the needle's music decoded (a few milliseconds), and the
                // hand may have moved meanwhile: from here the voice follows the hand's movement since now, so that
                // gap is neither counted twice (a rush forward) nor pulled back to the grab point (an audible zip).
                // A paused record played nothing meanwhile, so its offsets count from the grab point.
                if let hand = tap.readHand(after: 0) {
                    state.pointee.handSequence = hand.sequence
                    state.pointee.handBase = ringAllowed ? hand.offset : 0
                    state.pointee.voice?.hand(
                        target: max(0, start + hand.offset - state.pointee.handBase), speed: hand.speed)
                }
                tap.voicePositionBits.store(start.bitPattern, ordering: .releasing)
                tap.voiceSpeedBits.store(speed.bitPattern, ordering: .releasing)
                tap.voiceStarted.store(generation, ordering: .releasing)
            }
            guard var voice = state.pointee.voice else { return withoutVoice() }
            renderVoice(
                &voice, state: state, tap: tap, phase: settled ? phase : nil, window: window, into: words,
                frames: frames)
            state.pointee.voice = state.pointee.crossfade == Int.max ? nil : voice
            return frames
        }
    }

    private func renderVoice(
        _ voice: inout ScrubVoice, state: UnsafeMutablePointer<ScrubRenderState>, tap: ScrubTap,
        phase: ScrubTap.Phase?, window: ScrubWindow, into words: UnsafeMutablePointer<UInt32>, frames: Int
    ) {
        // A seek (the handover's) needs its flush acknowledged even though the ring is not being played.
        let flush = flushRequested.load(ordering: .acquiring)
        if flush != flushAcknowledged.load(ordering: .relaxed) {
            unretainedRing._withUnsafeGuaranteedRef { $0.discardReadable() }
            flushAcknowledged.store(flush, ordering: .releasing)
        }
        switch phase {
        case .hand:
            if let hand = tap.readHand(after: state.pointee.handSequence) {
                state.pointee.handSequence = hand.sequence
                var target = max(0, state.pointee.start + hand.offset - state.pointee.handBase)
                if window.totalFrames > 0 { target = min(target, Double(window.totalFrames)) }
                voice.hand(target: target, speed: hand.speed)
            }
        case .motor:
            if !state.pointee.released {
                state.pointee.released = true
                voice.release(toSpeed: 1, seconds: Double(bitPattern: tap.motorSecondsBits.load(ordering: .relaxed)))
            }
        case .fade:
            if state.pointee.fadeLeft < 0 {
                state.pointee.fadeLeft = max(1, Int(Self.fadeOutSeconds * Double(clientRate)))
            }
        case .idle, nil:
            break
        }
        // Where in this call the ring takes over: once the handover's audio is in the ring and the needle reaches it.
        var voiceOnly = frames
        if phase == .motor, state.pointee.crossfade < 0 {
            let handover = tap.handoverFrame.load(ordering: .acquiring)
            let held = seeksRequested.load(ordering: .acquiring) != seeksServed.load(ordering: .acquiring)
            let buffered = unretainedRing._withUnsafeGuaranteedRef { $0.availableToRead } >= frames * channels
            let step = voice.speed * voice.nominal
            if handover >= 0, !held, buffered, step > 0 {
                let reach = Int(((Double(handover) - voice.position) / step).rounded(.up))
                if reach < 0 {
                    // The seek took longer than the lead and the needle is past the handover frame: skip the ring
                    // forward to the needle (as far as it is buffered) rather than replay what the voice just played.
                    let available = unretainedRing._withUnsafeGuaranteedRef { $0.availableToRead } / channels
                    skipRing(min(-reach, max(0, available - frames)))
                }
                if reach < frames {
                    voiceOnly = max(0, reach)
                    state.pointee.crossfade = 0
                }
            }
        } else if state.pointee.crossfade >= 0 {
            voiceOnly = 0
        }
        let valid = window.valid
        var done = 0
        let crossfadeFrames = max(1, Int(Self.crossfadeSeconds * Double(clientRate)))
        while done < frames {
            let n = min(Self.scratchFrames, frames - done)
            voice.render(
                ring: UnsafePointer(window.storage), mask: window.mask, valid: valid, frames: n, into: scratch)
            if state.pointee.fadeLeft >= 0 { fadeOut(n, state: state) }
            let out = words + done * channels
            // Frames of this chunk the ring plays a part in.
            let fromRing = max(0, (done + n) - max(voiceOnly, done))
            let voiceFrames = n - fromRing
            for i in 0..<(voiceFrames * channels) { out[i] = word(scratch[i]) }
            if fromRing > 0 {
                let ringOut = out + voiceFrames * channels
                let wanted = fromRing * channels
                let got = unretainedRing._withUnsafeGuaranteedRef {
                    $0.read(into: UnsafeMutableBufferPointer(start: ringOut, count: wanted))
                }
                if got < wanted { (ringOut + got).update(repeating: 0, count: wanted - got) }
                if got > 0 {
                    rendered.store(rendered.load(ordering: .relaxed) + Int64(got / channels), ordering: .releasing)
                }
                for frame in 0..<fromRing {
                    let a = Float(min(state.pointee.crossfade + frame, crossfadeFrames)) / Float(crossfadeFrames)
                    for c in 0..<channels {
                        let i = frame * channels + c
                        ringOut[i] = word(sample(ringOut[i]) * a + scratch[voiceFrames * channels + i] * (1 - a))
                    }
                }
                state.pointee.crossfade += fromRing
            }
            done += n
        }
        tap.voicePositionBits.store(voice.position.bitPattern, ordering: .releasing)
        tap.voiceSpeedBits.store(voice.speed.bitPattern, ordering: .releasing)
        window.head.store(Int64(voice.position.rounded(.down)), ordering: .releasing)
        if state.pointee.crossfade >= crossfadeFrames {
            // The ring has the record again: this run is over for the render thread.
            state.pointee.crossfade = Int.max
            tap.handedOver.store(state.pointee.generation, ordering: .releasing)
        }
    }

    /// Drops `count` frames from the ring, counting them as rendered so positions stay right.
    private func skipRing(_ count: Int) {
        var left = count
        scratch.withMemoryRebound(to: UInt32.self, capacity: Self.scratchFrames * channels) { words in
            while left > 0 {
                let n = min(left, Self.scratchFrames)
                let got = unretainedRing._withUnsafeGuaranteedRef {
                    $0.read(into: UnsafeMutableBufferPointer(start: words, count: n * channels))
                }
                guard got > 0 else { break }
                rendered.store(rendered.load(ordering: .relaxed) + Int64(got / channels), ordering: .releasing)
                left -= got / channels
            }
        }
    }

    /// The let-go stopped record's fade, over the first `frames` of the scratch.
    private func fadeOut(_ frames: Int, state: UnsafeMutablePointer<ScrubRenderState>) {
        let total = max(1, Int(Self.fadeOutSeconds * Double(clientRate)))
        for frame in 0..<frames {
            let gain = Float(max(state.pointee.fadeLeft, 0)) / Float(total)
            for c in 0..<channels { scratch[frame * channels + c] *= gain }
            if state.pointee.fadeLeft > 0 { state.pointee.fadeLeft -= 1 }
        }
    }

    /// A Float32 sample as a client word.
    @inline(__always)
    private func word(_ x: Float) -> UInt32 {
        floatClient ? (x.isFinite ? x.bitPattern : 0) : int32Word(x)
    }

    /// A client word as a Float32 sample.
    @inline(__always)
    private func sample(_ w: UInt32) -> Float {
        floatClient ? Float(bitPattern: w) : int32Sample(w)
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

// MARK: - The Sound chain, render thread

// Free functions, not methods: a static method needs the class's metadata, and a closure holding a class reference
// retains it in a debug build. These take the runner unretained, and their closures capture only pointers and integers.

/// Whether the runner would leave a block untouched now (Pure, nothing in flight).
@inline(__always)
private func soundIsIdle(_ runner: Unmanaged<ChainRunner>) -> Bool {
    runner._withUnsafeGuaranteedRef { $0.isIdle }
}

/// Whether a scrub window is in place. It loads the pointer only, never what it points to, so it needs no
/// `ScrubTap.rendering` announcement: `renderScrub` announces itself before it loads the window again.
@inline(__always)
private func scrubWindowIsOpen(_ tap: Unmanaged<ScrubTap>) -> Bool {
    tap._withUnsafeGuaranteedRef {
        guard $0.window.load(ordering: .sequentiallyConsistent) != nil else {
            // A run retired without a handover leaves its voice behind; drop it here, as `renderScrub`'s guard did when
            // it ran on every call, so the next run's first callback can never play it. Plain render-owned values.
            $0.state.pointee.voice = nil
            return false
        }
        return true
    }
}

/// Runs the block in `buffer` through the chain, in place, after the ring or the scrub voice and before iOS (see "The
/// Sound chain"). In Pure the runner returns without touching a word.
private func runSound(
    _ runner: Unmanaged<ChainRunner>, on buffer: UnsafeMutableRawPointer, frames: Int, channels: Int,
    floatClient: Bool, scratch: UnsafeMutablePointer<Float>, scratchFrames: Int
) {
    let count = frames * channels
    if floatClient {
        // The words are Float32 bit patterns: the samples themselves.
        let samples = buffer.bindMemory(to: Float.self, capacity: count)
        runner._withUnsafeGuaranteedRef { $0.process(samples, frames: frames, channels: channels) }
        return
    }
    guard !soundIsIdle(runner) else { return }
    let words = buffer.bindMemory(to: UInt32.self, capacity: count)
    var done = 0
    while done < frames {
        let n = frames - done < scratchFrames ? frames - done : scratchFrames
        let block = words + done * channels
        let samples = n * channels
        var i = 0
        while i < samples {
            scratch[i] = int32Sample(block[i])
            i += 1
        }
        runner._withUnsafeGuaranteedRef { $0.process(scratch, frames: n, channels: channels) }
        // A sample the runner left alone keeps its word: a 32-bit word does not survive a Float32 round trip.
        i = 0
        while i < samples {
            if scratch[i].bitPattern != int32Sample(block[i]).bitPattern { block[i] = int32Word(scratch[i]) }
            i += 1
        }
        done += n
    }
}

/// A Float32 sample as an Int32 client's word, clipped to full scale.
@inline(__always)
private func int32Word(_ x: Float) -> UInt32 {
    guard x.isFinite else { return 0 }
    let clipped = min(max(Double(x), -1), 1 - 1 / 2_147_483_648)
    return UInt32(bitPattern: Int32((clipped * 2_147_483_648).rounded()))
}

/// An Int32 client's word as a Float32 sample.
@inline(__always)
private func int32Sample(_ w: UInt32) -> Float {
    Float(Double(Int32(bitPattern: w)) / 2_147_483_648)
}
