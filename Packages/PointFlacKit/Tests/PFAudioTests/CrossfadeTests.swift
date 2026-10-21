import Foundation
import PFCore
import PFDSP
import PFFlac
import PFTestSupport
import Synchronization
import Testing

@testable import PFAudio

// MARK: - Sources

/// −6.02 dB: exactly half (20·log10 0.5).
private let halfDb = 20 * log10(0.5)

/// A synthetic 24-bit stereo source: sample (frame, channel) is `value`, `frames` long at `rate`.
private struct Signal: Sendable {
    var rate = 48_000
    var frames: Int64
    var value: @Sendable (Int64, Int) -> Int32

    var format: AudioFormat { AudioFormat(sampleRate: rate, bitsPerSample: 24, channels: 2) }

    /// Sample (frame, channel) as the Float32 client receives it at `gainDb`, by the pipeline's own arithmetic, so a
    /// capture compares to the bit: v / 2^23, or the product in Double with the gain folded into the scale.
    func float(_ frame: Int64, channel: Int, gainDb: Double = 0) -> Float {
        let v = value(frame, channel)
        if gainDb == 0 { return Float(v) * 0x1p-23 }
        return Float(Double(v) * (0x1p-23 * pow(10, gainDb / 20)))
    }
}

/// A sine at a quarter of full scale (−12 dBFS), the right channel half a radian behind the left.
private func tone(_ hz: Double, seconds: Double, rate: Int = 48_000) -> Signal {
    Signal(rate: rate, frames: Int64(seconds * Double(rate))) { frame, channel in
        Int32((0x20_0000 * sin(2 * .pi * hz * Double(frame) / Double(rate) + 0.5 * Double(channel))).rounded())
    }
}

/// SplitMix64, for noise whose every sample is independent of every other, and of another seed's.
private func splitMix(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// White noise within ±1/8 of full scale (about −21 dBFS RMS), different for each seed.
private func noise(_ seed: UInt64, seconds: Double, rate: Int = 48_000) -> Signal {
    Signal(rate: rate, frames: Int64(seconds * Double(rate))) { frame, channel in
        let bits = splitMix((seed << 40) &+ UInt64(frame) &* 2 &+ UInt64(channel)) >> 43
        return Int32(bits) - 0x10_0000
    }
}

private final class SignalDecoder: PCMDecoding {
    let signal: Signal
    /// Reads past this frame throw: a file deleted or evicted mid-playback.
    let failAfter: Int64?
    /// The stream really ends here, though `totalFrames` says `signal.frames`: a length overstated in STREAMINFO.
    let endsAt: Int64?
    private var position: Int64 = 0

    init(_ signal: Signal, failAfter: Int64? = nil, endsAt: Int64? = nil) {
        self.signal = signal
        self.failAfter = failAfter
        self.endsAt = endsAt
    }

    var format: AudioFormat { signal.format }
    var totalFrames: Int64 { signal.frames }

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        let end = min(endsAt ?? signal.frames, failAfter ?? signal.frames)
        if position >= end, failAfter != nil { throw FlacDecodeError.ioError }
        let n = Int(min(Int64(min(maxFrames, buffer.count / 2)), end - position))
        for i in 0..<n {
            for c in 0..<2 { buffer[2 * i + c] = signal.value(position + Int64(i), c) }
        }
        position += Int64(n)
        return n
    }

    func seek(toFrame frame: Int64) throws {
        position = min(max(frame, 0), signal.frames)
    }
}

/// Opens the signal named by the item's ID, else the item's file. An ID in `failing` fails after that many frames;
/// one in `short` ends after that many, its length overstated.
private func decoders(
    _ signals: [String: Signal], failing: [String: Int64] = [:], short: [String: Int64] = [:]
) -> @Sendable (PlaybackItem) throws -> PCMDecoding {
    { item in
        if let signal = signals[item.id] {
            return SignalDecoder(signal, failAfter: failing[item.id], endsAt: short[item.id])
        }
        return try FlacDecoder(url: item.url)
    }
}

// MARK: - Expected captures

/// Source frames `range` of `signal` as the client receives them at `gainDb`, interleaved.
private func plain(_ signal: Signal, _ range: Range<Int64>, gainDb: Double = 0) -> [Float] {
    var out: [Float] = []
    out.reserveCapacity(range.count * 2)
    for n in range {
        for c in 0..<2 { out.append(signal.float(n, channel: c, gainDb: gainDb)) }
    }
    return out
}

/// The first `frames` frames of an overlap `overlap` frames long (all of it by default) of `a` from `aFrom` fading out
/// under `b` from `bFrom` fading in, each at its own gain: the pipeline's mix, `cos(πt/2)·a + sin(πt/2)·b` in Double,
/// rounded once to Float32.
private func mixed(
    _ a: Signal, from aFrom: Int64, gainDb aGain: Double = 0, _ b: Signal, from bFrom: Int64, gainDb bGain: Double = 0,
    frames: Int, of overlap: Int? = nil
) -> [Float] {
    var out: [Float] = []
    out.reserveCapacity(frames * 2)
    for k in 0..<frames {
        let w = PlaybackPipeline.crossfadeWeights(frame: k, of: overlap ?? frames)
        for c in 0..<2 {
            let x = Double(a.float(aFrom + Int64(k), channel: c, gainDb: aGain))
            let y = Double(b.float(bFrom + Int64(k), channel: c, gainDb: bGain))
            out.append(Float(x * w.outgoing + y * w.incoming))
        }
    }
    return out
}

/// A seek's (or a re-cue's) fade-out and fade-in at 48 kHz: 6 ms, 288 frames. Not the crossfade's own length.
private let seekFade = RenderSource.fadeFrames(atRate: 48_000)

/// What a seek puts in a stereo capture at 48 kHz after the frames pulled before it: the first `seekFade` frames of
/// `old` (what was playing) faded out on the raised cosine (`RenderSource.seekFadeGain`), then `new`, its first
/// `seekFade` frames faded in linearly. Both are interleaved samples from those two points on.
private func seekDip(old: some Collection<Float>, new: some Collection<Float>) -> [Float] {
    var out: [Float] = []
    for (i, x) in old.prefix(2 * seekFade).enumerated() {
        out.append(x * RenderSource.seekFadeGain(i / 2, of: seekFade))
    }
    for (i, x) in new.enumerated() {
        out.append(i / 2 < seekFade ? x * (Float(i / 2) / Float(seekFade)) : x)
    }
    return out
}

/// Waits without pulling while the decode thread runs ahead, so the ring holds the 6 ms a seek's fade-out plays.
private func letTheRingFill() async {
    try? await Task.sleep(for: .milliseconds(50))
}

/// Native-range samples as the Float32 client receives them: v / 2^(b−1).
private func floats(_ samples: some Sequence<Int32>, bits: Int) -> [Float] {
    let scale = Float(1 << (bits - 1))
    return samples.map { Float($0) / scale }
}

/// Nil when the arrays are identical; otherwise where they first differ. Floats compare by bit pattern.
private func mismatch(_ got: [Float], _ want: [Float]) -> String? {
    guard got.count == want.count else { return "count \(got.count) ≠ \(want.count)" }
    guard let i = got.indices.first(where: { got[$0].bitPattern != want[$0].bitPattern }) else { return nil }
    return "first difference at sample \(i) (frame \(i / 2)): \(got[i]) ≠ \(want[i])"
}

private func mismatch(_ got: [Int32], _ want: [Int32]) -> String? {
    guard got.count == want.count else { return "count \(got.count) ≠ \(want.count)" }
    guard let i = got.indices.first(where: { got[$0] != want[$0] }) else { return nil }
    return "first difference at sample \(i): \(got[i]) ≠ \(want[i])"
}

private func rmsDb(_ x: ArraySlice<Float>) -> Double {
    let power = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))
    return 10 * log10(power)
}

private func floatPlan(_ rate: Int, resample: RateChange? = nil) -> OutputPlan {
    OutputPlan(client: .float32, clientSampleRate: rate, resample: resample, reduceTo24: false)
}

/// The resampler run once over the whole input.
private func oneShotResample(_ input: [Float], from: Int, to: Int) throws -> [Float] {
    let converter = try SampleRateConverter(inputRate: from, outputRate: to, channels: 2)
    var out: [Float] = []
    input.withUnsafeBufferPointer { _ = converter.process($0, frames: input.count / 2, into: &out) }
    _ = converter.flush(into: &out)
    return out
}

private func fixtureItem(_ name: String, id: String? = nil) -> PlaybackItem {
    let f = Fixtures.named(name)
    return PlaybackItem(
        id: id ?? name, url: Fixtures.url(f),
        format: AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels),
        totalFrames: f.frames)
}

private func fixtureStarted(_ index: Int, _ name: String) -> PipelineEvent {
    let f = Fixtures.named(name)
    return .trackStarted(
        index, AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels),
        totalFrames: f.frames)
}

private func always(_ seconds: Double) -> CrossfadeSettings {
    CrossfadeSettings(mode: .always, seconds: seconds)
}

/// Pure off, nothing on but `crossfade` (and ReplayGain in `replayGain`): the Sound chain is the limiter alone.
private func sound(_ crossfade: CrossfadeSettings, replayGain: ReplayGainMode = .off) -> SoundSettings {
    var s = SoundSettings()
    s.pure = false
    s.crossfade = crossfade
    s.replayGain.mode = replayGain
    return s
}

// MARK: - Rigs

private final class EventLog: Sendable {
    private let storage = Mutex<[PipelineEvent]>([])

    var events: [PipelineEvent] { storage.withLock { $0 } }

    func append(_ event: PipelineEvent) {
        storage.withLock { $0.append(event) }
    }

    func contains(_ event: PipelineEvent) -> Bool {
        events.contains(event)
    }
}

/// Plays the render thread's part on a `FakeOutput`, in calls of up to `chunk` frames.
@MainActor
private final class Puller {
    let output: FakeOutput
    private(set) var pulled = 0

    init(_ output: FakeOutput) {
        self.output = output
    }

    @discardableResult
    func pullOnce(_ frames: Int = 2048) -> Int {
        let n = output.pull(frames: frames)
        pulled += n
        return n
    }

    /// Pulls until exactly `target` real frames have been pulled in all.
    func pull(upTo target: Int) async -> Bool {
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(20))
        while pulled < target {
            guard ContinuousClock.now < deadline else { return false }
            if pullOnce(min(2048, target - pulled)) == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
        return true
    }

    /// Pulls until `done()` holds.
    func pump(until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(20))
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            if pullOnce() == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
        return true
    }

    /// Pulls `frames` frames in 512-frame calls at four times real time, as `ScrubTests` does, so a scrub filler keeps
    /// ahead of the needle.
    func paced(_ frames: Int) async {
        var left = frames
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(20))
        let pace = Duration.seconds(512.0 / 48_000 / 4)
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

    /// Waits, without pulling, until `condition` holds.
    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

/// A bare pipeline on a `FakeOutput`, with no Sound chain: what the decode thread writes is what is captured.
@MainActor
private final class PipelineRig {
    let output = FakeOutput()
    let pipeline: PlaybackPipeline
    let puller: Puller
    let log = EventLog()
    let signals: [String: Signal]
    private let collector: Task<Void, Never>

    init(
        _ signals: [String: Signal] = [:], hardwareRate: @escaping @Sendable (Int) -> Int = { $0 },
        int32Passthrough: Bool = false, failing: [String: Int64] = [:], short: [String: Int64] = [:]
    ) {
        self.signals = signals
        puller = Puller(output)
        let pipeline = PlaybackPipeline(
            output: output, capabilities: OutputCapabilities(int32Passthrough: int32Passthrough),
            negotiateRate: { hardwareRate($0) }, makeDecoder: decoders(signals, failing: failing, short: short))
        self.pipeline = pipeline
        let log = log
        collector = Task {
            for await event in pipeline.events { log.append(event) }
        }
    }

    deinit {
        pipeline.stop()
        collector.cancel()
    }

    func item(_ id: String, gainDb: Double = 0) -> PlaybackItem {
        let signal = signals[id]!
        return PlaybackItem(
            id: id, url: URL(fileURLWithPath: "/dev/null"), format: signal.format, totalFrames: signal.frames,
            gainDb: gainDb)
    }

    func started(_ index: Int, _ id: String) -> PipelineEvent {
        .trackStarted(index, signals[id]!.format, totalFrames: signals[id]!.frames)
    }

    func playToEnd() async -> Bool {
        await puller.pump { log.contains(.queueEnded) }
    }

    /// Waits, without pulling, until `event` has been emitted.
    func heard(_ event: PipelineEvent) async -> Bool {
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.milliseconds(50))
        while !log.contains(event) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    var captured: [Float] { output.capturedFloat }
}

@MainActor
private final class QuietNowPlaying: NowPlayingPublishing {
    var onCommand: ((RemoteCommand) -> Void)?
    func show(_ item: QueueItem, elapsed: Duration, playing: Bool) {}
    func clear() {}
}

/// A player on a `FakeOutput`.
@MainActor
private final class PlayerRig {
    let output = FakeOutput()
    let player: Player
    let puller: Puller
    let signals: [String: Signal]

    init(_ signals: [String: Signal] = [:]) {
        self.signals = signals
        let output = output
        puller = Puller(output)
        player = Player(
            session: FakeSession(), makeOutput: { output }, capabilities: OutputCapabilities(int32Passthrough: false),
            nowPlaying: QuietNowPlaying(), makeDecoder: decoders(signals))
    }

    func item(_ id: String, trackGainDb: Double? = nil) -> QueueItem {
        let signal = signals[id]!
        return QueueItem(
            id: id, url: URL(fileURLWithPath: "/dev/null"), title: id, artist: "", album: "", format: signal.format,
            totalFrames: signal.frames, loudness: trackGainDb.map { TrackLoudness(trackGainDb: $0) })
    }

    func fixture(_ name: String, id: String? = nil) -> QueueItem {
        let f = Fixtures.named(name)
        return QueueItem(
            id: id ?? name, url: Fixtures.url(f), title: name, artist: "", album: "",
            format: AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels),
            totalFrames: f.frames)
    }

    /// Waits until every call queued on the player's engine has run, a switch's re-cue among them.
    func drained() async {
        await player.currentEngine?.enqueue { _ in }.value
    }
}

// MARK: - Tests

/// Crossfade (Plan 4 Task 16, ruling R4-4): at a boundary between two items of the same output plan, the decode
/// thread overlaps the end of one with the start of the next, `cos(πt/2)·a + sin(πt/2)·b`, each at its own
/// ReplayGain. Always overlaps every such boundary, Between albums only those `append` marked. Off and Pure keep
/// every boundary gapless and bit-exact.
///
/// Serialized: every test runs a decode thread and a pull loop on wall-clock deadlines.
@MainActor @Suite(.serialized) struct CrossfadeTests {
    // MARK: The brief's six

    /// Two 5 s tones with a 2 s crossfade make 8 s of output, to the frame, in one plan.
    @Test func overlapIsExact() async {
        let rig = PipelineRig(["a": tone(440, seconds: 5), "b": tone(660, seconds: 5)])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(2))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        let frames = rig.captured.count / 2
        #expect(abs(frames - 8 * 48_000) <= 1, "\(frames) frames")
        let plan = floatPlan(48_000)
        #expect(rig.output.plans == [plan])
        #expect(
            rig.log.events == [
                .planChanged(plan), rig.started(0, "a"), rig.started(1, "b"), .trackEnded(0), .trackEnded(1),
                .queueEnded,
            ])
    }

    /// Equal power: two uncorrelated noises at the same RMS overlap at that RMS, within 0.5 dB, half way through the
    /// fade (and a quarter and three quarters of the way, where the curves are unequal).
    @Test func equalPower() async {
        let a = noise(1, seconds: 4)
        let b = noise(2, seconds: 4)
        let rig = PipelineRig(["a": a, "b": b])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(2))
        #expect(await rig.playToEnd())
        let captured = rig.captured
        #expect(captured.count == 2 * 6 * 48_000)
        let start = 2 * 48_000
        let overlap = 2 * 48_000
        let half = 2_400
        for at in [overlap / 4, overlap / 2, 3 * overlap / 4] {
            let window = (start + at - half)..<(start + at + half)
            let mix = rmsDb(captured[(2 * window.lowerBound)..<(2 * window.upperBound)])
            let alone = Int64(window.lowerBound)..<Int64(window.upperBound)
            let aDb = rmsDb(plain(a, alone)[...])
            let bDb = rmsDb(plain(b, (alone.lowerBound - Int64(start))..<(alone.upperBound - Int64(start)))[...])
            #expect(abs(mix - aDb) <= 0.5, "at \(at): mix \(mix) dB, a alone \(aDb) dB")
            #expect(abs(mix - bDb) <= 0.5, "at \(at): mix \(mix) dB, b alone \(bDb) dB")
        }
    }

    /// Items of different plans never overlap, crossfade or not: 44.1 then 96 kHz, and mono then stereo, play one
    /// after the other, each to the bit, through a drain and a reconfigure.
    @Test(arguments: [("s16-44100", "s24-96000"), ("s16-44100-mono", "s16-44100")])
    func incompatibleStaysGapless(first: String, second: String) async {
        let rig = PipelineRig()
        await rig.pipeline.start(
            [fixtureItem(first), fixtureItem(second)], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        let one = Fixtures.named(first)
        let two = Fixtures.named(second)
        let plans = [floatPlan(one.sampleRate), floatPlan(two.sampleRate)]
        #expect(rig.output.plans == plans)
        let want =
            floats(Fixtures.rawSamples(one), bits: one.bits) + floats(Fixtures.rawSamples(two), bits: two.bits)
        #expect(mismatch(rig.captured, want) == nil)
        #expect(
            rig.log.events == [
                .planChanged(plans[0]), fixtureStarted(0, first), .trackEnded(0), .planChanged(plans[1]),
                fixtureStarted(1, second), .trackEnded(1), .queueEnded,
            ])
    }

    /// With crossfade Off, or under Pure with crossfade set to Always, the join is
    /// `PlaybackPipelineTests.gaplessJoinSameFormat`'s: two copies of a fixture, sample-exact, one plan. The pipeline
    /// takes Off as it is; the player hands it Off under Pure, and the strip says Pure. Each fixture is 4096 frames,
    /// so a crossfade would overlap the last 2048 of the first with the first 2048 of the second.
    @Test func pureAndOffAreGapless() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-48000"))
        let want = floats(raw + raw, bits: 24)
        let plan = floatPlan(48_000)

        let rig = PipelineRig()
        await rig.pipeline.start(
            [fixtureItem("s24-48000", id: "a"), fixtureItem("s24-48000", id: "b")], at: 0, fromFrame: 0,
            crossfade: CrossfadeSettings(mode: .off, seconds: 1))
        #expect(await rig.playToEnd())
        #expect(rig.captured.count == 8192 * 2)
        #expect(mismatch(rig.captured, want) == nil)
        #expect(rig.output.plans == [plan])
        #expect(
            rig.log.events == [
                .planChanged(plan), fixtureStarted(0, "s24-48000"), .trackEnded(0), fixtureStarted(1, "s24-48000"),
                .trackEnded(1), .queueEnded,
            ])

        var pure = SoundSettings()
        pure.crossfade = always(1)
        let off = sound(CrossfadeSettings(mode: .off, seconds: 1))
        for settings in [pure, off] {
            let player = PlayerRig()
            player.player.setSound(settings)
            await player.player.play(
                [player.fixture("s24-48000", id: "a"), player.fixture("s24-48000", id: "b")], startingAt: 0)
            #expect(await player.puller.pump { player.player.status == .ended }, "status: \(player.player.status)")
            #expect(mismatch(player.output.capturedFloat, want) == nil, "pure: \(settings.pure)")
            #expect(player.output.plans == [plan])
            #expect(player.player.signal.indicator == .pure)
        }
    }

    /// The next item's `trackStarted` fires once the overlap's first frame has rendered, and from that frame on the
    /// position is the new item's; the old one's `trackEnded` waits for the overlap's last frame.
    @Test func positionsFollowTheNewTrack() async {
        let rig = PipelineRig(["a": tone(440, seconds: 2), "b": tone(660, seconds: 2)])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        let start = 48_000
        #expect(await rig.puller.pull(upTo: start - 1))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!rig.log.contains(rig.started(1, "b")))
        #expect(rig.pipeline.position == (0, Int64(start - 1)))
        #expect(rig.pipeline.crossfading == nil)
        #expect(await rig.puller.pull(upTo: start))
        #expect(await rig.heard(rig.started(1, "b")), "\(LatencyBudget.describe(.milliseconds(50)))")
        #expect(rig.pipeline.position == (1, 0))
        #expect(!rig.log.contains(.trackEnded(0)))
        #expect(await rig.puller.pull(upTo: start + 512))
        #expect(rig.pipeline.position == (1, 512))
        #expect(rig.pipeline.renderingGain?.index == 1)
        #expect(rig.pipeline.crossfading?.index == 0)
        #expect(await rig.puller.pull(upTo: 2 * start - 1))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!rig.log.contains(.trackEnded(0)))
        #expect(rig.pipeline.crossfading?.index == 0)
        #expect(await rig.puller.pull(upTo: 2 * start))
        #expect(await rig.heard(.trackEnded(0)))
        #expect(rig.pipeline.crossfading == nil)
        #expect(rig.pipeline.position == (1, Int64(start)))
    }

    /// Between albums overlaps only the boundary `append` marked: two items from `start` join gaplessly, and the
    /// appended third fades in under the second. Always overlaps both, the middle item fading in and straight out.
    @Test(arguments: [CrossfadeMode.betweenAlbums, .always])
    func betweenAlbumsOnlyAtAppend(mode: CrossfadeMode) async {
        let a = tone(440, seconds: 2)
        let b = noise(9, seconds: 2)
        let c = tone(660, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b, "c": c])
        await rig.pipeline.start(
            [rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: CrossfadeSettings(mode: mode, seconds: 1))
        #expect(rig.pipeline.append([rig.item("c")]))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        let half: Int64 = 48_000
        let want: [Float]
        let events: [PipelineEvent]
        if mode == .betweenAlbums {
            want =
                plain(a, 0..<(2 * half)) + plain(b, 0..<half) + mixed(b, from: half, c, from: 0, frames: Int(half))
                + plain(c, half..<(2 * half))
            events = [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), .trackEnded(0), rig.started(1, "b"),
                rig.started(2, "c"), .trackEnded(1), .trackEnded(2), .queueEnded,
            ]
        } else {
            want =
                plain(a, 0..<half) + mixed(a, from: half, b, from: 0, frames: Int(half))
                + mixed(b, from: half, c, from: 0, frames: Int(half)) + plain(c, half..<(2 * half))
            events = [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), rig.started(1, "b"), .trackEnded(0),
                rig.started(2, "c"), .trackEnded(1), .trackEnded(2), .queueEnded,
            ]
        }
        #expect(mismatch(rig.captured, want) == nil)
        #expect(rig.log.events == events)
    }

    // MARK: Gains, the resampler, Int32

    /// Each item is mixed at its own ReplayGain, the one it was entered at: the outgoing halved, the incoming at
    /// −3 dB. From the moment the decode thread enters the incoming item (in the ring, before it is heard) until the
    /// overlap's last frame renders, both count as entered, so a switch can reach both.
    @Test func mixesEachItemAtItsOwnGain() async {
        let a = noise(3, seconds: 2)
        let b = noise(4, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b])
        await rig.pipeline.start(
            [rig.item("a", gainDb: halfDb), rig.item("b", gainDb: -3)], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.puller.pull(upTo: 1024))
        #expect(rig.pipeline.enteredGains.map(\.index) == [0])
        #expect(!rig.pipeline.crossfadePending)
        #expect(await rig.puller.pull(upTo: 30_000))
        #expect(await rig.puller.eventually { rig.pipeline.enteredGains.count == 2 })
        #expect(rig.pipeline.enteredGains.map(\.index) == [0, 1])
        #expect(rig.pipeline.enteredGains.map(\.gainDb) == [halfDb, -3])
        #expect(rig.pipeline.crossfadePending)
        #expect(rig.pipeline.crossfading == nil, "not heard yet")
        #expect(await rig.puller.pull(upTo: 60_000))
        #expect(rig.pipeline.enteredGains.map(\.index) == [0, 1])
        #expect(rig.pipeline.renderingGain?.index == 1)
        #expect(rig.pipeline.renderingGain?.gainDb == -3)
        #expect(rig.pipeline.crossfading?.index == 0)
        #expect(rig.pipeline.crossfading?.gainDb == halfDb)
        #expect(await rig.playToEnd())
        let want =
            plain(a, 0..<48_000, gainDb: halfDb)
            + mixed(a, from: 48_000, gainDb: halfDb, b, from: 0, gainDb: -3, frames: 48_000)
            + plain(b, 48_000..<96_000, gainDb: -3)
        #expect(mismatch(rig.captured, want) == nil)
        #expect(!rig.pipeline.crossfadePending)
    }

    /// Under the resampler the two items are mixed at their own rate, ahead of it, and the mix feeds the one
    /// converter: the capture is the mixed source resampled in one go (96 → 48 kHz), within Float32 rounding.
    @Test func overlapsAheadOfTheResampler() async throws {
        let a = noise(5, seconds: 2, rate: 96_000)
        let b = noise(6, seconds: 2, rate: 96_000)
        let rig = PipelineRig(["a": a, "b": b], hardwareRate: { _ in 48_000 })
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        let plan = floatPlan(48_000, resample: RateChange(from: 96_000, to: 48_000))
        #expect(rig.output.plans == [plan])
        let source =
            plain(a, 0..<96_000) + mixed(a, from: 96_000, b, from: 0, frames: 96_000) + plain(b, 96_000..<192_000)
        let reference = try oneShotResample(source, from: 96_000, to: 48_000)
        let captured = rig.captured
        #expect(captured.count == reference.count)
        let worst = zip(captured, reference).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(worst <= 1e-4, "largest difference \(worst)")
        #expect(
            rig.log.events == [
                .planChanged(plan), rig.started(0, "a"), rig.started(1, "b"), .trackEnded(0), .trackEnded(1),
                .queueEnded,
            ])
    }

    /// An Int32 client (a 32-bit source with passthrough) carries the source's words untouched, so it never
    /// overlaps, crossfade or not: the boundary is the gapless join, to the bit, as `purePathIsBitExact` plays it.
    @Test func anInt32ClientJoinsGaplessly() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s32-48000"))
        let rig = PipelineRig(int32Passthrough: true)
        await rig.pipeline.start(
            [fixtureItem("s32-48000", id: "a"), fixtureItem("s32-48000", id: "b")], at: 0, fromFrame: 0,
            crossfade: always(1))
        #expect(await rig.playToEnd())
        #expect(mismatch(rig.output.capturedInt32, raw + raw) == nil)
        #expect(rig.output.plans.map(\.client) == [.int32])
        #expect(
            rig.log.events == [
                .planChanged(rig.output.plans[0]), fixtureStarted(0, "s32-48000"), .trackEnded(0),
                fixtureStarted(1, "s32-48000"), .trackEnded(1), .queueEnded,
            ])
    }

    /// A crossfade switched off after the decode thread prepared an overlap, before it began, is called off at its
    /// start: the boundary joins gaplessly, to the bit. The incoming item is half the fade long, so the overlap is
    /// clamped to a quarter of it and prepared well ahead of its start.
    @Test func aCrossfadeCalledOffBeforeItsStartJoins() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 1)
        let rig = PipelineRig(["a": a, "b": b])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(2))
        // The ring fills (32 768 frames) long before the overlap's start, at 72 000.
        #expect(await rig.puller.pull(upTo: 1024))
        try? await Task.sleep(for: .milliseconds(30))
        rig.pipeline.setCrossfade(CrossfadeSettings(mode: .off, seconds: 2))
        #expect(await rig.playToEnd())
        #expect(mismatch(rig.captured, plain(a, 0..<96_000) + plain(b, 0..<48_000)) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), .trackEnded(0), rig.started(1, "b"),
                .trackEnded(1), .queueEnded,
            ])
    }

    /// An item that fails within an overlap is silent from there: what it decoded before plays, and the other item
    /// carries on along its curve. The incoming item failing 1000 frames in, the outgoing one fades out alone, and the
    /// failure fires after its end.
    @Test func aFailureInAnOverlapSilencesThatItem() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b], failing: ["b": 1000])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        var want = plain(a, 0..<48_000) + mixed(a, from: 48_000, b, from: 0, frames: 1000, of: 48_000)
        for k in 1000..<48_000 {
            let w = PlaybackPipeline.crossfadeWeights(frame: k, of: 48_000)
            for c in 0..<2 {
                want.append(Float(Double(a.float(Int64(48_000 + k), channel: c)) * w.outgoing + 0 * w.incoming))
            }
        }
        #expect(mismatch(rig.captured, want) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), rig.started(1, "b"), .trackEnded(0),
                .itemFailed(1, "ioError"), .queueEnded,
            ])
    }

    /// The outgoing item failing within an overlap is silent from there, the incoming one carrying on along its
    /// curve; the failure fires at the overlap's end, where the outgoing item's end would have.
    @Test func aFailureOfTheOutgoingItemInAnOverlap() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b], failing: ["a": 50_000])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        var want = plain(a, 0..<48_000) + mixed(a, from: 48_000, b, from: 0, frames: 2000, of: 48_000)
        for k in 2000..<48_000 {
            let w = PlaybackPipeline.crossfadeWeights(frame: k, of: 48_000)
            for c in 0..<2 {
                want.append(Float(0 * w.outgoing + Double(b.float(Int64(k), channel: c)) * w.incoming))
            }
        }
        want += plain(b, 48_000..<96_000)
        #expect(mismatch(rig.captured, want) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), rig.started(1, "b"), .itemFailed(0, "ioError"),
                .trackEnded(1), .queueEnded,
            ])
    }

    /// Both items running out within the same block of an overlap (lengths overstated: the outgoing item ends 2000
    /// frames in, the incoming one after 1000) end it at the later of the two, with no silence padded after.
    @Test func anOverlapWhoseItemsBothRunShortEndsWithThem() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b], short: ["a": 50_000, "b": 1000])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        var want = plain(a, 0..<48_000) + mixed(a, from: 48_000, b, from: 0, frames: 1000, of: 48_000)
        for k in 1000..<2000 {
            let w = PlaybackPipeline.crossfadeWeights(frame: k, of: 48_000)
            for c in 0..<2 {
                want.append(Float(Double(a.float(Int64(48_000 + k), channel: c)) * w.outgoing + 0 * w.incoming))
            }
        }
        #expect(rig.captured.count == 2 * 50_000)
        #expect(mismatch(rig.captured, want) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), rig.started(1, "b"), .trackEnded(0),
                .trackEnded(1), .queueEnded,
            ])
    }

    // MARK: Seeks, stops, pauses, scrubs in an overlap

    /// A seek during an overlap under the resampler ends it as without one: the position is the incoming item's, the
    /// outgoing one's end fires at the seek, and what follows is the dip then the incoming item alone from the target.
    @Test func aSeekDuringAnOverlapUnderTheResampler() async {
        let a = noise(12, seconds: 2, rate: 96_000)
        let b = noise(13, seconds: 2, rate: 96_000)
        let rig = PipelineRig(["a": a, "b": b], hardwareRate: { _ in 48_000 })
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        // The overlap renders from 48 000 (96 000 source frames, resampled to half).
        #expect(await rig.puller.pull(upTo: 60_000))
        await letTheRingFill()
        let mark = rig.captured.count
        await rig.pipeline.seek(toFrame: 100_000)
        #expect(rig.pipeline.position == (1, 100_000))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        let after = (rig.captured.count - mark) / 2
        #expect(abs(after - (seekFade + 46_000)) <= 64, "\(after) frames after the seek")
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000, resample: RateChange(from: 96_000, to: 48_000))), rig.started(0, "a"),
                rig.started(1, "b"), .trackEnded(0), .trackEnded(1), .queueEnded,
            ])
    }

    /// A seek during an overlap ends it. Once the overlap is heard (its start rendered) the position is the incoming
    /// item's, the seek lands in it, and nothing of the outgoing item plays again: it is cut off, and its
    /// `trackEnded` fires at the seek. That holds whether the decode thread is still mixing (60 000) or past the
    /// overlap's end (90 000). A seek before the overlap is heard (40 000), with the decode thread mixing ahead in the
    /// ring, lands in the outgoing item, which overlaps afresh when its end comes round again. Either way the seek is
    /// the usual dip: the 6 ms of what was playing fade out, then the target fades in alone.
    @Test(arguments: [60_000, 90_000, 40_000])
    func aSeekDuringAnOverlapEndsIt(pulledTo: Int) async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.puller.pull(upTo: pulledTo))
        // The decode thread runs ahead into, or past, the overlap, and fills the ring for the fade-out.
        await letTheRingFill()
        let heard = pulledTo >= 48_000
        let target: Int64 = heard ? 30_000 : 20_000
        let mark = rig.captured.count
        await rig.pipeline.seek(toFrame: target)
        #expect(rig.pipeline.position == (heard ? 1 : 0, target))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        let uninterrupted =
            plain(a, 0..<48_000) + mixed(a, from: 48_000, b, from: 0, frames: 48_000) + plain(b, 48_000..<96_000)
        let after =
            heard
            ? plain(b, target..<96_000)
            : plain(a, target..<48_000) + mixed(a, from: 48_000, b, from: 0, frames: 48_000)
                + plain(b, 48_000..<96_000)
        let want = seekDip(old: uninterrupted[(2 * pulledTo)...], new: after)
        #expect(mismatch(Array(rig.captured[mark...]), want) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), rig.started(1, "b"), .trackEnded(0),
                .trackEnded(1), .queueEnded,
            ])
        #expect(!rig.pipeline.crossfadePending)
    }

    /// The overlap's `aSeekJustBeforeAGaplessJoinStaysInItsItem`: a seek asked within the 6 ms before an overlap's
    /// start plays its fade-out into the mixed audio, whose frames are not counted, so the overlap's `trackStarted`
    /// is never reached and the seek stays in the outgoing item. That item replays from the target, overlapping
    /// afresh at its end, and the incoming item's `trackStarted` fires once, there.
    @Test func aSeekJustBeforeAnOverlapStaysInItsItem() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        let short = 100
        #expect(short < seekFade)
        #expect(await rig.puller.pull(upTo: 48_000 - short))
        await letTheRingFill()
        let mark = rig.captured.count
        await rig.pipeline.seek(toFrame: 1000)
        #expect(await rig.puller.pull(upTo: 48_000 - short + seekFade + 512))
        #expect(rig.pipeline.position == (0, 1512), "the seek stayed in the outgoing item")
        #expect(!rig.log.contains(rig.started(1, "b")))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        // The fade-out: the outgoing item's last 100 plain frames, then the overlap's first 188, mixed.
        let across = plain(a, Int64(48_000 - short)..<48_000) + mixed(a, from: 48_000, b, from: 0, frames: 48_000)
        let after =
            plain(a, 1000..<48_000) + mixed(a, from: 48_000, b, from: 0, frames: 48_000) + plain(b, 48_000..<96_000)
        #expect(mismatch(Array(rig.captured[mark...]), seekDip(old: across, new: after)) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), rig.started(1, "b"), .trackEnded(0),
                .trackEnded(1), .queueEnded,
            ])
    }

    /// A seek into the last fade's worth of an item overlaps at once, for what is left of it (16 000 frames here), and
    /// its 6 ms fade-in is on what is heard: the mix, each side at its own gain, faded in as one.
    @Test func aSeekIntoTheFadeOverlapsAtOnceAndFadesInTheMix() async {
        let a = noise(10, seconds: 2)
        let b = noise(11, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b])
        await rig.pipeline.start(
            [rig.item("a", gainDb: halfDb), rig.item("b", gainDb: -3)], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.puller.pull(upTo: 10_000))
        await letTheRingFill()
        let mark = rig.captured.count
        await rig.pipeline.seek(toFrame: 80_000)
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        let after =
            mixed(a, from: 80_000, gainDb: halfDb, b, from: 0, gainDb: -3, frames: 16_000)
            + plain(b, 16_000..<96_000, gainDb: -3)
        let want = seekDip(old: plain(a, 10_000..<(10_000 + Int64(seekFade)), gainDb: halfDb), new: after)
        #expect(mismatch(Array(rig.captured[mark...]), want) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), rig.started(1, "b"), .trackEnded(0),
                .trackEnded(1), .queueEnded,
            ])
    }

    /// A stop during an overlap stops it like any other playback: the output stops, the decode thread unwinds, the
    /// position stays on the incoming item, and the next start plays as usual. A pause during one remembers the
    /// incoming item's frame; the resume plays that item from there, with nothing of the outgoing one.
    @Test func stopOrPauseDuringAnOverlap() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b])
        await rig.pipeline.start([rig.item("a"), rig.item("b")], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.puller.pull(upTo: 60_000))
        rig.pipeline.stop()
        #expect(!rig.output.isStarted)
        #expect(rig.puller.pullOnce() == 0)
        #expect(await rig.puller.eventually { rig.pipeline.liveDecodeThreads == 0 })
        #expect(rig.pipeline.position == (1, 12_000))
        let mark = rig.captured.count
        await rig.pipeline.start([fixtureItem("s16-44100")], at: 0, fromFrame: 0)
        #expect(await rig.playToEnd())
        let raw = floats(Fixtures.rawSamples(Fixtures.named("s16-44100")), bits: 16)
        #expect(mismatch(Array(rig.captured[mark...]), raw) == nil)

        let settings = sound(always(1))
        let player = PlayerRig(["a": a, "b": b])
        player.player.setSound(settings)
        await player.player.play([player.item("a"), player.item("b")], startingAt: 0)
        #expect(await player.puller.eventually { player.player.status == .playing })
        #expect(await player.puller.pull(upTo: 60_000))
        #expect(await player.puller.eventually { player.player.currentIndex == 1 })
        player.player.pause()
        #expect(player.player.status == .paused)
        #expect(player.player.currentIndex == 1)
        #expect(player.player.position == .milliseconds(250))
        let resumedAt = player.output.capturedFloat.count / 2
        player.player.resume()
        #expect(await player.puller.eventually { player.player.status == .playing })
        #expect(await player.puller.pump { player.player.status == .ended })
        let after = Array(player.output.capturedFloat[(2 * resumedAt)...])
        #expect(after.count == 2 * (96_000 - 12_000))
        // The fresh chain opens on its look-ahead's silence, then plays the incoming item alone from the pause.
        let latency = SoundChain(settings, sampleRate: 48_000, channels: 2).latencyFrames
        #expect(after.prefix(2 * latency).allSatisfy { $0 == 0 })
        var worst: Float = 0
        for k in latency..<(after.count / 2) {
            for c in 0..<2 {
                worst = max(worst, abs(after[2 * k + c] - b.float(Int64(12_000 + k - latency), channel: c)))
            }
        }
        #expect(worst < 1e-6, "largest difference from the incoming item alone: \(worst)")
    }

    /// A finger on the record during an overlap cancels the fade: the hand plays the incoming item, and the let-go
    /// seeks the pipeline in it, which ends the overlap. Nothing crashes, nothing of the outgoing item comes back, and
    /// the incoming item plays out.
    @Test func aScrubDuringAnOverlapCancelsTheFade() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PlayerRig(["a": a, "b": b])
        rig.player.setSound(sound(always(1)))
        await rig.player.play([rig.item("a"), rig.item("b")], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        await rig.puller.paced(56_000)
        #expect(await rig.puller.eventually { rig.player.currentIndex == 1 })
        #expect(rig.player.pipeline?.crossfading?.index == 0)
        #expect(rig.player.beginScrub())
        let tap = rig.player.pipeline?.scrubTap
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(10))
        while let tap, tap.voiceStarted.load(ordering: .acquiring) != tap.generation.load(ordering: .acquiring),
            ContinuousClock.now < deadline
        {
            await rig.puller.paced(512)
        }
        await rig.puller.paced(4_800)
        let settled = rig.player.endScrub(spinUpSeconds: 0.05)
        var done = false
        Task { @MainActor in
            await settled.value
            done = true
        }
        #expect(await rig.puller.pump { done })
        #expect(!rig.player.isScrubbing)
        #expect(rig.player.status == .playing)
        #expect(rig.player.pipeline?.crossfadePending == false)
        #expect(rig.player.pipeline?.crossfading == nil)
        #expect(rig.player.pipeline?.enteredGains.map(\.index) == [1])
        #expect(rig.player.pipeline?.position.index == 1)
        #expect(await rig.puller.pump { rig.player.status == .ended })
        #expect(rig.player.currentIndex == 1)
    }

    /// Previous during an overlap, on the incoming item's first seconds, goes back to the outgoing item's start on a
    /// fresh pipeline: nothing of the overlap comes with it.
    @Test func previousDuringAnOverlapGoesBackCleanly() async {
        let rig = PlayerRig(["a": tone(440, seconds: 2), "b": tone(660, seconds: 2)])
        rig.player.setSound(sound(always(1)))
        await rig.player.play([rig.item("a"), rig.item("b")], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 60_000))
        #expect(await rig.puller.eventually { rig.player.currentIndex == 1 })
        await rig.player.previous()
        #expect(rig.player.currentIndex == 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(rig.player.pipeline?.crossfadePending == false)
        #expect(rig.player.pipeline?.position.index == 0)
        rig.player.pause()
    }

    // MARK: Repeat-one (ruling R4-T16a)

    /// With `crossfadeSuppressed` (repeat-one) every boundary is gapless whatever the crossfade setting: all of the
    /// first item plays before the next starts, so the controller's restart at that boundary loops the whole track.
    /// Turned on while an overlap is in the ring, it re-cues it away: the boundary then joins.
    @Test func suppressedCrossfadeKeepsEveryBoundaryGapless() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PlayerRig(["a": a, "b": b])
        rig.player.crossfadeSuppressed = true
        rig.player.setSound(sound(always(1)))
        await rig.player.play([rig.item("a"), rig.item("b")], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 96_000 - 512))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.player.currentIndex == 0, "the next item started before the first played out")
        #expect(rig.player.pipeline?.crossfadePending == false)
        #expect(await rig.puller.pump { rig.player.currentIndex == 1 })
        #expect(rig.puller.pulled >= 96_000)
        #expect(await rig.puller.pump { rig.player.status == .ended })
        #expect(rig.output.capturedFloat.count == 2 * 2 * 96_000)

        let late = PlayerRig(["a": a, "b": b])
        late.player.setSound(sound(always(1)))
        await late.player.play([late.item("a"), late.item("b")], startingAt: 0)
        #expect(await late.puller.eventually { late.player.status == .playing })
        #expect(await late.puller.pull(upTo: 40_000))
        await letTheRingFill()
        #expect(late.player.pipeline?.crossfadePending == true, "the overlap is mixed ahead in the ring")
        late.player.crossfadeSuppressed = true
        await late.drained()
        #expect(late.player.recueCount == 1)
        #expect(await late.puller.pump { late.player.status == .ended })
        let joined: Int = 40_000 + seekFade + 56_000 + 96_000
        #expect(late.output.capturedFloat.count == 2 * joined)
    }

    // MARK: Taking an append back (ruling R4-T16b)

    /// `removeAppended` takes back appended items that have not started, wherever the decode thread has got to:
    /// not yet looked at (1024), joined gaplessly in the ring (80 000, flushed by a re-cue at the playhead: the dip),
    /// or overlapping in the ring (40 000 under Always, likewise). The queue then ends with the first item. Once the
    /// appended item is heard (60 000 under Always: the overlap renders) it is refused, and plays on.
    @Test(arguments: [(CrossfadeMode.off, 1024), (.off, 80_000), (.always, 40_000), (.always, 60_000)])
    func removeAppendedTakesBackWhatHasNotStarted(mode: CrossfadeMode, pulledTo: Int) async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PlayerRig(["a": a, "b": b])
        if mode != .off { rig.player.setSound(sound(CrossfadeSettings(mode: mode, seconds: 1))) }
        await rig.player.play([rig.item("a")], startingAt: 0)
        await rig.player.append([rig.item("b")]).value
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: pulledTo))
        await letTheRingFill()
        let heard = mode == .always && pulledTo >= 48_000
        if heard { #expect(await rig.puller.eventually { rig.player.currentIndex == 1 }) }
        #expect(rig.player.removeAppended(from: 1) == !heard)
        #expect(rig.player.queue.map(\.id) == (heard ? ["a", "b"] : ["a"]))
        #expect(await rig.puller.pump { rig.player.status == .ended }, "status: \(rig.player.status)")
        let captured = rig.output.capturedFloat
        switch (mode, pulledTo) {
        case (.off, 1024):
            #expect(mismatch(captured, plain(a, 0..<96_000)) == nil)
        case (.off, _):
            let want =
                plain(a, 0..<80_000) + seekDip(old: plain(a, 80_000..<96_000), new: plain(a, 80_000..<96_000))
            #expect(mismatch(captured, want) == nil)
        case (_, 40_000):
            let joined: Int = 40_000 + seekFade + 56_000
            #expect(captured.count == 2 * joined)
        default:
            let overlapped: Int = 2 * 96_000 - 48_000
            #expect(captured.count == 2 * overlapped)
            #expect(rig.player.currentIndex == 1)
        }
        #expect(rig.output.plans == [floatPlan(48_000)])
    }

    /// Review N1, the drain: an item at another rate, taken back while the ring drains for its reconfigure, must not
    /// play. The take-back reports success and is kept: no output is configured for the item, and the queue ends
    /// after the first. With an item appended in its place, that one plays as index 1 (nothing of the one taken
    /// back under its index), through its own reconfigure.
    @Test(arguments: [false, true])
    func anItemTakenBackDuringADrainNeverPlays(replaced: Bool) async {
        let a = tone(440, seconds: 1, rate: 44_100)
        let b = tone(660, seconds: 1, rate: 96_000)
        let c = noise(22, seconds: 0.5, rate: 96_000)
        let rig = PipelineRig(["a": a, "b": b, "c": c])
        await rig.pipeline.start([rig.item("a")], at: 0, fromFrame: 0)
        #expect(rig.pipeline.append([rig.item("b")]))
        // The decode thread has written all of the first item, opened the second and waits for the ring to drain.
        #expect(await rig.puller.pull(upTo: 44_100 - 2_000))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.pipeline.removeItems(from: 1))
        if replaced { #expect(rig.pipeline.append([rig.item("c")])) }
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        #expect(!rig.log.contains(rig.started(1, "b")), "events: \(rig.log.events)")
        let first = floatPlan(44_100)
        if replaced {
            #expect(mismatch(rig.captured, plain(a, 0..<44_100) + plain(c, 0..<48_000)) == nil)
            #expect(
                rig.log.events == [
                    .planChanged(first), rig.started(0, "a"), .trackEnded(0), .planChanged(floatPlan(96_000)),
                    rig.started(1, "c"), .trackEnded(1), .queueEnded,
                ])
        } else {
            #expect(mismatch(rig.captured, plain(a, 0..<44_100)) == nil)
            #expect(rig.log.events == [.planChanged(first), rig.started(0, "a"), .trackEnded(0), .queueEnded])
            #expect(rig.output.plans == [first], "no output was configured for the item taken back")
        }
    }

    /// Review N1, the overlap: an item taken back after the decode thread prepared its overlap (clamped to a quarter
    /// of the fade by the item's length, so prepared at the outgoing item's 96 000 and due at 168 000), with another
    /// appended in its place before the overlap starts. Index 1 is the replacement, overlapped afresh for what is
    /// left (its own half, 12 000 frames), and nothing of the item taken back plays.
    @Test func aTakeBackAndAReplacementBeforeAShortenedOverlap() async {
        let a = tone(440, seconds: 4)
        let b = tone(660, seconds: 1)
        let c = noise(21, seconds: 0.5)
        let rig = PipelineRig(["a": a, "b": b, "c": c])
        await rig.pipeline.start([rig.item("a")], at: 0, fromFrame: 0, crossfade: always(2))
        #expect(rig.pipeline.append([rig.item("b")]))
        #expect(await rig.puller.pull(upTo: 100_000))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.pipeline.removeItems(from: 1))
        #expect(rig.pipeline.append([rig.item("c")]))
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        #expect(!rig.log.contains(rig.started(1, "b")), "events: \(rig.log.events)")
        let want =
            plain(a, 0..<180_000) + mixed(a, from: 180_000, c, from: 0, frames: 12_000) + plain(c, 12_000..<24_000)
        #expect(mismatch(rig.captured, want) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), rig.started(0, "a"), rig.started(1, "c"), .trackEnded(0),
                .trackEnded(1), .queueEnded,
            ])
    }

    /// An append taken back before it reached the pipeline (it waits on the engine's queue) never does; a later
    /// append at the same place plays.
    @Test func anAppendTakenBackOnItsWayNeverReachesThePipeline() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let c = noise(14, seconds: 1)
        let rig = PlayerRig(["a": a, "b": b, "c": c])
        await rig.player.play([rig.item("a")], startingAt: 0)
        let onItsWay = rig.player.append([rig.item("b")])
        #expect(rig.player.removeAppended(from: 1))
        await onItsWay.value
        await rig.player.append([rig.item("c")]).value
        #expect(rig.player.queue.map(\.id) == ["a", "c"])
        #expect(await rig.puller.pump { rig.player.status == .ended }, "status: \(rig.player.status)")
        #expect(mismatch(rig.output.capturedFloat, plain(a, 0..<96_000) + plain(c, 0..<48_000)) == nil)
        #expect(rig.output.plans == [floatPlan(48_000)])
    }

    // MARK: Switches in an overlap (rulings R4-T12a, R4-T12b)

    /// Pure set during an overlap is heard at once. Both items count as entered, so a gain on either re-cues, and so
    /// does the overlap itself when neither has one (Pure plays no crossfade). The re-cue ends the overlap: from one
    /// buffer after its dip, the incoming item plays alone, ungained, to the bit, from where playback had reached.
    @Test(arguments: [(halfDb, halfDb), (halfDb, 0.0), (0.0, halfDb), (0.0, 0.0)] as [(Double, Double)])
    func aSwitchDuringAnOverlapReachesBoth(outgoingGainDb: Double, incomingGainDb: Double) async {
        let a = noise(7, seconds: 2)
        let b = noise(8, seconds: 2)
        let rig = PlayerRig(["a": a, "b": b])
        rig.player.setSound(sound(always(1), replayGain: .track))
        await rig.player.play(
            [rig.item("a", trackGainDb: outgoingGainDb), rig.item("b", trackGainDb: incomingGainDb)], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 60_000))
        guard let pipeline = rig.player.pipeline else {
            Issue.record("no pipeline")
            return
        }
        #expect(pipeline.enteredGains.map(\.index) == [0, 1])
        #expect(pipeline.enteredGains.map(\.gainDb) == [outgoingGainDb, incomingGainDb])
        #expect(pipeline.crossfadePending)
        await letTheRingFill()
        rig.player.setSound(SoundSettings())
        await rig.drained()
        #expect(rig.player.recueCount == 1)
        #expect(await rig.puller.pull(upTo: 60_000 + seekFade + 8192))
        let captured = rig.output.capturedFloat
        var got: [Float] = []
        var want: [Float] = []
        // Past the re-cue's dip (the overlap's 6 ms fading out, then the fade-in) and the chain's fade to Pure.
        for k in 512..<8192 {
            for c in 0..<2 {
                got.append(captured[2 * (60_000 + seekFade + k) + c])
                want.append(b.float(Int64(12_000 + k), channel: c))
            }
        }
        #expect(mismatch(got, want) == nil)
        #expect(!pipeline.crossfadePending)
        #expect(pipeline.crossfading == nil)
        #expect(pipeline.enteredGains.map(\.index) == [1])
        #expect(await rig.puller.eventually { rig.player.signal.indicator == .pure })
        rig.player.pause()
    }

    // MARK: The strip

    /// The strip lists Crossfade exactly while an overlap is heard, as it lists ReplayGain exactly while a gain
    /// applies: during the overlap the outgoing item's gain still applies, though the incoming one has none.
    @Test func stripListsCrossfadeOnlyWhileMixing() async {
        let rig = PlayerRig(["a": tone(440, seconds: 2), "b": tone(660, seconds: 2)])
        rig.player.setSound(sound(always(1), replayGain: .track))
        await rig.player.play([rig.item("a", trackGainDb: halfDb), rig.item("b", trackGainDb: 0)], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(rig.player.signal.activeProcessing == ["ReplayGain", "Limiter"])
        #expect(await rig.puller.pull(upTo: 48_000 + 2048))
        #expect(
            await rig.puller.eventually {
                rig.player.signal.activeProcessing == ["ReplayGain", "Limiter", "Crossfade"]
            }, "\(rig.player.signal.activeProcessing)")
        #expect(rig.player.signal.indicator == .processing(3))
        #expect(await rig.puller.pull(upTo: 96_000 + 2048))
        #expect(
            await rig.puller.eventually { rig.player.signal.activeProcessing == ["Limiter"] },
            "\(rig.player.signal.activeProcessing)")
        rig.player.pause()
    }

    // MARK: Appending

    /// `Player.append` adds to the queue behind the item playing: in Pure the pipeline joins it gaplessly, to the
    /// bit, in the one plan; with Between albums it overlaps the appended boundary.
    @Test func appendedItemsPlayOn() async {
        let a = tone(440, seconds: 2)
        let b = tone(660, seconds: 2)
        let rig = PlayerRig(["a": a, "b": b])
        await rig.player.play([rig.item("a")], startingAt: 0)
        await rig.player.append([rig.item("b")]).value
        #expect(rig.player.queue.map(\.id) == ["a", "b"])
        #expect(await rig.puller.pump { rig.player.status == .ended }, "status: \(rig.player.status)")
        #expect(mismatch(rig.output.capturedFloat, plain(a, 0..<96_000) + plain(b, 0..<96_000)) == nil)
        #expect(rig.output.plans == [floatPlan(48_000)])
        #expect(rig.player.currentIndex == 1)

        let crossfading = PlayerRig(["a": a, "b": b])
        crossfading.player.setSound(sound(CrossfadeSettings(mode: .betweenAlbums, seconds: 1)))
        await crossfading.player.play([crossfading.item("a")], startingAt: 0)
        await crossfading.player.append([crossfading.item("b")]).value
        #expect(await crossfading.puller.pump { crossfading.player.status == .ended })
        let overlapped = 2 * 96_000 - 48_000
        #expect(crossfading.output.capturedFloat.count == 2 * overlapped)
        #expect(crossfading.output.plans == [floatPlan(48_000)])
    }

    /// An append that comes after the decode thread found the queue at its end is refused by the pipeline. The player
    /// then plays the appended items afresh once the queue has played out, rather than end.
    @Test func aLateAppendStillPlays() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-48000"))
        let rig = PlayerRig()
        await rig.player.play([rig.fixture("s24-48000", id: "a")], startingAt: 0)
        // The fixture fits in the ring: the decode thread writes all of it and closes the queue at once.
        #expect(await rig.puller.eventually { rig.player.pipeline?.queueClosed == true })
        await rig.player.append([rig.fixture("s24-48000", id: "b")]).value
        #expect(await rig.puller.pump { rig.player.status == .ended }, "status: \(rig.player.status)")
        #expect(mismatch(rig.output.capturedFloat, floats(raw + raw, bits: 24)) == nil)
        #expect(rig.output.plans == [floatPlan(48_000), floatPlan(48_000)])
        #expect(rig.player.currentIndex == 1)
    }
    /// Two overlaps mixed ahead in the ring and none heard yet: a seek back inside item 0 must not report item 1 ended
    /// before it has started (re-review 2, R2-1; it did with `!=` in the seek's end-marker cut).
    @Test func aSeekBeforeBackToBackOverlapsKeepsTheEventOrder() async {
        let a = tone(440, seconds: 2)
        let b = tone(550, seconds: 0.4)
        let c = tone(660, seconds: 2)
        let rig = PipelineRig(["a": a, "b": b, "c": c])
        await rig.pipeline.start(
            [rig.item("a"), rig.item("b"), rig.item("c")], at: 0, fromFrame: 0, crossfade: always(1))
        #expect(await rig.puller.pull(upTo: 80_000))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.pipeline.position.index == 0)
        await rig.pipeline.seek(toFrame: 1000)
        #expect(await rig.playToEnd(), "events: \(rig.log.events)")
        let events = rig.log.events
        let ended1 = events.firstIndex(of: .trackEnded(1))
        let started1 = events.firstIndex(of: rig.started(1, "b"))
        #expect(ended1 != nil && started1 != nil && ended1! > started1!, "events: \(events)")
        #expect(events.filter { $0 == .trackEnded(1) }.count == 1, "events: \(events)")
    }
}
