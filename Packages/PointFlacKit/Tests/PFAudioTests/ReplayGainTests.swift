import Foundation
import PFCore
import PFDSP
import PFFlac
import PFTestSupport
import Synchronization
import Testing

@testable import PFAudio

// MARK: - Sources

/// −6.02 dB: exactly half (20·log10 0.5 = −6.0206), so a halved capture can be checked to the bit. A tag reading
/// "-6.02 dB" is 0.50003 of the level, 3.5e-5 off a full-scale sample.
private let halfDb = 20 * log10(0.5)

/// Sixty thousand frames (1.25 s) of 24-bit stereo at 48 kHz whose samples are a hash of their frame and channel, so
/// any stretch of a capture can be matched to the source frames it came from. Longer than the ring (0.5 s), so the
/// decode thread is still inside it while the first half second renders. Noise within ±1/8 of full scale (−18 dBFS),
/// so its true peak stays far below the limiter's ceiling, which then only delays. Ids starting "hash44" decode the
/// same samples at 44.1 kHz.
private final class HashDecoder: PCMDecoding {
    static let format = AudioFormat(sampleRate: 48_000, bitsPerSample: 24, channels: 2)
    static let format44 = AudioFormat(sampleRate: 44_100, bitsPerSample: 24, channels: 2)
    static let frames: Int64 = 60_000

    let format: AudioFormat

    init(format: AudioFormat = HashDecoder.format) {
        self.format = format
    }

    static func value(_ frame: Int64, channel: Int) -> Int32 {
        Int32((frame &* 2_654_435_761 &+ Int64(channel) &* 40_503) & 0x1F_FFFF) - 0x10_0000
    }

    /// Sample (frame, channel) as the Float32 client receives it at `gain` (exact for a power of two).
    static func float(_ frame: Int64, channel: Int, gain: Float = 1) -> Float {
        Float(value(frame, channel: channel)) * (0x1p-23 * gain)
    }

    var totalFrames: Int64 { Self.frames }
    private var position: Int64 = 0

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        let n = Int(min(Int64(min(maxFrames, buffer.count / 2)), Self.frames - position))
        for i in 0..<n {
            for c in 0..<2 { buffer[2 * i + c] = Self.value(position + Int64(i), channel: c) }
        }
        position += Int64(n)
        return n
    }

    func seek(toFrame frame: Int64) throws {
        position = min(max(frame, 0), Self.frames)
    }
}

/// The item IDs the decoder factory has opened, in order, so a test can tell the decode thread has reached an item.
private let opened = Mutex<[String]>([])

/// Ids starting "hash" decode `HashDecoder` (at 44.1 kHz for "hash44"); anything else is a fixture file.
private let decoder: @Sendable (PlaybackItem) throws -> PCMDecoding = { item in
    opened.withLock { $0.append(item.id) }
    if item.id.hasPrefix("hash44") { return HashDecoder(format: HashDecoder.format44) }
    if item.id.hasPrefix("hash") { return HashDecoder() }
    return try FlacDecoder(url: item.url)
}

private func fixtureItem(_ name: String, id: String? = nil, loudness: TrackLoudness?) -> QueueItem {
    let f = Fixtures.named(name)
    return QueueItem(
        id: id ?? name, url: Fixtures.url(f), title: name, artist: "", album: "",
        format: AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels),
        totalFrames: f.frames, loudness: loudness)
}

private func hashItem(_ id: String, loudness: TrackLoudness?) -> QueueItem {
    QueueItem(
        id: id, url: URL(fileURLWithPath: "/dev/null"), title: id, artist: "", album: "",
        format: id.hasPrefix("hash44") ? HashDecoder.format44 : HashDecoder.format, totalFrames: HashDecoder.frames,
        loudness: loudness)
}

/// A queue item that is only its loudness, for the gain rules.
private func track(_ loudness: TrackLoudness?) -> QueueItem {
    hashItem("hash-rules", loudness: loudness)
}

/// Pure off, ReplayGain in `mode`, with `edit` applied to the ReplayGain settings.
private func sound(_ mode: ReplayGainMode, _ edit: (inout ReplayGainSettings) -> Void = { _ in }) -> SoundSettings {
    var s = SoundSettings()
    s.pure = false
    s.replayGain.mode = mode
    edit(&s.replayGain)
    return s
}

private func floatPlan(_ rate: Int, reduceTo24: Bool = false) -> OutputPlan {
    OutputPlan(client: .float32, clientSampleRate: rate, resample: nil, reduceTo24: reduceTo24)
}

/// Nil when the arrays are identical; otherwise where they first differ. Floats compare by bit pattern.
private func mismatch(_ got: [Float], _ want: [Float]) -> String? {
    guard got.count == want.count else { return "count \(got.count) ≠ \(want.count)" }
    guard let i = got.indices.first(where: { got[$0].bitPattern != want[$0].bitPattern }) else { return nil }
    return "first difference at sample \(i): \(got[i]) ≠ \(want[i])"
}

/// A seek's (or a re-cue's) fade-out and fade-in at 48 kHz: 6 ms, 288 frames.
private let seekFade = RenderSource.fadeFrames(atRate: 48_000)

/// Waits without pulling while the decode thread runs ahead, so that the ring holds the 6 ms a seek's fade-out plays:
/// pulled flat out from the start, the render thread can catch up with it, and a seek then finds the ring empty and
/// has nothing to fade (`SeekFadeOutTests.theFadeEndsWhereTheRingRunsDry`).
private func letTheRingFill() async {
    try? await Task.sleep(for: .milliseconds(50))
}

/// What a seek puts in a stereo capture at 48 kHz after the frames pulled before it: `old(k, channel)` for the
/// `seekFade` frames that were playing, faded out on the raised cosine (`RenderSource.seekFadeGain`); then `frames`
/// frames of `new(k, channel)`, the first `seekFade` faded in linearly (k / `seekFade`).
private func dip(old: (Int, Int) -> Float, new: (Int, Int) -> Float, frames: Int) -> [Float] {
    var out: [Float] = []
    for k in 0..<seekFade {
        for c in 0..<2 { out.append(old(k, c) * RenderSource.seekFadeGain(k, of: seekFade)) }
    }
    for k in 0..<frames {
        for c in 0..<2 { out.append(k < seekFade ? new(k, c) * (Float(k) / Float(seekFade)) : new(k, c)) }
    }
    return out
}

/// Waits until every call queued on the player's engine has run, a switch's re-cue check among them.
@MainActor
private func drained(_ player: Player) async {
    await player.currentEngine?.enqueue { _ in }.value
}

// MARK: - Rigs

@MainActor
private final class QuietNowPlaying: NowPlayingPublishing {
    var onCommand: ((RemoteCommand) -> Void)?
    func show(_ item: QueueItem, elapsed: Duration, playing: Bool) {}
    func clear() {}
}

/// Pulls from `output` the way the render thread would, for both rigs.
@MainActor
private final class Puller {
    let output: FakeOutput
    private(set) var pulled = 0

    init(_ output: FakeOutput) {
        self.output = output
    }

    @discardableResult
    func pullOnce(_ frames: Int = 512) -> Int {
        let n = output.pull(frames: frames)
        pulled += n
        return n
    }

    /// Pulls until exactly `target` real frames have been pulled in all.
    func pull(upTo target: Int) async -> Bool {
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(10))
        while pulled < target {
            guard ContinuousClock.now < deadline else { return false }
            if pullOnce(min(512, target - pulled)) == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
        return true
    }

    /// Pulls until `done()` holds.
    func pump(until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(10))
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

/// A player on a `FakeOutput`.
@MainActor
private final class PlayerRig {
    let output = FakeOutput()
    let player: Player
    let puller: Puller

    init() {
        let output = output
        puller = Puller(output)
        player = Player(
            session: FakeSession(), makeOutput: { output }, capabilities: OutputCapabilities(int32Passthrough: false),
            nowPlaying: QuietNowPlaying(), makeDecoder: decoder)
    }
}

/// A bare pipeline on a `FakeOutput`, with no Sound chain: what the decode thread writes is what is captured.
@MainActor
private final class PipelineRig {
    let output = FakeOutput()
    let pipeline: PlaybackPipeline
    let puller: Puller

    init(int32Passthrough: Bool = false) {
        puller = Puller(output)
        pipeline = PlaybackPipeline(
            output: output, capabilities: OutputCapabilities(int32Passthrough: int32Passthrough),
            negotiateRate: { $0 }, makeDecoder: decoder)
    }

    deinit {
        pipeline.stop()
    }
}

private func playback(_ id: String, gainDb: Double) -> PlaybackItem {
    PlaybackItem(
        id: id, url: URL(fileURLWithPath: "/dev/null"), format: HashDecoder.format, totalFrames: HashDecoder.frames,
        gainDb: gainDb)
}

// MARK: - Tests

/// ReplayGain in playback (Plan 4 Task 12): a static gain per item, applied on the decode thread in the Float32
/// conversion, ahead of the Sound chain, so the limiter sees the gained signal. Pure ignores it.
///
/// Serialized: the playing tests run decode threads and a pull loop on wall-clock deadlines.
@MainActor @Suite(.serialized) struct ReplayGainTests {
    // MARK: The brief's five

    /// A −6.02 dB track gain on a fixture halves every sample, through the player and the limiter that joins
    /// ReplayGain. The limiter is transparent this far below its ceiling, so it only delays, by its look-ahead.
    @Test func tagGainApplied() async {
        let f = Fixtures.named("s24-48000")
        let settings = sound(.track)
        let rig = PlayerRig()
        rig.player.setSound(settings)
        await rig.player.play([fixtureItem("s24-48000", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.pump { rig.player.status == .ended }, "status: \(rig.player.status)")
        let latency = SoundChain(settings, sampleRate: 48_000, channels: 2).latencyFrames
        let source = Fixtures.rawSamples(f).map { Double($0) * 0x1p-23 }
        let got = rig.output.capturedFloat
        #expect(got.count == source.count)
        #expect(got.prefix(2 * latency).allSatisfy { $0 == 0 })
        let compared = source.count - 2 * latency
        let worst = (0..<compared).map { abs(Double(got[$0 + 2 * latency]) - source[$0] * 0.5) }.max() ?? 1
        #expect(worst < 1e-6, "largest error \(worst)")
        #expect(rig.output.plans == [floatPlan(48_000)])
    }

    /// Album mode takes the album's gain, track mode the track's: the tag, else the album measured as a whole. With no
    /// album value (no album tag, and no current album measurement) album mode falls back to the track's value.
    @Test func albumModeUsesAlbumGain() {
        let tagged = track(TrackLoudness(trackGainDb: -3, trackPeak: 0.5, albumGainDb: -7, albumPeak: 0.6))
        #expect(Player.replayGainDb(for: tagged, settings: ReplayGainSettings(mode: .album)) == -7)
        #expect(Player.replayGainDb(for: tagged, settings: ReplayGainSettings(mode: .track)) == -3)

        let measured = track(
            TrackLoudness(measuredLufs: -12, measuredPeak: 0.5, albumMeasuredLufs: -10, albumMeasuredPeak: 0.6))
        #expect(Player.replayGainDb(for: measured, settings: ReplayGainSettings(mode: .album)) == -8)
        #expect(Player.replayGainDb(for: measured, settings: ReplayGainSettings(mode: .track)) == -6)

        // The album tag outranks the album's measurement.
        let both = track(TrackLoudness(albumGainDb: -7, albumMeasuredLufs: -10, albumMeasuredPeak: 0.6))
        #expect(Player.replayGainDb(for: both, settings: ReplayGainSettings(mode: .album)) == -7)

        // No album value: the track's tag, else its measurement.
        let alone = track(TrackLoudness(trackGainDb: -3, measuredLufs: -12, measuredPeak: 0.5))
        #expect(Player.replayGainDb(for: alone, settings: ReplayGainSettings(mode: .album)) == -3)
        let untagged = track(TrackLoudness(measuredLufs: -12, measuredPeak: 0.5))
        #expect(Player.replayGainDb(for: untagged, settings: ReplayGainSettings(mode: .album)) == -6)
    }

    /// No tags: the measured loudness against the reference, RG 2.0's −18 LUFS by default (ruling R4-7), so a
    /// −14 LUFS track gets −4 dB. A track measured with no usable loudness (silent, or under one 400 ms gating block:
    /// `measuredLufs` nil, `measuredPeak` set) gets no gain from it, nor does one nothing is known about. Tags, which are
    /// RG 2.0 values already, outrank the measurement and are never re-referenced.
    @Test func measuredFallback() {
        let measured = track(TrackLoudness(measuredLufs: -14, measuredPeak: 0.8))
        #expect(Player.replayGainDb(for: measured, settings: ReplayGainSettings(mode: .track)) == -4)
        #expect(
            Player.replayGainDb(for: measured, settings: ReplayGainSettings(mode: .track, referenceLufs: -23)) == -9)

        let tagged = track(TrackLoudness(trackGainDb: -2.5, measuredLufs: -14, measuredPeak: 0.8))
        #expect(Player.replayGainDb(for: tagged, settings: ReplayGainSettings(mode: .track)) == -2.5)
        #expect(
            Player.replayGainDb(for: tagged, settings: ReplayGainSettings(mode: .track, referenceLufs: -23)) == -2.5)

        let silent = track(TrackLoudness(measuredPeak: 0))
        #expect(Player.replayGainDb(for: silent, settings: ReplayGainSettings(mode: .track)) == 0)
        #expect(Player.replayGainDb(for: track(nil), settings: ReplayGainSettings(mode: .track)) == 0)
        #expect(Player.replayGainDb(for: track(TrackLoudness()), settings: ReplayGainSettings(mode: .album)) == 0)

        // The preamp adds to whichever gain was found, the measured one included.
        #expect(Player.replayGainDb(for: measured, settings: ReplayGainSettings(mode: .track, preampDb: 3)) == -1)
        // Off is no gain at all, preamp or not.
        #expect(Player.replayGainDb(for: measured, settings: ReplayGainSettings(mode: .off, preampDb: 3)) == 0)
    }

    /// With clipping prevention (the default), the gain is capped so the peak lands at full scale: +6 dB on a track
    /// that peaks at 0.9 becomes +0.915 dB (−20·log10 0.9). The tag peak, else the measured true peak; the album's in
    /// album mode. A cap only ever lowers a gain, and with no peak known there is none.
    @Test func clippingPrevented() {
        let loud = track(TrackLoudness(trackGainDb: 6, trackPeak: 0.9))
        let capped = Player.replayGainDb(for: loud, settings: ReplayGainSettings(mode: .track))
        #expect(abs(capped - 0.915) < 0.0005, "\(capped) dB")
        #expect(abs(capped + 20 * log10(0.9)) < 1e-12)
        #expect(Player.replayGainDb(for: loud, settings: ReplayGainSettings(mode: .track, preventClipping: false)) == 6)

        // The preamp counts before the cap.
        let preamp = Player.replayGainDb(
            for: track(TrackLoudness(trackGainDb: -3, trackPeak: 0.9)), settings: .init(mode: .track, preampDb: 9))
        #expect(abs(preamp - capped) < 1e-12)

        // No tag peak: the measured true peak.
        let measuredPeak = track(TrackLoudness(trackGainDb: 6, measuredLufs: -24, measuredPeak: 0.9))
        #expect(
            abs(Player.replayGainDb(for: measuredPeak, settings: ReplayGainSettings(mode: .track)) - capped) < 1e-12)
        // The tag peak wins over the measured one.
        let bothPeaks = track(TrackLoudness(trackGainDb: 6, trackPeak: 0.9, measuredLufs: -24, measuredPeak: 0.5))
        #expect(abs(Player.replayGainDb(for: bothPeaks, settings: ReplayGainSettings(mode: .track)) - capped) < 1e-12)

        // Album mode caps by the album's peak, and by the track's when the album has none.
        let album = track(TrackLoudness(trackGainDb: 6, trackPeak: 0.5, albumGainDb: 6, albumPeak: 0.9))
        #expect(abs(Player.replayGainDb(for: album, settings: ReplayGainSettings(mode: .album)) - capped) < 1e-12)
        let albumWithoutPeak = track(TrackLoudness(trackGainDb: 0, trackPeak: 0.9, albumGainDb: 6))
        let fallback = Player.replayGainDb(for: albumWithoutPeak, settings: ReplayGainSettings(mode: .album))
        #expect(abs(fallback - capped) < 1e-12)

        // A quiet gain is never raised to the cap, and no peak means no cap.
        let quiet = track(TrackLoudness(trackGainDb: -3, trackPeak: 1.2))
        #expect(Player.replayGainDb(for: quiet, settings: ReplayGainSettings(mode: .track)) == -3)
        #expect(Player.replayGainDb(for: track(TrackLoudness(trackGainDb: 6)), settings: .init(mode: .track)) == 6)
        // A silent track's measured peak of 0 caps nothing.
        let silent = track(TrackLoudness(trackGainDb: 6, measuredPeak: 0))
        #expect(Player.replayGainDb(for: silent, settings: ReplayGainSettings(mode: .track)) == 6)
    }

    /// Pure ignores ReplayGain whatever its settings say, and so does ReplayGain off with Pure off: no gain, no
    /// multiply, the plan unchanged. The capture of `PlayerTests.resumeContinuesFromPausedFrameBitExact` (play, pause at
    /// 1500 frames, resume, play out) is bit-identical to the source, and the strip says Pure.
    @Test func pureIgnoresGain() async {
        let f = Fixtures.named("s24-48000")
        let loudness = TrackLoudness(trackGainDb: halfDb, trackPeak: 0.5, albumGainDb: halfDb, albumPeak: 0.5)
        var pure = sound(.track) { $0.preampDb = 6 }
        pure.pure = true
        let off = sound(.off) { $0.preampDb = 6 }
        for settings in [pure, off] {
            let item = fixtureItem("s24-48000", loudness: loudness)
            #expect(Player.replayGainDb(for: item, sound: settings) == 0)
            let rig = PlayerRig()
            rig.player.setSound(settings)
            await rig.player.play([item], startingAt: 0)
            #expect(await rig.puller.eventually { rig.player.status == .playing })
            #expect(rig.player.signal.activeProcessing.isEmpty)
            #expect(await rig.puller.pull(upTo: 1500))
            rig.player.pause()
            #expect(rig.player.position == .microseconds(31_250))
            rig.player.resume()
            #expect(await rig.puller.eventually { rig.player.status == .playing })
            #expect(await rig.puller.pump { rig.player.status == .ended })
            let want = Fixtures.rawSamples(f).map { Float($0) * 0x1p-23 }
            #expect(mismatch(rig.output.capturedFloat, want) == nil)
            #expect(rig.output.plans == [floatPlan(48_000), floatPlan(48_000)])
            #expect(rig.player.signal.indicator == .pure)
        }
    }

    // MARK: Per item, and when a change applies

    /// Each item plays at its own gain from its first sample, across a gapless join: a halved fixture, then the same
    /// fixture untouched, in one plan. The pipeline reports the gain of what renders.
    @Test func gainFollowsEachItem() async {
        let f = Fixtures.named("s24-48000")
        let raw = Fixtures.rawSamples(f)
        let rig = PipelineRig()
        var halved = fixtureItem("s24-48000", id: "a", loudness: nil).playbackItem
        halved.gainDb = halfDb
        let untouched = fixtureItem("s24-48000", id: "b", loudness: nil).playbackItem
        await rig.pipeline.start([halved, untouched], at: 0, fromFrame: 0)
        #expect(await rig.puller.pull(upTo: 1024))
        #expect(rig.pipeline.renderingGain?.index == 0)
        #expect(rig.pipeline.renderingGain?.gainDb == halfDb)
        #expect(await rig.puller.pull(upTo: 8192))
        let want = raw.map { Float($0) * 0x1p-24 } + raw.map { Float($0) * 0x1p-23 }
        #expect(mismatch(rig.output.capturedFloat, want) == nil)
        #expect(rig.output.plans == [floatPlan(48_000)])
        #expect(rig.pipeline.renderingGain?.index == 1)
        #expect(rig.pipeline.renderingGain?.gainDb == 0)
    }

    /// A gain change never touches the item playing: it plays out at the gain it started with, and the change applies
    /// from the next item, at its first sample.
    @Test func aChangeWaitsForTheNextItem() async {
        let rig = PipelineRig()
        await rig.pipeline.start(
            [playback("hash-a", gainDb: halfDb), playback("hash-b", gainDb: halfDb)], at: 0, fromFrame: 0)
        #expect(await rig.puller.pull(upTo: 2048))
        rig.pipeline.setGains(["hash-a": 0, "hash-b": 0])
        let frames = Int(HashDecoder.frames)
        #expect(await rig.puller.pull(upTo: 2 * frames))
        var want: [Float] = []
        for n in 0..<Int64(frames) { for c in 0..<2 { want.append(HashDecoder.float(n, channel: c, gain: 0.5)) } }
        for n in 0..<Int64(frames) { for c in 0..<2 { want.append(HashDecoder.float(n, channel: c)) } }
        #expect(mismatch(rig.output.capturedFloat, want) == nil)
        #expect(rig.pipeline.renderingGain?.index == 1)
        #expect(rig.pipeline.renderingGain?.gainDb == 0)
    }

    /// A seek applies a gain change at once, from the first frame at the new position. What played before the seek
    /// kept the gain it was decoded with, its fade-out included.
    @Test func aSeekAppliesTheChange() async {
        let rig = PipelineRig()
        await rig.pipeline.start([playback("hash-a", gainDb: halfDb)], at: 0, fromFrame: 0)
        #expect(await rig.puller.pull(upTo: 4096))
        rig.pipeline.setGains(["hash-a": 0])
        #expect(await rig.puller.pull(upTo: 8192))
        await letTheRingFill()
        await rig.pipeline.seek(toFrame: 40_000)
        let after = Int(HashDecoder.frames) - 40_000
        #expect(await rig.puller.pull(upTo: 8192 + seekFade + after))
        var want: [Float] = []
        for n in 0..<Int64(8192) { for c in 0..<2 { want.append(HashDecoder.float(n, channel: c, gain: 0.5)) } }
        want += dip(
            old: { HashDecoder.float(8192 + Int64($0), channel: $1, gain: 0.5) },
            new: { HashDecoder.float(40_000 + Int64($0), channel: $1) }, frames: after)
        #expect(mismatch(rig.output.capturedFloat, want) == nil)
        #expect(rig.pipeline.renderingGain?.gainDb == 0)
    }

    /// The player recomputes the queue's gains when the settings change, and they apply on a seek: switched from
    /// track mode (this track's own gain is 0 dB) to album mode (its album's is −6.02 dB) mid-play, the track keeps
    /// its level until the seek, and is halved from the first frame after it.
    @Test func playerAppliesNewSettingsOnASeek() async {
        let rig = PlayerRig()
        let settings = sound(.track)
        rig.player.setSound(settings)
        let loudness = TrackLoudness(trackGainDb: 0, albumGainDb: halfDb)
        await rig.player.play([hashItem("hash-q", loudness: loudness)], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 4096))
        rig.player.setSound(sound(.album))
        await drained(rig.player)
        #expect(rig.player.recueCount == 0, "a change of mode is no switch: no re-cue")
        #expect(await rig.puller.pull(upTo: 16_384))
        // The limiter that joins ReplayGain only delays here, by its look-ahead: the level stays far below its
        // ceiling. Swapping it for the album mode's chain (the same blocks) cross-fades two equal outputs.
        let latency = SoundChain(settings, sampleRate: 48_000, channels: 2).latencyFrames
        let before = rig.output.capturedFloat
        let worstBefore =
            (0..<(16_384 - latency)).map { n in
                abs(before[2 * (n + latency)] - HashDecoder.float(Int64(n), channel: 0))
            }.max() ?? 1
        #expect(worstBefore < 1e-6, "the playing item changed level before the seek: \(worstBefore)")

        await letTheRingFill()
        await rig.player.seek(to: .milliseconds(500))
        let target = 24_000
        #expect(await rig.puller.pull(upTo: 16_384 + seekFade + 8_192))
        // First the fade-out of what was playing, then the new position: its first `latency` frames are what the
        // look-ahead held from the gap, and its first `seekFade` fade in.
        let after = Array(rig.output.capturedFloat[(2 * (16_384 + seekFade))...])
        let worstAfter =
            (seekFade..<(8_192 - latency)).map { n in
                abs(after[2 * (n + latency)] - HashDecoder.float(Int64(target + n), channel: 0, gain: 0.5))
            }.max() ?? 1
        #expect(worstAfter < 1e-6, "the seek did not apply the new gain: \(worstAfter)")
        rig.player.pause()
    }

    // MARK: Switches heard at once (ruling R4-T12a)

    /// Pure set while an item plays at a gain re-cues it where it is: within one buffer of the re-cue's audio, the
    /// capture is the ungained source, to the bit, from the frame playback had reached. (Before it, the fade-out of
    /// what was playing; that buffer holds the re-cue's fade-in and the chain's fade out to Pure.)
    @Test func pureTakesEffectAtOnce() async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.track))
        await rig.player.play([hashItem("hash-p", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 4096))
        await letTheRingFill()
        rig.player.setSound(SoundSettings())
        // The re-cue reaches the pipeline through the engine's queue; nothing renders meanwhile.
        await drained(rig.player)
        #expect(rig.player.recueCount == 1)
        #expect(await rig.puller.pull(upTo: 4096 + seekFade + 8192))
        let captured = rig.output.capturedFloat
        var got: [Float] = []
        var want: [Float] = []
        for n in Int64(512)..<8192 {
            for c in 0..<2 {
                got.append(captured[2 * (4096 + seekFade + Int(n)) + c])
                want.append(HashDecoder.float(4096 + n, channel: c))
            }
        }
        #expect(mismatch(got, want) == nil)
        #expect(rig.player.pipeline?.renderingGain?.gainDb == 0)
        #expect(await rig.puller.eventually { rig.player.signal.indicator == .pure })
        #expect(rig.player.status == .playing)
        rig.player.pause()
    }

    /// ReplayGain switched on (from off) while an item plays re-cues it too: within a buffer and the limiter's
    /// look-ahead, the item plays halved. Switched off again, it re-cues back to the source's level.
    @Test func replayGainOnTakesEffectAtOnce() async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.off))
        await rig.player.play([hashItem("hash-o", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 4096))
        await letTheRingFill()
        let settings = sound(.track)
        rig.player.setSound(settings)
        await drained(rig.player)
        #expect(rig.player.recueCount == 1)
        #expect(await rig.puller.pull(upTo: 4096 + seekFade + 8192))
        let latency = SoundChain(settings, sampleRate: 48_000, channels: 2).latencyFrames
        let captured = rig.output.capturedFloat
        // Past the fade-out of what was playing, the fade-in, the chain's priming and its fade in: the halved source,
        // delayed by the look-ahead.
        let base = 4096 + seekFade
        let worst =
            (1024..<8192).map { k in
                abs(captured[2 * (base + k)] - HashDecoder.float(Int64(4096 + k - latency), channel: 0, gain: 0.5))
            }.max() ?? 1
        #expect(worst < 1e-6, "not halved after the re-cue: \(worst)")
        #expect(rig.player.pipeline?.renderingGain?.gainDb == halfDb)
        #expect(await rig.puller.eventually { rig.player.signal.activeProcessing == ["ReplayGain", "Limiter"] })

        rig.player.setSound(sound(.off))
        await drained(rig.player)
        #expect(rig.player.recueCount == 2)
        #expect(await rig.puller.pull(upTo: rig.puller.pulled + 2048))
        #expect(rig.player.pipeline?.renderingGain?.gainDb == 0)
        rig.player.pause()
    }

    /// A switch that leaves the playing item's gain as it was re-cues nothing, so there is no gap: Pure toggled with
    /// ReplayGain off (the capture stays the source, bit for bit, throughout), and ReplayGain switched on and off for
    /// an item that gets 0 dB either way.
    @Test func aSwitchThatChangesNoGainDoesNotRecue() async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.off))
        await rig.player.play([hashItem("hash-s", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 4096))
        rig.player.setSound(SoundSettings())
        await drained(rig.player)
        #expect(await rig.puller.pull(upTo: 8192))
        rig.player.setSound(sound(.off))
        await drained(rig.player)
        #expect(rig.player.recueCount == 0)
        #expect(await rig.puller.pull(upTo: 16_384))
        var want: [Float] = []
        for n in Int64(0)..<16_384 { for c in 0..<2 { want.append(HashDecoder.float(n, channel: c)) } }
        #expect(mismatch(rig.output.capturedFloat, want) == nil)

        await rig.player.play([hashItem("hash-z", loudness: nil)], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        rig.player.setSound(sound(.track))
        await drained(rig.player)
        rig.player.setSound(sound(.off))
        await drained(rig.player)
        #expect(rig.player.recueCount == 0)
        rig.player.pause()
    }

    /// A re-cue is a seek: what was playing fades out over `RenderSource.crossfadeSeconds` (288 frames at 48 kHz) on
    /// the raised cosine, and the re-cued audio fades in from silence over as long, linearly, so it never starts with
    /// a step; past the ramp every sample is the source's at its new gain, exactly. A seek (`aSeekAppliesTheChange`)
    /// dips the same way.
    @Test func recueFadesIn() async {
        let rig = PipelineRig()
        await rig.pipeline.start([playback("hash-r", gainDb: halfDb)], at: 0, fromFrame: 0)
        #expect(await rig.puller.pull(upTo: 4096))
        await letTheRingFill()
        rig.pipeline.setGains(["hash-r": 0])
        await rig.pipeline.recue(toFrame: 4096, firstFrame: FirstFrameInterval(.seek))
        #expect(await rig.puller.pull(upTo: 8192 + seekFade))
        let ramp = Int((RenderSource.crossfadeSeconds * 48_000).rounded())
        #expect(ramp == 288 && seekFade == ramp)
        var want: [Float] = []
        for n in Int64(0)..<4096 { for c in 0..<2 { want.append(HashDecoder.float(n, channel: c, gain: 0.5)) } }
        for k in 0..<ramp {
            let gain = RenderSource.seekFadeGain(k, of: ramp)
            for c in 0..<2 { want.append(HashDecoder.float(Int64(4096 + k), channel: c, gain: 0.5) * gain) }
        }
        for k in 0..<4096 {
            let weight: Float = k < ramp ? Float(k) / Float(ramp) : 1
            for c in 0..<2 {
                let sample = HashDecoder.float(Int64(4096 + k), channel: c)
                want.append(k < ramp ? sample * weight : sample)
            }
        }
        #expect(mismatch(rig.output.capturedFloat, want) == nil)
    }

    /// Values that are not finite count as absent, and the gain is bounded at ±`Player.maxGainDb` (75 dB, the
    /// largest tag plus the largest preamp): a corrupt saved reference can never overflow the scale.
    @Test func gainsStayFiniteAndBounded() {
        let measured = track(TrackLoudness(measuredLufs: -14, measuredPeak: 0.8))
        let unguarded = ReplayGainSettings(mode: .track, preventClipping: false, referenceLufs: 900)
        #expect(Player.replayGainDb(for: measured, settings: unguarded) == Player.maxGainDb)
        let negative = ReplayGainSettings(mode: .track, referenceLufs: -900)
        #expect(Player.replayGainDb(for: measured, settings: negative) == -Player.maxGainDb)
        #expect(Player.maxGainDb == 75)
        // A reference that is not finite is the default's, and a preamp that is not finite adds nothing.
        #expect(
            Player.replayGainDb(for: measured, settings: ReplayGainSettings(mode: .track, referenceLufs: .nan)) == -4)
        #expect(Player.replayGainDb(for: measured, settings: ReplayGainSettings(mode: .track, preampDb: .nan)) == -4)
        // Loudness values that are not finite are no values.
        let odd = track(TrackLoudness(trackGainDb: .nan, trackPeak: .infinity, measuredLufs: -14, measuredPeak: 0.8))
        #expect(Player.replayGainDb(for: odd, settings: ReplayGainSettings(mode: .track)) == -4)
        let infinite = track(TrackLoudness(trackGainDb: .infinity, albumGainDb: -.infinity, measuredLufs: -.infinity))
        #expect(Player.replayGainDb(for: infinite, settings: ReplayGainSettings(mode: .track)) == 0)
        #expect(Player.replayGainDb(for: infinite, settings: ReplayGainSettings(mode: .album)) == 0)
    }

    /// Ruling R4-T12b: a switch reaches an item already joined behind the playing one in the ring, not only the one
    /// rendering. Two items, the second halved; Pure is set in the first item's last half second, once the decode
    /// thread has entered the second. Playback is re-cued (the ring flushed, the second item with it), and the second
    /// item plays bit-exact with its ungained source. The first item is halved too in one case and gets 0 dB in the
    /// other, where it alone would need no re-cue.
    @Test(arguments: [halfDb, 0])
    func aSwitchReachesAJoinedItem(firstGainDb: Double) async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.track))
        let items = [
            hashItem("hash-1", loudness: TrackLoudness(trackGainDb: firstGainDb)),
            hashItem("hash-2", loudness: TrackLoudness(trackGainDb: halfDb)),
        ]
        await rig.player.play(items, startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        let frames = Int(HashDecoder.frames)
        #expect(await rig.puller.pull(upTo: frames - 12_000))
        // The ring holds half a second: the decode thread runs on into the second item.
        #expect(await rig.puller.eventually { rig.player.pipeline?.enteredGains.map(\.index) == [0, 1] })
        #expect(rig.player.pipeline?.enteredGains.map(\.gainDb) == [firstGainDb, halfDb])
        #expect(rig.player.pipeline?.renderingGain?.index == 0)
        rig.player.setSound(SoundSettings())
        await drained(rig.player)
        #expect(rig.player.recueCount == 1)
        #expect(await rig.puller.pump { rig.player.status == .ended })
        // Both items, and the fade-out of what was playing at the re-cue, which then replays from where it began.
        let captured = rig.output.capturedFloat
        #expect(captured.count == 2 * (2 * frames + seekFade))
        var want: [Float] = []
        for n in Int64(0)..<HashDecoder.frames { for c in 0..<2 { want.append(HashDecoder.float(n, channel: c)) } }
        #expect(mismatch(Array(captured[(2 * (frames + seekFade))...]), want) == nil)
    }

    /// Ruling R4-T12b across a boundary that is not gapless (re-review N1): a 48 kHz item at 0 dB, then a halved
    /// 44.1 kHz one. In the first item's last half second the decode thread has opened the second and waits for the
    /// ring to drain before it reconfigures; Pure set then reaches the second item, which takes its gain only once
    /// entered, after the reconfigure: it plays bit-exact with its ungained source.
    @Test func aSwitchReachesAnItemBehindARateChange() async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.track))
        let items = [
            hashItem("hash-48", loudness: TrackLoudness(trackGainDb: 0)),
            hashItem("hash44-n1", loudness: TrackLoudness(trackGainDb: halfDb)),
        ]
        await rig.player.play(items, startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        let frames = Int(HashDecoder.frames)
        #expect(await rig.puller.pull(upTo: frames - 12_000))
        // The decode thread has written out the first item and opened the second, and is draining the ring.
        #expect(await rig.puller.eventually { opened.withLock { $0.contains("hash44-n1") } })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.player.pipeline?.enteredGains.map(\.index) == [0])
        rig.player.setSound(SoundSettings())
        await drained(rig.player)
        #expect(await rig.puller.pump { rig.player.status == .ended })
        #expect(rig.output.plans.map(\.clientSampleRate) == [48_000, 44_100])
        let captured = rig.output.capturedFloat
        #expect(captured.count == 2 * 2 * frames)
        var want: [Float] = []
        for n in Int64(0)..<HashDecoder.frames { for c in 0..<2 { want.append(HashDecoder.float(n, channel: c)) } }
        #expect(mismatch(Array(captured[(2 * frames)...]), want) == nil)
    }

    /// Re-review N2: once a switch has queued its chain change behind a re-cue's hold, a later change that is no
    /// switch (an EQ edit) waits behind the hold too; the queued call then hands the pipeline the latest settings.
    @Test func aChainChangeAfterASwitchStaysBehindTheHold() async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.off))
        await rig.player.play([hashItem("hash-h", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 4096))
        rig.player.setSound(sound(.track))
        var withEQ = sound(.track)
        withEQ.eq = EQSettings(
            enabled: true, mode: .parametric, bands: [EQBand(type: .peak, frequency: 1_000, gainDb: 3, q: 1.41)])
        rig.player.setSound(withEQ)
        // Neither has reached the pipeline: the chain is still ReplayGain off's, until the hold is in place.
        #expect(rig.player.pipeline?.soundSettings == sound(.off).clamped())
        await drained(rig.player)
        #expect(rig.player.recueCount == 1)
        #expect(rig.player.pipeline?.soundSettings == withEQ.clamped())
        #expect(rig.player.currentEngine?.soundAppliesPending == 0)
        rig.player.pause()
    }

    /// Review M2: a switch while a seek is still counted as on its way (the decode thread may have taken it at the old
    /// gains before the main actor heard back) is checked behind it on the engine's queue, not dropped. The re-cue
    /// goes to the seek's target, where the playhead is: from one buffer after it, the ungained source from there.
    @Test func aSwitchWhileASeekIsInFlightIsStillChecked() async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.track))
        await rig.player.play([hashItem("hash-f", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 4096))
        guard let engine = rig.player.currentEngine, let pipeline = rig.player.pipeline else {
            Issue.record("no engine")
            return
        }
        // A real seek, which sets the cue; render calls of one frame let the decode thread take it, at the old gain,
        // and stop as soon as it has entered the item there, before any of its audio is rendered.
        await rig.player.seek(to: .milliseconds(500))
        let target: Int64 = 24_000
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(5))
        while pipeline.enteredGains.isEmpty, ContinuousClock.now < deadline {
            rig.puller.pullOnce(1)
            try? await Task.sleep(for: .microseconds(200))
        }
        #expect(pipeline.enteredGains.first?.gainDb == halfDb)
        #expect(pipeline.position == (0, target))
        // The main actor has not heard back yet: the seek's count still stands, as `seek(to:)` holds it.
        engine.seeksInFlight += 1
        rig.player.setSound(SoundSettings())
        await drained(rig.player)
        #expect(rig.player.recueCount == 1)
        engine.seeksInFlight -= 1
        let base = rig.output.capturedFloat.count / 2
        #expect(await rig.puller.pull(upTo: rig.puller.pulled + 4096))
        let captured = rig.output.capturedFloat
        var got: [Float] = []
        var want: [Float] = []
        for k in Int64(512)..<4096 {
            for c in 0..<2 {
                got.append(captured[2 * (base + Int(k)) + c])
                want.append(HashDecoder.float(target + k, channel: c))
            }
        }
        #expect(mismatch(got, want) == nil)
        #expect(pipeline.renderingGain?.gainDb == 0)
        rig.player.pause()
    }

    /// Review M3: a switch while a finger is on the record re-cues nothing under the finger; at the let-go it is
    /// checked again. Let go before any render call, no voice ever started and the let-go seeks nothing, so the check
    /// re-cues: from one buffer after it, the item plays bit-exact with its ungained source.
    @Test func aSwitchDuringAScrubIsCheckedAtTheLetGo() async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.track))
        await rig.player.play([hashItem("hash-c", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: 8192))
        await letTheRingFill()
        #expect(rig.player.beginScrub())
        rig.player.setSound(SoundSettings())
        await drained(rig.player)
        #expect(rig.player.recueCount == 0, "nothing is re-cued under the finger")
        await rig.player.endScrub(spinUpSeconds: 0.01).value
        #expect(!rig.player.isScrubbing)
        await drained(rig.player)
        #expect(rig.player.recueCount == 1)
        #expect(await rig.puller.pull(upTo: 8192 + seekFade + 4096))
        #expect(rig.player.pipeline?.renderingGain?.gainDb == 0)
        // After the fade-out of what was playing: no voice ever started, so that was the ring.
        let captured = rig.output.capturedFloat
        var got: [Float] = []
        var want: [Float] = []
        for n in Int64(512)..<4096 {
            for c in 0..<2 {
                got.append(captured[2 * (8192 + seekFade + Int(n)) + c])
                want.append(HashDecoder.float(8192 + n, channel: c))
            }
        }
        #expect(mismatch(got, want) == nil)
        rig.player.pause()
    }

    // MARK: The strip

    /// The strip lists ReplayGain exactly while a non-zero gain applies to the item playing, and says Processing
    /// then. An item that gets no gain shows only the limiter that ReplayGain brings into the chain. A switch to Pure
    /// while an item plays re-cues it at once (ruling R4-T12a); until the decode thread has taken the re-cue, the gain
    /// is still on and the strip says so, and it says Pure once the item plays ungained.
    @Test func stripListsReplayGainOnlyWhileItApplies() async {
        let rig = PlayerRig()
        rig.player.setSound(sound(.track))
        await rig.player.play([hashItem("hash-g", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(rig.player.signal.activeProcessing == ["ReplayGain", "Limiter"])
        #expect(rig.player.signal.indicator == .processing(2))

        await rig.player.play([hashItem("hash-n", loudness: nil)], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(rig.player.signal.activeProcessing == ["Limiter"])
        #expect(rig.player.signal.indicator == .processing(1))
        // A preamp is a gain on its own.
        rig.player.setSound(sound(.track) { $0.preampDb = 3 })
        #expect(rig.player.signal.activeProcessing == ["Limiter"], "the playing item keeps its gain, 0 dB")
        await rig.player.play([hashItem("hash-n", loudness: nil)], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(rig.player.signal.activeProcessing == ["ReplayGain", "Limiter"])

        // Pure mid-play: re-cued at once, and the strip never says Pure while the gain is still on.
        await rig.player.play([hashItem("hash-g", loudness: TrackLoudness(trackGainDb: halfDb))], startingAt: 0)
        #expect(await rig.puller.eventually { rig.player.status == .playing })
        #expect(await rig.puller.pull(upTo: rig.puller.pulled + 2048))
        rig.player.setSound(SoundSettings())
        #expect(rig.player.signal.activeProcessing == ["ReplayGain"])
        #expect(rig.player.signal.indicator == .processing(1))
        // Some audio after the re-cue, then the position updates (10 Hz) show what the decode thread took.
        await drained(rig.player)
        #expect(rig.player.recueCount == 1)
        #expect(await rig.puller.pull(upTo: rig.puller.pulled + 2048))
        #expect(rig.player.pipeline?.renderingGain?.gainDb == 0)
        #expect(await rig.puller.eventually { rig.player.signal.indicator == .pure })
        #expect(rig.player.status == .playing)
        #expect(rig.player.pipeline?.renderingGain?.gainDb == 0)
        rig.player.pause()
        #expect(rig.player.signal.indicator == .pure)
    }

    // MARK: The plan

    /// A gain is a multiply in Float32, so with Int32 passthrough a 32-bit source with a gain plays through a Float32
    /// client instead, TPDF-dithered to 24 bits first, which the strip then shows; with no gain it stays on Int32, and
    /// a 24-bit source's plan never changes. Dither, then gain: the capture is `TPDFDither(seed:)` over the source,
    /// halved, to the bit.
    @Test func gainTakes32BitSourcesOffInt32() async {
        let deep = AudioFormat(sampleRate: 48_000, bitsPerSample: 32, channels: 2)
        let shallow = AudioFormat(sampleRate: 48_000, bitsPerSample: 24, channels: 2)
        let passthrough = OutputCapabilities(int32Passthrough: true)
        func plan(_ format: AudioFormat, _ gainDb: Double) -> OutputPlan {
            OutputFormatPolicy.plan(source: format, hardwareRate: 48_000, capabilities: passthrough, gainDb: gainDb)
        }
        #expect(plan(deep, 0) == OutputPlan(client: .int32, clientSampleRate: 48_000, resample: nil, reduceTo24: false))
        #expect(plan(deep, halfDb) == floatPlan(48_000, reduceTo24: true))
        #expect(plan(shallow, halfDb) == floatPlan(48_000))
        #expect(plan(shallow, halfDb) == plan(shallow, 0))

        let f = Fixtures.named("s32-48000")
        let rig = PipelineRig(int32Passthrough: true)
        var item = fixtureItem("s32-48000", loudness: nil).playbackItem
        item.gainDb = halfDb
        await rig.pipeline.start([item], at: 0, fromFrame: 0)
        #expect(await rig.puller.pull(upTo: Int(f.frames)))
        #expect(rig.output.plans == [floatPlan(48_000, reduceTo24: true)])
        var dithered = Fixtures.rawSamples(f)
        var dither = TPDFDither(seed: 0x9E37_79B9_7F4A_7C15)
        dithered.withUnsafeMutableBufferPointer { dither.reduce32To24($0) }
        #expect(mismatch(rig.output.capturedFloat, dithered.map { Float($0) * 0x1p-32 }) == nil)
        #expect(SignalState(source: deep, plan: rig.output.plans.first).indicator == .depthReduced(from: 32, to: 24))
    }

    // MARK: Wiring

    /// A queue item made from a library track carries what the library knows about its loudness.
    @Test func queueItemsCarryLoudness() {
        let loudness = TrackLoudness(trackGainDb: -4, trackPeak: 0.7, measuredLufs: -13, measuredPeak: 0.8)
        let library = LibraryTrack(
            id: "t", url: URL(fileURLWithPath: "/dev/null"), title: "T", artist: "", albumArtist: "", album: "",
            albumID: "a", discNumber: nil, trackNumber: nil, year: nil, format: HashDecoder.format, totalFrames: 10,
            artworkID: nil, isInLibraryFolder: true, loudness: loudness)
        #expect(QueueItem(track: library).loudness == loudness)
        #expect(QueueItem(track: library).playbackItem.gainDb == 0)
    }
}
