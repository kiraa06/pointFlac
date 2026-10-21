import Foundation
import PFCore
import PFTestSupport
import Synchronization
import Testing

@testable import PFAudio

/// A 440 Hz sine, 16-bit stereo at 44.1 kHz, twenty seconds long: smooth enough that a resampled read of it can be
/// checked for pitch (zero crossings), level and continuity.
private final class SineDecoder: PCMDecoding {
    static let rate = 44_100
    static let hz = 440.0
    static let amplitude = 16_000.0
    static let frames: Int64 = 20 * 44_100
    static let format = AudioFormat(sampleRate: rate, bitsPerSample: 16, channels: 2)
    static let item = QueueItem(
        id: "sine", url: URL(fileURLWithPath: "/dev/null"), title: "Sine", artist: "Test", album: "Test",
        format: format, totalFrames: frames)

    static func value(_ frame: Int64) -> Int32 {
        Int32((amplitude * sin(2 * .pi * hz * Double(frame) / Double(rate))).rounded())
    }

    var format: AudioFormat { Self.format }
    var totalFrames: Int64 { Self.frames }
    private var position: Int64 = 0

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        let n = Int(min(Int64(min(maxFrames, buffer.count / 2)), Self.frames - position))
        for i in 0..<n {
            let v = Self.value(position + Int64(i))
            buffer[2 * i] = v
            buffer[2 * i + 1] = v
        }
        position += Int64(n)
        return n
    }

    func seek(toFrame frame: Int64) throws {
        position = min(max(frame, 0), Self.frames)
    }
}

@MainActor
private final class ScrubRig {
    let output = FakeOutput()
    let player: Player
    private(set) var pulled = 0

    init(
        session: FakeSession = FakeSession(),
        makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding = { _ in SineDecoder() }
    ) {
        let output = output
        player = Player(
            session: session, makeOutput: { output },
            capabilities: OutputCapabilities(int32Passthrough: false), nowPlaying: SilentNowPlaying(),
            makeDecoder: makeDecoder)
    }

    /// Plays the part of the render thread for `frames` frames, in 512-frame calls, letting the player run between.
    /// Paced at four times real time: a real render thread asks at exactly real time, and the scrub filler, which has
    /// to stay ahead of the needle, gets the same head start relative to it (harsher, not easier, than on a device).
    func pull(_ frames: Int) async {
        var left = frames
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(10))
        let pace = Duration.seconds(512.0 / 44_100 / 4)
        while left > 0, ContinuousClock.now < deadline {
            let n = output.pull(frames: min(512, left))
            if n == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                left -= n
                pulled += n
                try? await Task.sleep(for: pace)
            }
        }
    }

    /// Pulls until `done()` holds.
    func pump(until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(10))
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            if output.pull(frames: 512) == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
        return true
    }

    /// Pulls until the scrub voice has taken over from the ring (its music decoded around the needle): under the
    /// thread sanitizer that can take a while, and measurements must start from it.
    func voiceTookOver() async -> Bool {
        guard let tap = player.pipeline?.scrubTap else { return false }
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(10))
        while tap.voiceStarted.load(ordering: .acquiring) != tap.generation.load(ordering: .acquiring) {
            guard ContinuousClock.now < deadline else { return false }
            // Paced, as a render thread would ask: unpaced, the ring would outrun the decoder for ever.
            await pull(512)
        }
        return true
    }

    /// Waits (pulling) for a settling let-go to finish.
    func settle(_ task: Task<Void, Never>) async -> Bool {
        var done = false
        Task { @MainActor in
            await task.value
            done = true
        }
        return await pump { done }
    }

    /// The left channel of the last `frames` frames captured.
    func lastLeft(_ frames: Int) -> [Float] {
        let captured = output.capturedFloat
        let count = min(frames, captured.count / 2)
        return (0..<count).map { captured[captured.count - 2 * (count - $0)] }
    }

    func startPlaying() async -> Bool {
        await player.play([SineDecoder.item], startingAt: 0)
        return await pump { player.status == .playing }
    }
}

@MainActor
private final class SilentNowPlaying: NowPlayingPublishing {
    var onCommand: ((RemoteCommand) -> Void)?
    func show(_ item: QueueItem, elapsed: Duration, playing: Bool) {}
    func clear() {}
}

private func rms(_ x: [Float]) -> Double {
    (x.map { Double($0) * Double($0) }.reduce(0, +) / Double(max(x.count, 1))).squareRoot()
}

/// The tone's frequency in `x`, from its rising zero crossings.
private func frequency(_ x: [Float], rate: Double = 44_100) -> Double {
    var crossings: [Int] = []
    for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 { crossings.append(i) }
    guard let first = crossings.first, let last = crossings.last, crossings.count > 2 else { return 0 }
    return Double(crossings.count - 1) * rate / Double(last - first)
}

/// The largest jump between neighbouring samples: a click shows up as one far above the tone's own slope.
private func largestStep(_ x: [Float]) -> Float {
    zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

private let fullLevel = SineDecoder.amplitude / 32_768 / 2.0.squareRoot()
/// The steepest a 440 Hz tone at this level gets between two samples at 44.1 kHz.
private let toneSlope = Float(
    2 * Double.pi * SineDecoder.hz / Double(SineDecoder.rate) * SineDecoder.amplitude / 32_768)

@Suite("Scrub window")
struct ScrubWindowTests {
    @Test("The filler decodes around the needle and follows it both ways")
    func fillerFollowsTheNeedle() async throws {
        let window = ScrubWindow(format: SineDecoder.format, totalFrames: SineDecoder.frames, at: 300_000)
        let filler = ScrubFiller(
            item: SineDecoder.item.playbackItem, window: window, makeDecoder: { _ in SineDecoder() })
        filler.start()
        defer { filler.stop() }
        let reach = Int64(ScrubFiller.reachSeconds * 44_100)
        func covers(_ range: Range<Int64>) async -> Bool {
            let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(5))
            while ContinuousClock.now < deadline {
                let valid = window.valid
                if valid.lowerBound <= range.lowerBound, valid.upperBound >= range.upperBound { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        #expect(await covers((300_000 - reach)..<(300_000 + reach)))
        // The music in the window is the track's, scaled to ±1.
        for frame: Int64 in [300_000 - 1_000, 300_000, 300_000 + 77_777] {
            let slot = window.storage + Int(frame & Int64(window.mask)) * 2
            #expect(abs(slot[0] - Float(SineDecoder.value(frame)) / 32_768) < 1e-6)
        }
        window.head.store(600_000, ordering: .releasing)
        #expect(await covers((600_000 - reach)..<(600_000 + reach)))
        window.head.store(100_000, ordering: .releasing)
        #expect(await covers(max(0, 100_000 - reach)..<(100_000 + reach)))
        let failed = filler.failed.load(ordering: .acquiring)
        #expect(!failed)
    }
}

@MainActor @Suite("Scrubbing", .serialized)
struct ScrubTests {
    @Test("A finger on a playing record brakes it to silence, and the strip says Scrubbing")
    func handOnAPlayingRecordStopsIt() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(8_820)
        rig.player.beginScrub()
        #expect(rig.player.signal.scrubbing)
        #expect(rig.player.signal.indicator == .scrubbing)
        #expect(await rig.voiceTookOver())
        await rig.pull(22_050)
        #expect(rms(rig.lastLeft(4_410)) < 1e-3)
        // The brake is a slowdown, not a cut: no click where the hand landed.
        let sinceTouch = rig.lastLeft(22_050)
        #expect(largestStep(sinceTouch) < toneSlope * 1.5)
    }

    @Test("Turning the record at normal speed plays the music at its pitch; twice as fast, an octave up")
    func pitchFollowsTheHand() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(4_410)
        rig.player.beginScrub()
        for speed in [1.0, 2.0] {
            var offset = speed == 1 ? 0.0 : 1.0
            for _ in 0..<40 {
                offset += speed * 512 / 44_100
                rig.player.scrub(offsetSeconds: offset, speed: speed)
                await rig.pull(512)
            }
            let tail = rig.lastLeft(8_192)
            #expect(abs(frequency(tail) - 440 * speed) < 440 * speed * 0.01)
            #expect(abs(rms(tail) - fullLevel) < fullLevel * 0.05)
        }
    }

    @Test("Turning it backwards plays it backwards, at pitch")
    func backwardsAtPitch() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(44_100)
        rig.player.beginScrub()
        var offset = 0.0
        for _ in 0..<40 {
            offset -= 512.0 / 44_100
            rig.player.scrub(offsetSeconds: offset, speed: -1)
            await rig.pull(512)
        }
        let tail = rig.lastLeft(8_192)
        #expect(abs(frequency(tail) - 440) < 440 * 0.01)
        #expect(abs(rms(tail) - fullLevel) < fullLevel * 0.05)
    }

    @Test("Let go of a playing record: it spins up and the pipeline takes over where the needle is, without a click")
    func letGoWhilePlayingHandsBackToThePipeline() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(4_410)
        rig.player.beginScrub()
        await rig.pull(8_820)
        let settled = rig.player.endScrub(spinUpSeconds: 0.05)
        var done = false
        Task { @MainActor in
            await settled.value
            done = true
        }
        #expect(await rig.pump { done })
        #expect(!rig.player.signal.scrubbing)
        #expect(!rig.player.isScrubbing)
        #expect(rig.player.status == .playing)
        await rig.pull(22_050)
        let after = rig.lastLeft(30_000)
        #expect(largestStep(after) < toneSlope * 1.5)
        #expect(abs(frequency(rig.lastLeft(8_192)) - 440) < 4.4)
        // Counting resumed from the handover: the position moves with what is played.
        let before = rig.player.pipeline?.position.frame ?? 0
        await rig.pull(4_410)
        let moved = (rig.player.pipeline?.position.frame ?? 0) - before
        #expect(abs(moved - 4_410) <= 512)
    }

    /// Render-polish brief: every seek fades in, but the let-go's hand-over seek must not. The render thread cross-fades
    /// from the voice into the ring's first frames there; faded in as well, they would dip the level by up to 2.5 dB.
    @Test("Let go of a record turning at normal speed: the hand-over keeps the level, one cross-fade and no fade-in")
    func handOverIsOneCrossFade() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(4_410)
        rig.player.beginScrub()
        #expect(await rig.voiceTookOver())
        // The hand turns the record at normal speed, so the voice plays at full level right up to the let-go.
        var offset = 0.0
        for _ in 0..<20 {
            offset += 512.0 / 44_100
            rig.player.scrub(offsetSeconds: offset, speed: 1)
            await rig.pull(512)
        }
        let letGo = rig.output.capturedFloat.count / 2
        #expect(await rig.settle(rig.player.endScrub(spinUpSeconds: 0.01)))
        #expect(!rig.player.isScrubbing && rig.player.status == .playing)
        await rig.pull(4_410)
        // The level in every two periods from the let-go on: the motor, the voice, the cross-fade, then the ring.
        let since = rig.lastLeft(rig.output.capturedFloat.count / 2 - letGo)
        let window = 200
        let quietest =
            stride(from: 0, to: since.count - window, by: 50).map { rms(Array(since[$0..<($0 + window)])) }
            .min() ?? 0
        #expect(quietest > fullLevel * 0.9, "the level fell to \(quietest / fullLevel) of the tone's")
        #expect(largestStep(since) < toneSlope * 1.5)
    }

    @Test("Scrub a paused record: it sounds while turned, then stays paused where the hand left it")
    func scrubWhilePaused() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(44_100)
        rig.player.pause()
        let paused = rig.player.position
        #expect(!rig.output.isStarted)
        rig.player.beginScrub()
        #expect(rig.player.status == .paused)
        #expect(await rig.pump { rig.output.isStarted })
        var offset = 0.0
        for _ in 0..<40 {
            offset += 512.0 / 44_100
            rig.player.scrub(offsetSeconds: offset, speed: 1)
            await rig.pull(512)
        }
        #expect(abs(frequency(rig.lastLeft(8_192)) - 440) < 4.4)
        let settled = rig.player.endScrub()
        var done = false
        Task { @MainActor in
            await settled.value
            done = true
        }
        #expect(await rig.pump { done })
        #expect(rig.player.status == .paused)
        #expect(!rig.output.isStarted)
        #expect(!rig.player.signal.scrubbing)
        let moved = (rig.player.position - paused) / .seconds(1)
        #expect(abs(moved - offset) < 0.001)
    }

    @Test("Touched again while settling, the record carries on from where the needle is")
    func retouchWhileSettling() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(4_410)
        rig.player.beginScrub()
        await rig.pull(4_410)
        rig.player.endScrub(spinUpSeconds: 0.5)
        await rig.pull(4_410)
        rig.player.beginScrub()
        #expect(rig.player.isScrubbing)
        #expect(await rig.voiceTookOver())
        await rig.pull(22_050)
        #expect(rms(rig.lastLeft(4_410)) < 1e-3)
        #expect(largestStep(rig.lastLeft(30_000)) < toneSlope * 1.5)
    }

    @Test("A paused record held still is silent: its pipeline's ring, at the old cue, is never heard")
    func pausedHoldIsSilent() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(44_100)
        rig.player.pause()
        let captured = rig.output.capturedFloat.count
        rig.player.beginScrub()
        #expect(await rig.pump { rig.output.isStarted })
        await rig.pull(13_230)
        #expect(await rig.settle(rig.player.endScrub()))
        let since = Array(rig.output.capturedFloat[captured...])
        #expect(!since.isEmpty)
        #expect(since.allSatisfy { $0 == 0 })
        #expect(rig.player.status == .paused && !rig.output.isStarted)
    }

    @Test("If the scrub's music cannot be decoded, the record plays on and letting go changes nothing")
    func voiceThatNeverStartsLeavesPlaybackAlone() async {
        // The scrub filler's decoder fails; the pipeline's works.
        let rig = ScrubRig(makeDecoder: { _ in
            if Thread.current.name == "pointFlac.scrub" { throw CocoaError(.fileReadCorruptFile) }
            return SineDecoder()
        })
        #expect(await rig.startPlaying())
        await rig.pull(44_100)
        rig.player.beginScrub()
        rig.player.scrub(offsetSeconds: 2, speed: 3)
        await rig.pull(8_820)
        let before = rig.player.pipeline?.position.frame ?? 0
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await rig.settle(rig.player.endScrub(spinUpSeconds: 0.05)))
        #expect(clock.now - start < .seconds(1))
        #expect(!rig.player.isScrubbing && !rig.player.signal.scrubbing)
        // No seek to a stale needle: the ring played on all along.
        await rig.pull(4_410)
        let after = rig.player.pipeline?.position.frame ?? 0
        #expect(abs(after - before - 4_410) <= 1_024)
        #expect(largestStep(rig.lastLeft(30_000)) < toneSlope * 1.5)
    }

    @Test("Pausing mid-scrub keeps the needle where the hand put it")
    func pauseMidScrubKeepsTheNeedle() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(44_100)
        rig.player.beginScrub()
        let anchor = rig.player.pipeline?.scrubTap.anchorFrame.load(ordering: .acquiring) ?? 0
        var offset = 0.0
        for _ in 0..<60 {
            offset += 512.0 / 44_100
            rig.player.scrub(offsetSeconds: offset, speed: 1)
            await rig.pull(512)
        }
        let needle = rig.player.pipeline?.scrubTap.voicePosition ?? 0
        rig.player.pause()
        #expect(!rig.player.isScrubbing && !rig.player.signal.scrubbing)
        #expect(rig.player.status == .paused)
        // Pause keeps the needle that was heard, which the hand moved by its offset from where it took hold (plus
        // the slip while the needle's music decoded: milliseconds on a device, more under the thread sanitizer).
        let paused = Double(rig.player.position / .seconds(1)) * 44_100
        #expect(abs(paused - needle) < 2)
        #expect(abs(paused - (Double(anchor) + offset * 44_100)) < 0.1 * 44_100)
    }

    @Test("A seek while a paused record is held wins: the scrub ends and the cue is the seek's")
    func seekDuringPausedScrubWins() async {
        let rig = ScrubRig()
        #expect(await rig.startPlaying())
        await rig.pull(44_100)
        rig.player.pause()
        rig.player.beginScrub()
        #expect(await rig.pump { rig.output.isStarted })
        rig.player.scrub(offsetSeconds: 0.5, speed: 1)
        await rig.pull(2_048)
        await rig.player.seek(to: .seconds(5))
        #expect(!rig.player.isScrubbing && !rig.output.isStarted)
        #expect(await rig.settle(rig.player.endScrub()))
        #expect(rig.player.position == .seconds(5))
        #expect(rig.player.status == .paused)
    }

    @Test("Resampled output (48 kHz hardware, 44.1 kHz file): the hand's speed still sets the pitch")
    func resampledPitch() async {
        let rig = ScrubRig(session: FakeSession(rateResponse: { _ in 48_000 }))
        #expect(await rig.startPlaying())
        #expect(rig.output.plans.last?.clientSampleRate == 48_000)
        await rig.pull(48_000)
        rig.player.beginScrub()
        var offset = 0.0
        for _ in 0..<60 {
            offset += 512.0 / 48_000
            rig.player.scrub(offsetSeconds: offset, speed: 1)
            await rig.pull(512)
        }
        let tail = rig.lastLeft(8_192)
        #expect(abs(frequency(tail, rate: 48_000) - 440) < 4.4)
        #expect(abs(rms(tail) - fullLevel) < fullLevel * 0.05)
        #expect(await rig.settle(rig.player.endScrub(spinUpSeconds: 0.05)))
        await rig.pull(9_600)
        #expect(largestStep(rig.lastLeft(40_000)) < toneSlope * 1.5)
    }
}
