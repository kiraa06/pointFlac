import Foundation
import PFCore
import PFDSP
import PFFlac
import PFTestSupport
import Synchronization
import Testing

@testable import PFAudio

// MARK: - Helpers

private func item(_ name: String, id: String? = nil) -> PlaybackItem {
    let f = Fixtures.named(name)
    return PlaybackItem(
        id: id ?? name, url: Fixtures.url(f),
        format: AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels),
        totalFrames: f.frames)
}

/// The format fixture `name` decodes to, as `.trackStarted` reports it.
private func format(_ name: String) -> AudioFormat {
    let f = Fixtures.named(name)
    return AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels)
}

/// `.trackStarted` for item `index` playing fixture `name`: its decoded format and its STREAMINFO length.
private func started(_ index: Int, _ name: String) -> PipelineEvent {
    .trackStarted(index, format(name), totalFrames: Fixtures.named(name).frames)
}

/// Native-range samples as the Float32 client receives them: v / 2^(b−1).
private func floats(_ samples: some Sequence<Int32>, bits: Int) -> [Float] {
    let scale = Float(1 << (bits - 1))
    return samples.map { Float($0) / scale }
}

/// nil when the arrays are identical; otherwise where they first differ. Floats compare by bit pattern.
private func mismatch(_ got: [Float], _ want: [Float]) -> String? {
    guard got.count == want.count else { return "count \(got.count) ≠ \(want.count)" }
    guard let i = got.indices.first(where: { got[$0].bitPattern != want[$0].bitPattern }) else { return nil }
    return "first difference at sample \(i): \(got[i]) ≠ \(want[i])"
}

private func mismatch(_ got: [Int32], _ want: [Int32]) -> String? {
    guard got.count == want.count else { return "count \(got.count) ≠ \(want.count)" }
    guard let i = got.indices.first(where: { got[$0] != want[$0] }) else { return nil }
    return "first difference at sample \(i): \(got[i]) ≠ \(want[i])"
}

private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

/// The resampler run once over the whole input: no decode-block joins at all.
private func oneShotResample(_ input: [Float], from: Int, to: Int, channels: Int) throws -> [Float] {
    let converter = try SampleRateConverter(inputRate: from, outputRate: to, channels: channels)
    var out: [Float] = []
    input.withUnsafeBufferPointer { _ = converter.process($0, frames: input.count / channels, into: &out) }
    _ = converter.flush(into: &out)
    return out
}

/// Everything libFLAC delivers for a fixture, in one read (damaged blocks come back as silence).
private func decodeAll(_ name: String) throws -> [Int32] {
    let f = Fixtures.named(name)
    let decoder = try FlacDecoder(url: Fixtures.url(f))
    var out = [Int32](repeating: 0, count: Int(f.frames) * f.channels)
    let n = try out.withUnsafeMutableBufferPointer { try decoder.read(into: $0, maxFrames: Int(f.frames)) }
    return Array(out.prefix(n * f.channels))
}

private final class EventLog: Sendable {
    private let storage = Mutex<[PipelineEvent]>([])

    var events: [PipelineEvent] { storage.withLock { $0 } }

    func append(_ event: PipelineEvent) {
        storage.withLock { $0.append(event) }
    }

    func contains(_ event: PipelineEvent) -> Bool {
        events.contains(event)
    }

    var failures: [Int] {
        events.compactMap {
            if case .itemFailed(let index, _) = $0 { return index }
            return nil
        }
    }
}

/// Delivers the first `failAfter` frames of a real file, then throws: a file deleted or evicted mid-playback.
private final class FailingDecoder: PCMDecoding {
    private let inner: FlacDecoder
    private let failAfter: Int
    private var delivered = 0

    init(_ inner: FlacDecoder, failAfter: Int) {
        self.inner = inner
        self.failAfter = failAfter
    }

    var format: AudioFormat { inner.format }
    var totalFrames: Int64 { inner.totalFrames }

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        guard delivered < failAfter else { throw FlacDecodeError.ioError }
        let n = try inner.read(into: buffer, maxFrames: min(maxFrames, failAfter - delivered))
        delivered += n
        return n
    }

    func seek(toFrame frame: Int64) throws {
        try inner.seek(toFrame: frame)
    }
}

/// A `negotiateRate` that does not answer until the test releases it, like an audio session stuck activating.
private final class StuckNegotiation: Sendable {
    private struct State {
        var entered = false
        var waiter: CheckedContinuation<Int, Never>?
        var answer: Int?
    }

    private let state = Mutex(State())

    var entered: Bool { state.withLock { $0.entered } }

    func answer() async -> Int {
        await withCheckedContinuation { continuation in
            state.withLock { s in
                s.entered = true
                if let answer = s.answer {
                    continuation.resume(returning: answer)
                } else {
                    s.waiter = continuation
                }
            }
        }
    }

    func release(_ rate: Int) {
        state.withLock { s in
            s.answer = rate
            s.waiter?.resume(returning: rate)
            s.waiter = nil
        }
    }
}

/// Wraps a decoder and records when it is deallocated, to show a stopped session let go of it.
private final class TrackedDecoder: PCMDecoding {
    final class Lifetime: Sendable {
        private let flag = Atomic<Bool>(false)
        var ended: Bool { flag.load(ordering: .acquiring) }
        func end() { flag.store(true, ordering: .releasing) }
    }

    private let inner: FlacDecoder
    private let lifetime: Lifetime

    init(_ inner: FlacDecoder, lifetime: Lifetime) {
        self.inner = inner
        self.lifetime = lifetime
    }

    deinit {
        lifetime.end()
    }

    var format: AudioFormat { inner.format }
    var totalFrames: Int64 { inner.totalFrames }

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        try inner.read(into: buffer, maxFrames: maxFrames)
    }

    func seek(toFrame frame: Int64) throws {
        try inner.seek(toFrame: frame)
    }
}

/// A pipeline wired to a `FakeOutput`, with its events collected. The test plays the render thread by pulling
/// 512-frame chunks.
private final class Rig {
    let output = FakeOutput()
    let pipeline: PlaybackPipeline
    let log = EventLog()
    private let collector: Task<Void, Never>
    /// Real frames pulled so far (the FakeOutput captures exactly these).
    private(set) var pulledFrames = 0

    /// `negotiate`, when given, replaces `hardwareRate` as the pipeline's `negotiateRate`.
    init(
        hardwareRate: @escaping @Sendable (Int) -> Int = { $0 }, int32Passthrough: Bool = false,
        ditherSeed: UInt64 = 0x9E37_79B9_7F4A_7C15, negotiate: (@Sendable (Int) async -> Int)? = nil,
        makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding = { try FlacDecoder(url: $0.url) }
    ) {
        let pipeline = PlaybackPipeline(
            output: output, capabilities: OutputCapabilities(int32Passthrough: int32Passthrough),
            negotiateRate: negotiate ?? { hardwareRate($0) }, makeDecoder: makeDecoder, ditherSeed: ditherSeed)
        self.pipeline = pipeline
        let log = self.log
        collector = Task {
            for await event in pipeline.events { log.append(event) }
        }
    }

    deinit {
        pipeline.stop()
        collector.cancel()
    }

    func play(_ items: [PlaybackItem], fromFrame: Int64 = 0) async {
        await pipeline.start(items, at: 0, fromFrame: fromFrame)
    }

    @discardableResult
    func pull(frames: Int = 512) -> Int {
        let n = output.pull(frames: frames)
        pulledFrames += n
        return n
    }

    /// Pulls until exactly `target` real frames have been pulled in all, then stops. False on timeout. Every polling
    /// helper here scales its timeout by `LatencyBudget` (×3 under CI).
    @discardableResult
    func pull(upTo target: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + LatencyBudget.scaled(timeout)
        while pulledFrames < target {
            guard clock.now < deadline else { return false }
            if pull(frames: min(512, target - pulledFrames)) == 0 {
                try? await Task.sleep(for: .microseconds(200))
            }
        }
        return true
    }

    /// Pulls until `done()` holds or the timeout passes, and returns whether it held.
    @discardableResult
    func pump(timeout: Duration = pumpTimeout, until done: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + LatencyBudget.scaled(timeout)
        while !done() {
            guard clock.now < deadline else { return false }
            if pull() == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
        return true
    }

    func playToEnd() async {
        let ended = await pump { log.contains(.queueEnded) }
        #expect(ended, "no queueEnded within \(LatencyBudget.describe(pumpTimeout)); events so far: \(log.events)")
    }
}

/// `Rig.pump`'s timeout, before `LatencyBudget` scales it.
private let pumpTimeout: Duration = .seconds(20)

/// Waits, without pulling, until `condition` holds or the timeout passes, and returns whether it held. `timeout` is a
/// budget, scaled by `LatencyBudget` (×3 under CI): pass the spec's figure, not a scaled one.
private func wait(upTo timeout: Duration, for condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + LatencyBudget.scaled(timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// A long synthetic source, so the decode thread is still busy (blocked on a full ring) when a seek arrives.
/// 16-bit stereo, ten seconds at 44.1 kHz; sample (n, c) = ((2n + c) mod 65536) − 32768.
private final class PatternDecoder: PCMDecoding {
    static let frames: Int64 = 441_000
    static let item = PlaybackItem(
        id: "pattern", url: URL(fileURLWithPath: "/dev/null"),
        format: AudioFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2), totalFrames: frames)

    static func samples(from frame: Int64, count frames: Int) -> [Int32] {
        (0..<(frames * 2)).map { Int32((2 * frame + Int64($0)) % 65_536) - 32_768 }
    }

    let format = PatternDecoder.item.format
    var totalFrames: Int64 { Self.frames }
    private var position: Int64 = 0

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        let n = Int(min(Int64(min(maxFrames, buffer.count / 2)), Self.frames - position))
        for i in 0..<(n * 2) {
            buffer[i] = Int32((2 * position + Int64(i)) % 65_536) - 32_768
        }
        position += Int64(n)
        return n
    }

    func seek(toFrame frame: Int64) throws {
        position = frame
    }
}

private func floatPlan(_ rate: Int, resample: RateChange? = nil, reduceTo24: Bool = false) -> OutputPlan {
    OutputPlan(client: .float32, clientSampleRate: rate, resample: resample, reduceTo24: reduceTo24)
}

/// What a seek puts in a Float32 client's real-frame capture after the frames pulled before it. First the ring's next
/// 6 ms, the old position's, fading out on the raised cosine (`RenderSource.seekFadeGain`); the hold's silence is not
/// captured; then the new position's audio, whose first 6 ms fade in linearly (frame k × k / their length), and from
/// there exactly as decoded. `old` and `new` are interleaved samples from those two points on.
private func seekDip(
    old: some Collection<Float>, new: some Collection<Float>, channels: Int, rate: Int
) -> [Float] {
    let fade = RenderSource.fadeFrames(atRate: rate)
    var out: [Float] = []
    for (i, x) in old.prefix(fade * channels).enumerated() {
        out.append(x * RenderSource.seekFadeGain(i / channels, of: fade))
    }
    for (i, x) in new.enumerated() {
        let k = i / channels
        out.append(k < fade ? x * (Float(k) / Float(fade)) : x)
    }
    return out
}

/// SoundChainTests' click measure: the largest step between neighbouring samples of a tone at `hz`, over the tone's
/// own steepest step at the level around it (`local`: the loudest sample in that period and its neighbours) and at
/// its loudest (`global`). A clean tone, or a smooth change of its level, stays near 1; a cut to silence mid-wave
/// reaches 1 / (2π · hz / rate).
private func largestStepRatios(_ x: [Float], channels: Int, hz: Double, rate: Double) -> (local: Double, global: Double)
{
    let omega = 2 * .pi * hz / rate
    let period = Int((rate / hz).rounded(.up))
    let frames = x.count / channels
    var local = 0.0
    var global = 0.0
    for channel in 0..<channels {
        let y = (0..<frames).map { Double(x[$0 * channels + channel]) }
        let loudest = y.map(\.magnitude).max() ?? 0
        let chunks = (frames + period - 1) / period
        var chunkPeak = [Double](repeating: 0, count: chunks)
        for n in 0..<frames { chunkPeak[n / period] = max(chunkPeak[n / period], y[n].magnitude) }
        for n in 1..<frames {
            let step = abs(y[n] - y[n - 1])
            let c = n / period
            let around = max(chunkPeak[max(c - 1, 0)], chunkPeak[c], chunkPeak[min(c + 1, chunks - 1)])
            if around > 1e-6 { local = max(local, step / (omega * around)) }
            global = max(global, step / (omega * loudest))
        }
    }
    return (local, global)
}

/// A full-scale 1 kHz sine, 24-bit stereo at 48 kHz, ten seconds long: the steadiest loud signal, on which a click
/// stands out at once.
private final class FullScaleSineDecoder: PCMDecoding {
    static let rate = 48_000
    static let hz = 1_000.0
    static let frames: Int64 = 480_000
    static let item = PlaybackItem(
        id: "sine", url: URL(fileURLWithPath: "/dev/null"),
        format: AudioFormat(sampleRate: rate, bitsPerSample: 24, channels: 2), totalFrames: frames)

    static func value(_ frame: Int64) -> Int32 {
        Int32((8_388_607 * sin(2 * .pi * hz * Double(frame) / Double(rate))).rounded())
    }

    /// Frame `frame` as the Float32 client receives it: v / 2^23.
    static func float(_ frame: Int64) -> Float {
        Float(value(frame)) * 0x1p-23
    }

    let format = FullScaleSineDecoder.item.format
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

/// An output that keeps every frame it renders, silence included (`FakeOutput` keeps only real ones), with each
/// call's first frame and its real frames: all the listener hears across a seek's gap. Float32 clients only.
private final class RecordingOutput: AudioOutput, Sendable {
    struct Call: Sendable {
        var start: Int
        var real: Int
    }

    private struct State {
        var source: RenderSource?
        var channels = 0
        var started = false
        var buffer: UnsafeMutableRawPointer?
        var stream: [Float] = []
        var calls: [Call] = []
    }

    private let state = Mutex(State())

    deinit {
        state.withLock { $0.buffer?.deallocate() }
    }

    var source: RenderSource? {
        get { state.withLock { $0.source } }
        set { state.withLock { $0.source = newValue } }
    }

    /// Every frame rendered, interleaved.
    var stream: [Float] { state.withLock { $0.stream } }
    var calls: [Call] { state.withLock { $0.calls } }

    func configure(_ plan: OutputPlan, channels: Int) throws {
        precondition(plan.client == .float32, "RecordingOutput records Float32 clients")
        state.withLock { s in
            s.buffer?.deallocate()
            s.buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096 * channels * 4, alignment: 16)
            s.channels = channels
        }
    }

    func start() throws {
        state.withLock { $0.started = true }
    }

    func stop() {
        state.withLock { $0.started = false }
    }

    /// One render callback of `frames` (at most 4096) frames. Returns its real frames.
    @discardableResult
    func pull(frames: Int) -> Int {
        state.withLock { s in
            guard s.started, let source = s.source, let buffer = s.buffer else { return 0 }
            let real = source.render(into: buffer, frames: frames)
            let samples = buffer.bindMemory(to: Float.self, capacity: frames * s.channels)
            s.calls.append(Call(start: s.stream.count / s.channels, real: real))
            s.stream.append(contentsOf: UnsafeBufferPointer(start: samples, count: frames * s.channels))
            return real
        }
    }
}

// MARK: - Tests

// Serialized: every test runs a decode thread and a pull loop, and `seekCompletesWithin50ms` measures wall-clock
// latency. Run in parallel under TSan the seek took 23–28 ms (half the budget) against 8–10 ms serialized.
@Suite(.serialized) struct PlaybackPipelineTests {
    /// Every accepted fixture v1 plays (mono and stereo, 16 to 32 bits, 44.1 to 384 kHz), on the pure path at its own
    /// rate. corrupt-mid is left out: its damaged block decodes to silence, not to its `.raw` (see FlacDecoderTests).
    static let pureFixtures = Fixtures.all.filter {
        $0.expect == .accept && $0.channels <= 2 && $0.name != "corrupt-mid-s16-44100"
    }.map(\.name)

    /// Spec §6.3: what the pipeline hands the output equals the decoded source exactly, with the negotiated rate equal
    /// to the source's. Up to 24 bits that is the Float32 client, v / 2^(b−1); a 32-bit source needs the Int32 client,
    /// so the capabilities allow it here.
    @Test(arguments: pureFixtures)
    func purePathIsBitExact(_ name: String) async {
        let f = Fixtures.named(name)
        let rig = Rig(int32Passthrough: true)
        await rig.play([item(name)])
        await rig.playToEnd()
        let raw = Fixtures.rawSamples(f)
        #expect(raw.count == Int(f.frames) * f.channels)
        if f.bits > 24 {
            let plan = OutputPlan(client: .int32, clientSampleRate: f.sampleRate, resample: nil, reduceTo24: false)
            #expect(rig.output.plans == [plan])
            #expect(mismatch(rig.output.capturedInt32, raw) == nil)
        } else {
            #expect(rig.output.plans == [floatPlan(f.sampleRate)])
            #expect(mismatch(rig.output.capturedFloat, floats(raw, bits: f.bits)) == nil)
        }
        #expect(rig.log.events.first == .planChanged(rig.output.plans[0]))
        #expect(rig.log.contains(started(0, name)))
    }

    static let thirtyTwoBitFixtures = pureFixtures.filter { Fixtures.named($0).bits == 32 }

    /// Ruling R3: one `TPDFDither(seed:)` per track, run over its samples in order, so a capture is reproducible. The
    /// dither itself is pinned to fixed numbers by `ditherGoldenVector`.
    @Test(arguments: thirtyTwoBitFixtures)
    func reducedDepthPathMatchesSeededDither(_ name: String) async {
        let f = Fixtures.named(name)
        let seed: UInt64 = 0x0123_4567_89AB_CDEF
        let rig = Rig(ditherSeed: seed)
        await rig.play([item(name)])
        await rig.playToEnd()
        var expected = Fixtures.rawSamples(f)
        var dither = TPDFDither(seed: seed)
        expected.withUnsafeMutableBufferPointer { dither.reduce32To24($0) }
        #expect(rig.output.plans == [floatPlan(f.sampleRate, reduceTo24: true)])
        #expect(mismatch(rig.output.capturedFloat, floats(expected, bits: 32)) == nil)
    }

    @Test func gaplessJoinSameFormat() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-48000"))
        let rig = Rig()
        await rig.play([item("s24-48000", id: "a"), item("s24-48000", id: "b")])
        await rig.playToEnd()
        let plan = floatPlan(48_000)
        #expect(rig.output.capturedFloat.count == 8192 * 2)
        #expect(mismatch(rig.output.capturedFloat, floats(raw + raw, bits: 24)) == nil)
        #expect(rig.output.plans == [plan])
        #expect(
            rig.log.events == [
                .planChanged(plan), started(0, "s24-48000"), .trackEnded(0),
                started(1, "s24-48000"), .trackEnded(1), .queueEnded,
            ])
    }

    @Test func formatChangeBetweenTracksReconfigures() async {
        let first = floats(Fixtures.rawSamples(Fixtures.named("s16-44100")), bits: 16)
        let second = floats(Fixtures.rawSamples(Fixtures.named("s24-96000")), bits: 24)
        let rig = Rig()
        await rig.play([item("s16-44100"), item("s24-96000")])
        await rig.playToEnd()
        #expect(rig.output.plans == [floatPlan(44_100), floatPlan(96_000)])
        #expect(rig.output.plans.count == 2 && rig.output.plans[1].clientSampleRate == 96_000)
        let captured = rig.output.capturedFloat
        #expect(mismatch(Array(captured.prefix(first.count)), first) == nil)
        #expect(mismatch(Array(captured.dropFirst(first.count)), second) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(44_100)), started(0, "s16-44100"), .trackEnded(0),
                .planChanged(floatPlan(96_000)), started(1, "s24-96000"), .trackEnded(1), .queueEnded,
            ])
    }

    @Test func resamplesWhenHardwareDiffers() async throws {
        let f = Fixtures.named("s24-96000")
        let rig = Rig(hardwareRate: { _ in 48_000 })
        await rig.play([item("s24-96000")])
        await rig.playToEnd()
        #expect(rig.output.plans == [floatPlan(48_000, resample: RateChange(from: 96_000, to: 48_000))])
        let captured = rig.output.capturedFloat
        #expect(abs(captured.count / 2 - 2048) <= 64)
        let reference = try oneShotResample(
            floats(Fixtures.rawSamples(f), bits: 24), from: 96_000, to: 48_000, channels: 2)
        #expect(captured.count == reference.count)
        #expect(maxDifference(captured, reference) <= resampleJoinTolerance)

        // Decode-block joins (T8 carry-over): corrupt-mid is 16384 frames, four 4096-frame decode blocks, so the
        // pipeline feeds the converter in four `process` calls. 44.1 → 48 kHz is a non-integer ratio, the harder case.
        let long = Rig(hardwareRate: { _ in 48_000 })
        await long.play([item("corrupt-mid-s16-44100")])
        await long.playToEnd()
        let joined = long.output.capturedFloat
        let oneShot = try oneShotResample(
            floats(try decodeAll("corrupt-mid-s16-44100"), bits: 16), from: 44_100, to: 48_000, channels: 2)
        #expect(abs(joined.count / 2 - 17_833) <= 64)
        #expect(joined.count == oneShot.count)
        #expect(maxDifference(joined, oneShot) <= resampleJoinTolerance)
    }

    /// Ruling R7: a same-plan join keeps feeding the same converter, so the join is as seamless as one long file.
    @Test func gaplessResampledJoinFeedsOneConverter() async throws {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-96000"))
        let rig = Rig(hardwareRate: { _ in 48_000 })
        await rig.play([item("s24-96000", id: "a"), item("s24-96000", id: "b")])
        await rig.playToEnd()
        #expect(rig.output.plans.count == 1)
        let captured = rig.output.capturedFloat
        let reference = try oneShotResample(floats(raw + raw, bits: 24), from: 96_000, to: 48_000, channels: 2)
        #expect(abs(captured.count / 2 - 4096) <= 64)
        #expect(captured.count == reference.count)
        #expect(maxDifference(captured, reference) <= resampleJoinTolerance)
    }

    @Test func decoderFailureSkipsToNextItem() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s16-44100"))
        let rig = Rig(makeDecoder: { item in
            let decoder = try FlacDecoder(url: item.url)
            return item.id == "doomed" ? FailingDecoder(decoder, failAfter: 1000) : decoder
        })
        await rig.play([item("s16-44100", id: "doomed"), item("s16-44100", id: "next")])
        await rig.playToEnd()
        let events = rig.log.events
        let failed = events.firstIndex {
            if case .itemFailed(0, _) = $0 { return true }
            return false
        }
        let next = events.firstIndex(of: started(1, "s16-44100"))
        #expect(failed != nil && next != nil && failed! < next!, "events: \(events)")
        #expect(!events.contains(.trackEnded(0)))
        // The 1000 frames decoded before the failure play; then item 1 plays exactly.
        #expect(mismatch(rig.output.capturedFloat, floats(raw.prefix(2000) + raw, bits: 16)) == nil)
    }

    /// Fifty seeks before the render thread runs again are one dip: one fade-out of what was playing, and the newest
    /// target's audio fading in.
    @Test func seekSpamLatestWins() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-96000"))
        let rig = Rig()
        await rig.play([item("s24-96000")])
        #expect(await rig.pump { rig.pulledFrames >= 1024 })
        let played = rig.pulledFrames
        for i in 0..<49 {
            await rig.pipeline.seek(toFrame: Int64(i * 613 % 4096))
        }
        await rig.pipeline.seek(toFrame: 3000)
        let position = rig.pipeline.position
        #expect(position.index == 0 && position.frame == 3000)
        let mark = rig.output.capturedFloat.count
        await rig.playToEnd()
        let source = floats(raw, bits: 24)
        let want = seekDip(old: source[(2 * played)...], new: source[6000...], channels: 2, rate: 96_000)
        #expect(mismatch(Array(rig.output.capturedFloat[mark...]), want) == nil)
        #expect(rig.pipeline.position.frame == 4096)
        // The end markers queued before the seeks were never rendered, so they are dropped, not fired twice.
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(96_000)), started(0, "s24-96000"), .trackEnded(0), .queueEnded,
            ])
    }

    @Test func midstreamDamagePlaysThrough() async {
        let rig = Rig()
        await rig.play([item("corrupt-mid-s16-44100")])
        await rig.playToEnd()
        #expect(rig.log.failures.isEmpty)
        #expect(rig.output.capturedFloat.count == 16384 * 2)
    }

    /// An Int32 client (a 32-bit source through passthrough) dips the same way. The fade-out scales its words in
    /// Double, rounded half away from zero, and so does the fade-in; every word outside the two fades is the source's
    /// own, all 32 bits of it.
    @Test func aSeekDipsOnAnInt32ClientToo() async {
        let f = Fixtures.named("s32-48000")
        let raw = Fixtures.rawSamples(f)
        let fade = RenderSource.fadeFrames(atRate: f.sampleRate)
        let rig = Rig(int32Passthrough: true)
        await rig.play([item("s32-48000")])
        #expect(await rig.pump { rig.pulledFrames >= 1024 })
        let played = rig.pulledFrames
        let mark = rig.output.capturedInt32.count
        await rig.pipeline.seek(toFrame: 2000)
        await rig.playToEnd()
        #expect(rig.output.plans.map(\.client) == [.int32])
        func scaled(_ x: Int32, by gain: Float) -> Int32 { Int32((Double(x) * Double(gain)).rounded()) }
        let channels = f.channels
        var want: [Int32] = []
        for i in 0..<(fade * channels) {
            want.append(scaled(raw[played * channels + i], by: RenderSource.seekFadeGain(i / channels, of: fade)))
        }
        for (i, x) in raw[(2000 * channels)...].enumerated() {
            let k = i / channels
            want.append(k < fade ? scaled(x, by: Float(k) / Float(fade)) : x)
        }
        #expect(mismatch(Array(rig.output.capturedInt32[mark...]), want) == nil)
    }

    /// The seek's latency runs to the new position's first frame. The fade-out of what was playing comes first (it is
    /// already in the ring); then the new audio, fading in.
    @Test func seekCompletesWithin50ms() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-96000"))
        let fade = RenderSource.fadeFrames(atRate: 96_000)
        let rig = Rig()
        await rig.play([item("s24-96000")])
        #expect(await rig.pump { rig.pulledFrames >= 1024 })
        let played = rig.pulledFrames
        let mark = rig.output.capturedFloat.count
        let clock = ContinuousClock()
        let start = clock.now
        await rig.pipeline.seek(toFrame: 2000)
        var latency: Duration?
        var fading = 0
        // A render thread pulling about once a millisecond.
        while clock.now - start < .seconds(2) {
            let n = rig.pull()
            if n > 0, fading < fade {
                fading += n
            } else if n > 0 {
                latency = clock.now - start
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(fading == fade, "the fade-out came first, all of it")
        let budget = LatencyBudget.scaled(.milliseconds(50))
        #expect(
            latency != nil && latency! < budget,
            "seek latency \(String(describing: latency)), \(LatencyBudget.describe(.milliseconds(50)))")
        let fresh = Array(rig.output.capturedFloat[mark...])
        let source = floats(raw, bits: 24)
        let new = source[4000..<(4000 + max(fresh.count - 2 * fade, 0))]
        let want = seekDip(old: source[(2 * played)...], new: new, channels: 2, rate: 96_000)
        #expect(fresh.count > 2 * fade && mismatch(fresh, want) == nil)
    }

    /// Render-polish brief, part 1: a seek on a full-scale sine is a short dip, never a click. Every frame the output
    /// is handed, silence included: the music before the seek, bit-exact; the ring's next 6 ms fading out on the
    /// raised cosine; the hold's silence; the new position's first 6 ms fading in linearly; then the source again,
    /// bit-exact. The largest step anywhere stays below 1.5 × the tone's own slope (SoundChainTests' click bound),
    /// locally and against the loudest level, where a cut to silence mid-wave reaches up to 7.6 ×. The fade-out's frames
    /// belong to the old position: the new one counts from its first frame after the hold.
    @Test func aSeekDipsWithoutAClick() async {
        let output = RecordingOutput()
        let pipeline = PlaybackPipeline(
            output: output, capabilities: OutputCapabilities(int32Passthrough: false), negotiateRate: { $0 },
            makeDecoder: { _ in FullScaleSineDecoder() })
        defer { pipeline.stop() }
        let rate = FullScaleSineDecoder.rate
        let fade = RenderSource.fadeFrames(atRate: rate)
        /// Pulls until `count` more real frames have been rendered, in calls of at most 512 frames.
        func pullReal(_ count: Int) async -> Bool {
            var left = count
            let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(10))
            while left > 0 {
                guard ContinuousClock.now < deadline else { return false }
                let n = output.pull(frames: min(512, left))
                left -= n
                if n == 0 { try? await Task.sleep(for: .microseconds(200)) }
            }
            return true
        }
        await pipeline.start([FullScaleSineDecoder.item], at: 0, fromFrame: 0)
        // Let the decode thread fill the ring first, so every call before the seek is all music.
        try? await Task.sleep(for: .milliseconds(100))
        let before = 4096
        #expect(await pullReal(before))
        // Whatever silence the start-up rendered, before the first real frame.
        let opening = output.calls.first { $0.real > 0 }?.start ?? 0
        let seekedAt = output.calls.count
        let played = output.calls.flatMap { $0.start..<($0.start + $0.real) }
        #expect(played == Array(opening..<(opening + before)), "the music before the seek played unbroken")
        let target: Int64 = 100_000
        await pipeline.seek(toFrame: target)
        let after = 4096
        #expect(await pullReal(fade + after))
        #expect(pipeline.position == (0, target + Int64(after)), "the new position counts from after the hold")

        let stream = output.stream
        func left(_ frame: Int) -> Float { stream[2 * frame] }
        func right(_ frame: Int) -> Float { stream[2 * frame + 1] }
        // Where each real frame since the seek landed in the stream: a call's real frames are a prefix of it.
        let real = output.calls[seekedAt...].flatMap { $0.start..<($0.start + $0.real) }
        #expect(real.count == fade + after)
        guard real.count == fade + after else { return }
        let fadeOut = Array(real.prefix(fade))
        let resumed = real[fade]
        #expect(fadeOut == Array((opening + before)..<(opening + before + fade)), "the fade-out follows on at once")
        #expect(Array(real[fade...]) == Array(resumed..<(resumed + after)), "the new position plays on unbroken")

        // Before the seek: the source, bit-exact.
        let exactBefore = (0..<before).allSatisfy { n in
            let want = FullScaleSineDecoder.float(Int64(n))
            return left(opening + n).bitPattern == want.bitPattern && right(opening + n).bitPattern == want.bitPattern
        }
        #expect(exactBefore, "bit-exact before the seek")
        // The fade-out: the ring's next frames on the raised cosine.
        let outShape = (0..<fade).allSatisfy { k in
            let want = FullScaleSineDecoder.float(Int64(before + k)) * RenderSource.seekFadeGain(k, of: fade)
            return left(fadeOut[k]).bitPattern == want.bitPattern && right(fadeOut[k]).bitPattern == want.bitPattern
        }
        #expect(outShape, "the fade-out's shape")
        // The hold: silence, to the bit, and at least the rest of the fade's call.
        let gap = (fadeOut[fade - 1] + 1)..<resumed
        #expect(!gap.isEmpty && gap.allSatisfy { left($0).bitPattern == 0 && right($0).bitPattern == 0 })
        // The fade-in, from silence, then the new position exactly.
        let inShape = (0..<fade).allSatisfy { k in
            let want = FullScaleSineDecoder.float(target + Int64(k)) * (Float(k) / Float(fade))
            return left(resumed + k).bitPattern == want.bitPattern && right(resumed + k).bitPattern == want.bitPattern
        }
        #expect(inShape, "the fade-in's shape")
        let exact = (fade..<after).allSatisfy { k in
            let want = FullScaleSineDecoder.float(target + Int64(k))
            return left(resumed + k).bitPattern == want.bitPattern && right(resumed + k).bitPattern == want.bitPattern
        }
        #expect(exact, "bit-exact after the fade-in")
        // No click anywhere: the whole stream, the gap included, against the tone's own slope.
        let heard = Array(stream[(2 * opening)..<(2 * (resumed + after))])
        let ratios = largestStepRatios(heard, channels: 2, hz: FullScaleSineDecoder.hz, rate: Double(rate))
        #expect(ratios.local < 1.5, "largest step \(ratios.local) × the local slope")
        #expect(ratios.global < 1.5, "largest step \(ratios.global) × the loudest slope")
    }

    @Test func eventsFireOnRenderedBoundary() async {
        let rig = Rig()
        await rig.play([item("s24-48000", id: "a"), item("s24-48000", id: "b")])
        // Both tracks fit in the ring, so the decode thread passes the boundary long before it is rendered.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rig.log.contains(.trackEnded(0)))
        // One frame short of the boundary: still not ended.
        #expect(await rig.pull(upTo: 4095))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!rig.log.contains(.trackEnded(0)))
        // The boundary rendered, and nothing more pulled: the event follows promptly, the next track's end does not.
        #expect(await rig.pull(upTo: 4096))
        // trackEnded(0) and trackStarted(1) share frame 4096 and reach the log one at a time, so wait for both.
        #expect(
            await wait(upTo: .milliseconds(50)) {
                rig.log.contains(.trackEnded(0)) && rig.log.contains(started(1, "s24-48000"))
            }, "boundary events, \(LatencyBudget.describe(.milliseconds(50)))")
        #expect(!rig.log.contains(.trackEnded(1)))
    }

    /// 44.1 → 48 kHz has no integer ratio, so the join's output frame is predicted (4096 · 48000/44100 ≈ 4458), and
    /// the resampler's real output after its final flush can fall a frame short of the predicted end.
    @Test func resampledGaplessJoinAtNonIntegerRatio() async throws {
        let raw = Fixtures.rawSamples(Fixtures.named("s16-44100"))
        let rig = Rig(hardwareRate: { _ in 48_000 })
        await rig.play([item("s16-44100", id: "a"), item("s16-44100", id: "b")])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await rig.pull(upTo: 4458 - 32))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!rig.log.contains(.trackEnded(0)))
        #expect(await rig.pull(upTo: 4458 + 32))
        #expect(
            await wait(upTo: .milliseconds(50)) {
                rig.log.contains(started(1, "s16-44100"))
            }, "\(LatencyBudget.describe(.milliseconds(50)))")
        #expect(!rig.log.contains(.trackEnded(1)))
        await rig.playToEnd()
        let plan = floatPlan(48_000, resample: RateChange(from: 44_100, to: 48_000))
        #expect(
            rig.log.events == [
                .planChanged(plan), started(0, "s16-44100"), .trackEnded(0),
                started(1, "s16-44100"), .trackEnded(1), .queueEnded,
            ])
        let reference = try oneShotResample(floats(raw + raw, bits: 16), from: 44_100, to: 48_000, channels: 2)
        #expect(rig.output.capturedFloat.count == reference.count)
        #expect(maxDifference(rig.output.capturedFloat, reference) <= resampleJoinTolerance)
    }

    /// Regression: a resampled join predicted one frame past the true end of the stream, when the next item yields
    /// nothing, used to strand every later event behind it. With `followedByFormatChange`, `.planChanged` used to
    /// overtake `trackEnded(0)` as well.
    @Test(arguments: [false, true])
    func resampledJoinIntoAnEmptyItemStillEnds(followedByFormatChange: Bool) async {
        let rig = Rig(
            hardwareRate: { _ in 48_000 },
            makeDecoder: { item in
                let decoder = try FlacDecoder(url: item.url)
                return item.id == "empty" ? FailingDecoder(decoder, failAfter: 0) : decoder
            })
        var items = [item("corrupt-mid-s16-44100"), item("s16-44100", id: "empty")]
        if followedByFormatChange { items.append(item("s24-96000")) }
        await rig.play(items)
        let ended = await rig.pump(timeout: .seconds(5)) { rig.log.contains(.queueEnded) }
        #expect(ended, "events: \(rig.log.events)")
        var expected: [PipelineEvent] = [
            .planChanged(floatPlan(48_000, resample: RateChange(from: 44_100, to: 48_000))),
            started(0, "corrupt-mid-s16-44100"),
            .trackEnded(0), started(1, "s16-44100"), .itemFailed(1, "ioError"),
        ]
        if followedByFormatChange {
            expected += [
                .planChanged(floatPlan(48_000, resample: RateChange(from: 96_000, to: 48_000))),
                started(2, "s24-96000"),
                .trackEnded(2),
            ]
        }
        expected.append(.queueEnded)
        #expect(rig.log.events == expected)
    }

    /// A seek asked for in the last 6 ms of an item, with the next one already joined behind it in the ring, seeks in
    /// the item it was asked in. Its fade-out plays on across the join (the first frames of the next item, fading
    /// out), but those frames are the old position's on their way out and are not counted: no boundary is crossed, and
    /// the next item still follows whole, from its start, with its events in order.
    @Test func aSeekJustBeforeAGaplessJoinStaysInItsItem() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-48000"))
        let fade = RenderSource.fadeFrames(atRate: 48_000)
        let rig = Rig()
        await rig.play([item("s24-48000", id: "a"), item("s24-48000", id: "b")])
        // Both tracks fit in the ring.
        try? await Task.sleep(for: .milliseconds(100))
        let short = 100
        #expect(short < fade)
        #expect(await rig.pull(upTo: 4096 - short))
        let mark = rig.output.capturedFloat.count
        await rig.pipeline.seek(toFrame: 1000)
        #expect(await rig.pull(upTo: 4096 - short + fade + 512))
        #expect(rig.pipeline.position == (0, 1512), "the seek stayed in the first item")
        await rig.playToEnd()
        let source = floats(raw, bits: 24)
        // The fade-out: the first item's last 100 frames, then the second's first 188, fading out.
        let across = source[(2 * (4096 - short))...] + source[0..<(2 * (fade - short))]
        let want = seekDip(old: across, new: source[2000...], channels: 2, rate: 48_000) + source
        #expect(mismatch(Array(rig.output.capturedFloat[mark...]), want) == nil)
        #expect(
            rig.log.events == [
                .planChanged(floatPlan(48_000)), started(0, "s24-48000"), .trackEnded(0), started(1, "s24-48000"),
                .trackEnded(1), .queueEnded,
            ])
    }

    /// The realistic seek: mid-playback of a long track, with the decode thread blocked writing into a full ring. Its
    /// latency runs to the new position's first frame, after the fade-out of what was playing.
    @Test func seekWhileDecodingCompletesWithin50ms() async {
        let fade = RenderSource.fadeFrames(atRate: 44_100)
        let rig = Rig(makeDecoder: { _ in PatternDecoder() })
        await rig.play([PatternDecoder.item])
        #expect(await rig.pump { rig.pulledFrames >= 8192 })
        // Let the decode thread refill the half-second ring and block on it.
        try? await Task.sleep(for: .milliseconds(20))
        let played = Int64(rig.pulledFrames)
        let mark = rig.output.capturedFloat.count
        let clock = ContinuousClock()
        let start = clock.now
        await rig.pipeline.seek(toFrame: 300_000)
        var latency: Duration?
        var fading = 0
        while clock.now - start < .seconds(2) {
            let n = rig.pull()
            if n > 0, fading < fade {
                fading += n
            } else if n > 0 {
                latency = clock.now - start
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(fading == fade, "the fade-out came first, all of it")
        let budget = LatencyBudget.scaled(.milliseconds(50))
        #expect(
            latency != nil && latency! < budget,
            "seek latency \(String(describing: latency)), \(LatencyBudget.describe(.milliseconds(50)))")
        let fresh = Array(rig.output.capturedFloat[mark...])
        let old = floats(PatternDecoder.samples(from: played, count: fade), bits: 16)
        let new = floats(PatternDecoder.samples(from: 300_000, count: max(fresh.count / 2 - fade, 0)), bits: 16)
        #expect(
            fresh.count > 2 * fade && mismatch(fresh, seekDip(old: old, new: new, channels: 2, rate: 44_100)) == nil)
    }

    /// `negotiateRate` returning no usable rate fails that item; the pipeline never assumes the source rate.
    @Test func unavailableOutputRateFailsTheItem() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s16-44100"))
        let rig = Rig(hardwareRate: { $0 == 96_000 ? 0 : $0 })
        await rig.play([item("s24-96000"), item("s16-44100")])
        await rig.playToEnd()
        #expect(
            rig.log.events == [
                .itemFailed(0, "Output rate unavailable"), .planChanged(floatPlan(44_100)),
                started(1, "s16-44100"),
                .trackEnded(1), .queueEnded,
            ])
        #expect(rig.output.plans == [floatPlan(44_100)])
        #expect(mismatch(rig.output.capturedFloat, floats(raw, bits: 16)) == nil)
    }

    /// C1: a file with more channels than v1 plays fails closed. It gets an `itemFailed` with the policy's message, the
    /// output is never configured for it and nothing of it is rendered, and the queue moves on.
    @Test func multichannelItemFailsClosed() async {
        let alone = Rig()
        await alone.play([item("s16-48000-6ch")])
        await alone.playToEnd()
        #expect(alone.log.events == [.itemFailed(0, "Multichannel FLAC isn't supported yet"), .queueEnded])
        #expect(alone.output.plans.isEmpty && !alone.output.isStarted)
        #expect(alone.output.capturedFloat.isEmpty && alone.output.capturedInt32.isEmpty)

        let raw = Fixtures.rawSamples(Fixtures.named("s16-44100"))
        let rig = Rig()
        await rig.play([item("s16-48000-6ch"), item("s16-44100")])
        await rig.playToEnd()
        #expect(
            rig.log.events == [
                .itemFailed(0, "Multichannel FLAC isn't supported yet"), .planChanged(floatPlan(44_100)),
                started(1, "s16-44100"), .trackEnded(1), .queueEnded,
            ])
        #expect(rig.output.plans == [floatPlan(44_100)])
        #expect(mismatch(rig.output.capturedFloat, floats(raw, bits: 16)) == nil)
    }

    /// Final review I6 (measurement): the start and seek intervals end at the first real frame the decode thread sees
    /// rendered, never on hold or underrun silence, nor on a seek's fade-out of the old position. One that never gets
    /// a frame (superseded, or the pipeline stopped) ends as abandoned.
    @Test func firstFrameIntervalsEndOnRenderedAudio() async {
        let rig = Rig()
        let started = FirstFrameInterval(.play)
        await rig.pipeline.start([item("s24-96000")], at: 0, fromFrame: 0, firstFrame: started)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(started.outcome == nil, "ended before anything was rendered")
        #expect(await rig.pull(upTo: 512))
        #expect(await wait(upTo: .seconds(2)) { started.outcome != nil })
        #expect(started.outcome == .rendered)

        let superseded = FirstFrameInterval(.seek)
        let seek = FirstFrameInterval(.seek)
        await rig.pipeline.seek(toFrame: 1000, firstFrame: superseded)
        await rig.pipeline.seek(toFrame: 2000, firstFrame: seek)
        #expect(superseded.outcome == .abandoned)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(seek.outcome == nil, "ended before the seek was served")
        // The fade-out's frames are the old position's: they end nothing.
        let fade = RenderSource.fadeFrames(atRate: 96_000)
        #expect(await rig.pull(upTo: 512 + fade))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(seek.outcome == nil, "ended on the fade-out")
        #expect(await rig.pump { rig.pulledFrames > 512 + fade })
        #expect(await wait(upTo: .seconds(2)) { seek.outcome != nil })
        #expect(seek.outcome == .rendered)

        let stopped = FirstFrameInterval(.seek)
        await rig.pipeline.seek(toFrame: 100, firstFrame: stopped)
        rig.pipeline.stop()
        #expect(stopped.outcome == .abandoned)

        let neverRendered = FirstFrameInterval(.play)
        await rig.pipeline.start([item("s16-44100")], at: 0, fromFrame: 0, firstFrame: neverRendered)
        rig.pipeline.stop()
        #expect(await wait(upTo: .seconds(2)) { neverRendered.outcome != nil })
        #expect(neverRendered.outcome == .abandoned)
    }

    /// The underrun counter through the pipeline: the silence after the queue's last frame is the stream's end, which
    /// the decode thread marks, so a clean play-through counts no underrun (with the mark missing, the pulls after the
    /// end would count).
    @Test func cleanPlayThroughCountsNoUnderrun() async {
        let rig = Rig()
        await rig.play([item("s24-48000"), item("s16-44100")])
        // Paced so the render never outruns the decode thread: each 85 ms track sits whole in the ring before it is
        // pulled, and the format change's drain and reconfiguration finish between the two.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await rig.pull(upTo: 4096))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await rig.pull(upTo: 8192))
        #expect(await wait(upTo: .seconds(2)) { rig.log.contains(.queueEnded) })
        for _ in 0..<8 { #expect(rig.pull() == 0) }
        #expect(rig.pipeline.underrunFrames == 0)
    }

    @Test func positionFollowsRenderedFrames() async {
        let rig = Rig()
        await rig.play([item("s24-48000", id: "a"), item("s24-48000", id: "b")])
        try? await Task.sleep(for: .milliseconds(50))
        var position = rig.pipeline.position
        #expect(position.index == 0 && position.frame == 0)
        await rig.pump { rig.pulledFrames >= 1024 }
        position = rig.pipeline.position
        #expect(position.index == 0 && position.frame == 1024)
        await rig.pump { rig.pulledFrames >= 4096 + 512 }
        position = rig.pipeline.position
        #expect(position.index == 1 && position.frame == 512)
    }

    /// `stop()` must not wait on `negotiateRate`, and the decode thread must unwind even though it never answers.
    @Test func stopWhileNegotiationNeverAnswers() async {
        let negotiation = StuckNegotiation()
        let lifetime = TrackedDecoder.Lifetime()
        let rig = Rig(
            negotiate: { _ in await negotiation.answer() },
            makeDecoder: { item in TrackedDecoder(try FlacDecoder(url: item.url), lifetime: lifetime) })
        await rig.play([item("s16-44100")])
        #expect(await wait(upTo: .seconds(2)) { negotiation.entered })
        #expect(rig.pipeline.liveDecodeThreads == 1)
        let clock = ContinuousClock()
        let start = clock.now
        rig.pipeline.stop()
        let stopTook = clock.now - start
        #expect(
            stopTook < LatencyBudget.scaled(.milliseconds(50)),
            "stop() took \(stopTook), \(LatencyBudget.describe(.milliseconds(50)))")
        #expect(await wait(upTo: .seconds(1)) { rig.pipeline.liveDecodeThreads == 0 })
        #expect(await wait(upTo: .seconds(1)) { lifetime.ended }, "the stopped session still holds its decoder")
        // A late answer must not configure or start the output, or emit anything.
        negotiation.release(44_100)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.output.plans.isEmpty && !rig.output.isStarted)
        #expect(rig.log.events.isEmpty)
    }

    @Test func stopHaltsOutputAndStartReplacesTheQueue() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s16-44100"))
        let rig = Rig()
        await rig.play([item("s24-48000")])
        await rig.pump { rig.pulledFrames >= 512 }
        rig.pipeline.stop()
        #expect(!rig.output.isStarted)
        #expect(rig.pull() == 0)
        let mark = rig.output.capturedFloat.count
        await rig.play([item("s16-44100")])
        await rig.playToEnd()
        #expect(mismatch(Array(rig.output.capturedFloat[mark...]), floats(raw, bits: 16)) == nil)
    }
}

/// Bound on |pipeline − one-shot| for the resampled tests. Both runs use the same filter, so if the converter carries
/// its state across `process` calls the only differences are Float32 rounding from a different internal partitioning,
/// a few ulps of full scale (~1e-6). A fault at a join — filter state reset, or a frame dropped or repeated — is on the
/// order of the signal itself: these fixtures are full-scale noise and a bit walk up to 0.5, so adjacent output
/// samples differ by ~0.1 or more. 1e-4 (−80 dBFS) sits two orders of magnitude above rounding and three below a fault.
/// Measured on macOS 26 with AVAudioConverter (Mastering, max quality): 0, the streamed output is bit-identical.
private let resampleJoinTolerance: Float = 1e-4
