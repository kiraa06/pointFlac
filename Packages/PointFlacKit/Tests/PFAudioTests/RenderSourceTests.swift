import Foundation
import PFCore
import Testing

@testable import PFAudio

/// One render call into a stereo buffer of `frames` frames; returns the real frames.
private func render(_ source: RenderSource, frames: Int) -> Int {
    var buffer = [UInt32](repeating: 0xAAAA_AAAA, count: frames * 2)
    return buffer.withUnsafeMutableBytes { source.render(into: $0.baseAddress!, frames: frames) }
}

private func write(_ source: RenderSource, frames: Int) {
    let words = [UInt32](repeating: 0x3F00_0000, count: frames * 2)
    #expect(words.withUnsafeBufferPointer { source.write($0) } == words.count)
}

/// Final review (minor): underruns were uncounted. `underrunFrames` counts the frames of silence `render` had to fill
/// because the ring ran dry mid-stream, and nothing deliberate: not the start-up before the first real frame, not a
/// flush or a seek hold, not the end of the stream once the producer has said so.
@Suite struct RenderSourceTests {
    @Test func countsUnderrunsOnlyMidStream() {
        let source = RenderSource(channels: 2, capacityFrames: 64, renderedFrames: 0, inheritingHoldsFrom: nil)
        // Start-up: nothing written yet, then a first callback that is only partly real.
        #expect(render(source, frames: 16) == 0)
        write(source, frames: 10)
        #expect(render(source, frames: 16) == 10)
        #expect(source.underrunFrames == 0)

        // Mid-stream: the ring runs dry, wholly and then partly.
        #expect(render(source, frames: 16) == 0)
        #expect(source.underrunFrames == 16)
        write(source, frames: 4)
        #expect(render(source, frames: 16) == 4)
        #expect(source.underrunFrames == 28)

        // A seek hold and a flush are silence on purpose.
        write(source, frames: 8)
        source.holdForSeek()
        #expect(render(source, frames: 16) == 0)
        let flush = source.requestFlush()
        #expect(render(source, frames: 16) == 0)
        #expect(source.isFlushAcknowledged(flush))
        source.releaseSeekHolds(through: source.seekHoldTicket)
        #expect(source.underrunFrames == 28)

        // The end of the stream: the producer said nothing more is coming.
        write(source, frames: 2)
        source.markEndOfStream()
        #expect(render(source, frames: 16) == 2)
        #expect(render(source, frames: 16) == 0)
        #expect(source.underrunFrames == 28)
        // Writing again (a seek after the end) resumes counting.
        write(source, frames: 2)
        #expect(render(source, frames: 16) == 2)
        #expect(source.underrunFrames == 28 + 14)
        // The 8 frames the flush dropped were never rendered.
        #expect(source.renderedFrames == 10 + 4 + 2 + 2)

        // A replacement source carries the count on, like `renderedFrames`.
        let next = RenderSource(channels: 2, capacityFrames: 64, renderedFrames: 18, inheritingHoldsFrom: source)
        #expect(next.underrunFrames == 42)
        #expect(render(next, frames: 8) == 0)
        #expect(next.underrunFrames == 42, "the replacement's start-up counted")
    }
}

// MARK: - A seek's fade-out

/// The client rate of the fade tests: 6 ms is 288 frames.
private let fadeRate = 48_000

/// The ring's word for (frame, channel). A Float32 client's is a sample within ±0.5; an Int32 client's uses every bit,
/// as a 32-bit source's does, so a Float32 round trip would show.
private func word(_ frame: Int, _ channel: Int, floatClient: Bool) -> UInt32 {
    let hash = UInt32(truncatingIfNeeded: (frame &* 2_654_435_761) &+ channel &* 40_503)
    guard floatClient else { return hash }
    return (Float(Int32(bitPattern: hash) >> 8) * 0x1p-24).bitPattern
}

/// `w` scaled by `gain` as the fade-out scales it: Float32 in Float32; Int32 in Double, rounded half away from zero.
private func scaled(_ w: UInt32, by gain: Float, floatClient: Bool) -> UInt32 {
    guard floatClient else { return UInt32(bitPattern: Int32((Double(Int32(bitPattern: w)) * Double(gain)).rounded())) }
    return (Float(bitPattern: w) * gain).bitPattern
}

/// A stereo source at `fadeRate` whose ring holds frames `0..<frames` of `word`.
private func playing(floatClient: Bool, frames: Int, scrub: ScrubTap? = nil) -> RenderSource {
    let source = RenderSource(
        channels: 2, capacityFrames: 1 << 15, renderedFrames: 0, inheritingHoldsFrom: nil, clientRate: fadeRate,
        floatClient: floatClient, scrub: scrub)
    feed(source, from: 0, count: frames, floatClient: floatClient)
    return source
}

private func feed(_ source: RenderSource, from frame: Int, count: Int, floatClient: Bool) {
    let words = (0..<(count * 2)).map { word(frame + $0 / 2, $0 % 2, floatClient: floatClient) }
    #expect(words.withUnsafeBufferPointer { source.write($0) } == words.count)
}

/// One render call of `frames` frames: the real frames, and every word of the block, silence included.
private func block(_ source: RenderSource, frames: Int) -> (real: Int, words: [UInt32]) {
    var buffer = [UInt32](repeating: 0xAAAA_AAAA, count: frames * 2)
    let real = buffer.withUnsafeMutableBytes { source.render(into: $0.baseAddress!, frames: frames) }
    return (real, buffer)
}

/// The words of `frames` frames of the ring from `frame`, faded out from fade frame `k` on.
private func faded(from frame: Int, fadeFrame k: Int, frames: Int, floatClient: Bool) -> [UInt32] {
    let fade = RenderSource.fadeFrames(atRate: fadeRate)
    return (0..<(frames * 2)).map { i in
        let gain = RenderSource.seekFadeGain(k + i / 2, of: fade)
        return scaled(word(frame + i / 2, i % 2, floatClient: floatClient), by: gain, floatClient: floatClient)
    }
}

/// A seek's fade-out (render-polish brief, part 1): a hold or a flush that finds the ring's music playing fades its
/// next 6 ms out on a raised cosine, then holds silence as before. The fade's frames are the old position's on their
/// way out: they never advance `renderedFrames`, so the new position starts after the hold, exactly. The flush waits
/// for the fade, so it never drops what the fade plays.
@Suite struct SeekFadeOutTests {
    @Test func theFadeIsARaisedCosineOverSixMilliseconds() {
        let fade = RenderSource.fadeFrames(atRate: fadeRate)
        #expect(fade == 288)
        #expect(RenderSource.fadeFrames(atRate: 44_100) == 265)
        #expect(RenderSource.fadeFrames(atRate: 384_000) == 2_304)
        #expect(RenderSource.seekFadeGain(0, of: fade) == 1, "the fade starts at the music's own level")
        for k in 1..<fade {
            let gain = RenderSource.seekFadeGain(k, of: fade)
            #expect(gain < RenderSource.seekFadeGain(k - 1, of: fade), "frame \(k): falling")
            let expected = 0.5 + 0.5 * cos(Double.pi * Double(k) / Double(fade))
            #expect(abs(Double(gain) - expected) < 1e-7, "frame \(k): \(gain) ≠ \(expected)")
        }
        // Its last frame is all but silent: the step into the hold's silence is under 30 ppm of the level.
        #expect(RenderSource.seekFadeGain(fade - 1, of: fade) < 3e-5)
    }

    @Test(arguments: [true, false])
    func aSeekFadesOutWhatWasPlaying(floatClient: Bool) {
        let fade = RenderSource.fadeFrames(atRate: fadeRate)
        let source = playing(floatClient: floatClient, frames: 4096)
        let before = block(source, frames: 512)
        #expect(before.real == 512)
        #expect(before.words == (0..<1024).map { word($0 / 2, $0 % 2, floatClient: floatClient) })

        source.holdForSeek()
        // Calls of 100 frames: the ring's next 288 frames fade out over three of them, then the hold is silent.
        let first = block(source, frames: 100)
        #expect(first.real == 100)
        #expect(first.words == faded(from: 512, fadeFrame: 0, frames: 100, floatClient: floatClient))
        // The decode thread's flush, while the fade plays: it is acknowledged once the fade is done, not before.
        let flush = source.requestFlush()
        let second = block(source, frames: 100)
        #expect(second.real == 100)
        #expect(second.words == faded(from: 612, fadeFrame: 100, frames: 100, floatClient: floatClient))
        #expect(!source.isFlushAcknowledged(flush), "the flush must not drop the fade's audio")
        let third = block(source, frames: 100)
        #expect(third.real == fade - 200)
        let tail = faded(from: 712, fadeFrame: 200, frames: fade - 200, floatClient: floatClient)
        #expect(third.words == tail + [UInt32](repeating: 0, count: 2 * (300 - fade)))
        #expect(source.isFlushAcknowledged(flush))
        // The hold: silence, and nothing of the ring is touched.
        let held = block(source, frames: 100)
        #expect(held.real == 0 && held.words.allSatisfy { $0 == 0 })
        // The fade's frames belong to the old position: the rendered count stood still from the hold on.
        #expect(source.renderedFrames == 512)

        // The decode thread refills at the new position and releases the hold: it plays from its first frame, exactly.
        feed(source, from: 20_000, count: 1024, floatClient: floatClient)
        source.releaseSeekHolds(through: source.seekHoldTicket)
        let after = block(source, frames: 512)
        #expect(after.real == 512)
        #expect(after.words == (0..<1024).map { word(20_000 + $0 / 2, $0 % 2, floatClient: floatClient) })
        #expect(source.renderedFrames == 512 + 512)
        #expect(source.underrunFrames == 0)
    }

    /// With nothing playing there is nothing to fade: at the start, and after the ring ran dry, the hold is silent at
    /// once and the flush is acknowledged in the same call, as before.
    @Test func withNothingPlayingTheHoldIsSilentAtOnce() {
        let source = playing(floatClient: true, frames: 1024)
        source.holdForSeek()
        let startUp = block(source, frames: 256)
        #expect(startUp.real == 0 && startUp.words.allSatisfy { $0 == 0 }, "nothing has played yet")
        let flush = source.requestFlush()
        #expect(block(source, frames: 256).real == 0)
        #expect(source.isFlushAcknowledged(flush))
        source.releaseSeekHolds(through: source.seekHoldTicket)

        // The ring runs dry mid-block: the block ends in silence, so the next seek has nothing to fade either.
        feed(source, from: 0, count: 100, floatClient: true)
        #expect(block(source, frames: 256).real == 100)
        feed(source, from: 100, count: 1024, floatClient: true)
        source.holdForSeek()
        let held = block(source, frames: 256)
        #expect(held.real == 0 && held.words.allSatisfy { $0 == 0 })
        source.releaseSeekHolds(through: source.seekHoldTicket)
    }

    /// The fade plays only what the ring holds: if it runs dry, the fade ends there and the flush is acknowledged.
    @Test func theFadeEndsWhereTheRingRunsDry() {
        let source = playing(floatClient: true, frames: 512 + 100)
        #expect(block(source, frames: 512).real == 512)
        source.holdForSeek()
        let flush = source.requestFlush()
        let short = block(source, frames: 512)
        #expect(short.real == 100)
        let silence = [UInt32](repeating: 0, count: 2 * 412)
        #expect(short.words == faded(from: 512, fadeFrame: 0, frames: 100, floatClient: true) + silence)
        #expect(source.isFlushAcknowledged(flush))
        #expect(block(source, frames: 512).real == 0)
        #expect(source.renderedFrames == 512)
    }

    /// A newer seek while the fade plays neither restarts it nor plays it twice: one fade per gap.
    @Test func aSecondSeekDuringTheFadeKeepsOneFade() {
        let fade = RenderSource.fadeFrames(atRate: fadeRate)
        let source = playing(floatClient: true, frames: 4096)
        #expect(block(source, frames: 512).real == 512)
        source.holdForSeek()
        #expect(block(source, frames: 100).real == 100)
        source.holdForSeek()
        let rest = block(source, frames: 512)
        #expect(rest.real == fade - 100)
        #expect(
            Array(rest.words.prefix(2 * (fade - 100)))
                == faded(from: 612, fadeFrame: 100, frames: fade - 100, floatClient: true))
        // Served together, by the decode thread's ticket for both: the next seek fades out again.
        _ = source.requestFlush()
        #expect(block(source, frames: 512).real == 0)
        feed(source, from: 30_000, count: 2048, floatClient: true)
        source.releaseSeekHolds(through: source.seekHoldTicket)
        #expect(block(source, frames: 512).real == 512)
        source.holdForSeek()
        let again = block(source, frames: 512)
        #expect(again.real == fade)
        #expect(
            Array(again.words.prefix(2 * fade)) == faded(from: 30_512, fadeFrame: 0, frames: fade, floatClient: true))
    }

    /// A fade the voice cut short stays over: when the hand lets go of a paused record (the window retired, no
    /// hand-over) with the hold still in force, the ring's old audio is not faded back in, and the hold is silent.
    @Test func aFadeTheVoiceCutShortDoesNotResume() {
        let tap = ScrubTap()
        let window = ScrubWindow(
            format: AudioFormat(sampleRate: fadeRate, bitsPerSample: 24, channels: 2), totalFrames: 480_000, at: 0)
        window.validStart.store(0, ordering: .releasing)
        window.validEnd.store(0, ordering: .releasing)
        let source = playing(floatClient: true, frames: 16_384, scrub: tap)
        #expect(block(source, frames: 512).real == 512)
        source.holdForSeek()
        #expect(block(source, frames: 100).real == 100)
        // A paused record's hand: its silence replaces the ring.
        tap.begin(window: window, anchorFrame: 0, anchorRendered: 0, startSpeed: 0, ringAllowed: false)
        let paused = block(source, frames: 512)
        #expect(paused.real == 512 && paused.words.allSatisfy { $0 == 0 })
        tap.retireWindow()
        let held = block(source, frames: 512)
        #expect(held.real == 0 && held.words.allSatisfy { $0 == 0 }, "the cut-short fade came back")
    }

    /// Scrubbing has its own hand-overs, so a seek under the hand never fades or waits: the ring is not being heard.
    /// The voice takes over from a fade in progress (which is then over for good), a flush is acknowledged at once,
    /// and once the record is back on the ring, the next seek fades out what it plays.
    @Test func aSeekUnderTheHandNeitherFadesNorWaits() {
        let fade = RenderSource.fadeFrames(atRate: fadeRate)
        let tap = ScrubTap()
        let window = ScrubWindow(
            format: AudioFormat(sampleRate: fadeRate, bitsPerSample: 24, channels: 2), totalFrames: 480_000, at: 0)
        for frame in 0..<200_000 {
            let slot = window.storage + (frame & window.mask) * 2
            slot[0] = Float(0.25 * sin(2 * Double.pi * 1_000 * Double(frame) / Double(fadeRate)))
            slot[1] = slot[0]
        }
        window.validStart.store(0, ordering: .releasing)
        window.validEnd.store(200_000, ordering: .releasing)
        let source = playing(floatClient: true, frames: 16_384, scrub: tap)
        #expect(block(source, frames: 512).real == 512)

        // A seek's fade is under way when the hand lands on the playing record: the voice takes over at once.
        source.holdForSeek()
        #expect(block(source, frames: 100).real == 100)
        tap.begin(window: window, anchorFrame: 512, anchorRendered: 512, startSpeed: 1, ringAllowed: true)
        let generation = tap.generation.load(ordering: .acquiring)
        let voice = block(source, frames: 512)
        #expect(voice.real == 512 && tap.voiceStarted.load(ordering: .acquiring) == generation)
        // Under the hand a flush is acknowledged in the next call, with nothing of the ring played or counted.
        let flush = source.requestFlush()
        tap.setHand(offsetFrames: 512, speed: 1)
        #expect(block(source, frames: 512).real == 512)
        #expect(source.isFlushAcknowledged(flush))
        #expect(source.renderedFrames == 512)

        // The let-go: the motor, then the ring lined up ahead of the needle (the hand-over's seek), and the cross-fade.
        tap.motorSecondsBits.store(0.01.bitPattern, ordering: .relaxed)
        tap.phase.store(ScrubTap.Phase.motor.rawValue, ordering: .releasing)
        for _ in 0..<4 { _ = block(source, frames: 512) }
        let target = Int(tap.voicePosition.rounded(.down)) + 4_800
        feed(source, from: target, count: 16_384, floatClient: true)
        source.releaseSeekHolds(through: source.seekHoldTicket)
        tap.handoverFrame.store(Int64(target), ordering: .releasing)
        var calls = 0
        while tap.handedOver.load(ordering: .acquiring) != generation, calls < 100 {
            _ = block(source, frames: 512)
            calls += 1
        }
        #expect(tap.handedOver.load(ordering: .acquiring) == generation, "the ring took over")
        // Back on the ring (the window stays open until the player retires it): a seek fades out what plays.
        let ringPlays = block(source, frames: 512)
        #expect(ringPlays.real == 512)
        // The ring's words tell which frame it has reached.
        let reached = (target..<(target + 16_384)).first { frame in
            (0..<8).allSatisfy { ringPlays.words[$0] == word(frame + $0 / 2, $0 % 2, floatClient: true) }
        }
        guard let reached else {
            Issue.record("the ring's frame was not found")
            return
        }
        #expect(ringPlays.words == (0..<1024).map { word(reached + $0 / 2, $0 % 2, floatClient: true) })
        source.holdForSeek()
        let out = block(source, frames: 512)
        #expect(out.real == fade, "the ring is heard again, so it fades out")
        #expect(
            Array(out.words.prefix(2 * fade))
                == faded(from: reached + 512, fadeFrame: 0, frames: fade, floatClient: true))
        tap.retireWindow()
    }
}
