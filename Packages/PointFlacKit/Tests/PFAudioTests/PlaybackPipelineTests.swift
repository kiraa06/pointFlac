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

/// A pipeline wired to a `FakeOutput`, with its events collected. The test plays the render thread by pulling
/// 512-frame chunks.
private final class Rig {
    let output = FakeOutput()
    let pipeline: PlaybackPipeline
    let log = EventLog()
    private let collector: Task<Void, Never>
    /// Real frames pulled so far (the FakeOutput captures exactly these).
    private(set) var pulledFrames = 0

    init(
        hardwareRate: @escaping @Sendable (Int) -> Int = { $0 }, int32Passthrough: Bool = false,
        ditherSeed: UInt64 = 0x9E37_79B9_7F4A_7C15,
        makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding = { try FlacDecoder(url: $0.url) }
    ) {
        let pipeline = PlaybackPipeline(
            output: output, capabilities: OutputCapabilities(int32Passthrough: int32Passthrough),
            negotiateRate: { hardwareRate($0) }, makeDecoder: makeDecoder, ditherSeed: ditherSeed)
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
    func pull() -> Int {
        let n = output.pull(frames: 512)
        pulledFrames += n
        return n
    }

    /// Pulls until `done()` holds or the timeout passes, and returns whether it held.
    @discardableResult
    func pump(timeout: Duration = .seconds(20), until done: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
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
        #expect(ended, "no queueEnded; events so far: \(log.events)")
    }
}

private func floatPlan(_ rate: Int, resample: RateChange? = nil, reduceTo24: Bool = false) -> OutputPlan {
    OutputPlan(client: .float32, clientSampleRate: rate, resample: resample, reduceTo24: reduceTo24)
}

// MARK: - Tests

// Serialized: every test runs a decode thread and a pull loop, and `seekCompletesWithin50ms` measures wall-clock
// latency. Run in parallel under TSan the seek took 23–28 ms (half the budget) against 8–10 ms serialized.
@Suite(.serialized) struct PlaybackPipelineTests {
    @Test(arguments: ["s16-44100", "s24-96000"])
    func pureFloatPathIsBitExact(_ name: String) async {
        let f = Fixtures.named(name)
        let rig = Rig()
        await rig.play([item(name)])
        await rig.playToEnd()
        #expect(rig.output.plans == [floatPlan(f.sampleRate)])
        #expect(mismatch(rig.output.capturedFloat, floats(Fixtures.rawSamples(f), bits: f.bits)) == nil)
    }

    @Test func int32PathIsBitExact() async {
        let f = Fixtures.named("s32-96000")
        let rig = Rig(int32Passthrough: true)
        await rig.play([item("s32-96000")])
        await rig.playToEnd()
        let plan = OutputPlan(client: .int32, clientSampleRate: 96_000, resample: nil, reduceTo24: false)
        #expect(rig.output.plans == [plan])
        #expect(mismatch(rig.output.capturedInt32, Fixtures.rawSamples(f)) == nil)
    }

    /// Ruling R3: one `TPDFDither(seed:)` per track, run over its samples in order, so a capture is reproducible.
    @Test func reducedDepthPathMatchesSeededDither() async {
        let f = Fixtures.named("s32-96000")
        let seed: UInt64 = 0x0123_4567_89AB_CDEF
        let rig = Rig(ditherSeed: seed)
        await rig.play([item("s32-96000")])
        await rig.playToEnd()
        var expected = Fixtures.rawSamples(f)
        var dither = TPDFDither(seed: seed)
        expected.withUnsafeMutableBufferPointer { dither.reduce32To24($0) }
        #expect(rig.output.plans == [floatPlan(96_000, reduceTo24: true)])
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
                .planChanged(plan), .trackStarted(0), .trackEnded(0), .trackStarted(1), .trackEnded(1), .queueEnded,
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
                .planChanged(floatPlan(44_100)), .trackStarted(0), .trackEnded(0),
                .planChanged(floatPlan(96_000)), .trackStarted(1), .trackEnded(1), .queueEnded,
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
        let next = events.firstIndex(of: .trackStarted(1))
        #expect(failed != nil && next != nil && failed! < next!, "events: \(events)")
        #expect(!events.contains(.trackEnded(0)))
        // The 1000 frames decoded before the failure play; then item 1 plays exactly.
        #expect(mismatch(rig.output.capturedFloat, floats(raw.prefix(2000) + raw, bits: 16)) == nil)
    }

    @Test func seekSpamLatestWins() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-96000"))
        let rig = Rig()
        await rig.play([item("s24-96000")])
        #expect(await rig.pump { rig.pulledFrames >= 1024 })
        for i in 0..<49 {
            await rig.pipeline.seek(toFrame: Int64(i * 613 % 4096))
        }
        await rig.pipeline.seek(toFrame: 3000)
        let position = rig.pipeline.position
        #expect(position.index == 0 && position.frame == 3000)
        let mark = rig.output.capturedFloat.count
        await rig.playToEnd()
        #expect(mismatch(Array(rig.output.capturedFloat[mark...]), floats(raw[6000...], bits: 24)) == nil)
        #expect(rig.pipeline.position.frame == 4096)
        // The end markers queued before the seeks were never rendered, so they are dropped, not fired twice.
        #expect(rig.log.events == [.planChanged(floatPlan(96_000)), .trackStarted(0), .trackEnded(0), .queueEnded])
    }

    @Test func midstreamDamagePlaysThrough() async {
        let rig = Rig()
        await rig.play([item("corrupt-mid-s16-44100")])
        await rig.playToEnd()
        #expect(rig.log.failures.isEmpty)
        #expect(rig.output.capturedFloat.count == 16384 * 2)
    }

    @Test func seekCompletesWithin50ms() async {
        let raw = Fixtures.rawSamples(Fixtures.named("s24-96000"))
        let rig = Rig()
        await rig.play([item("s24-96000")])
        #expect(await rig.pump { rig.pulledFrames >= 1024 })
        let mark = rig.output.capturedFloat.count
        let clock = ContinuousClock()
        let start = clock.now
        await rig.pipeline.seek(toFrame: 2000)
        var latency: Duration?
        // A render thread pulling about once a millisecond.
        while clock.now - start < .seconds(2) {
            if rig.pull() > 0 {
                latency = clock.now - start
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(latency != nil && latency! < .milliseconds(50), "seek latency \(String(describing: latency))")
        let fresh = Array(rig.output.capturedFloat[mark...])
        #expect(!fresh.isEmpty && mismatch(fresh, floats(raw[4000..<(4000 + fresh.count)], bits: 24)) == nil)
    }

    @Test func eventsFireOnRenderedBoundary() async {
        let rig = Rig()
        await rig.play([item("s24-48000", id: "a"), item("s24-48000", id: "b")])
        // Both tracks fit in the ring, so the decode thread passes the boundary long before it is rendered.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rig.log.contains(.trackEnded(0)))
        var framesWhenSeen: Int?
        await rig.pump {
            if rig.log.contains(.trackEnded(0)) { framesWhenSeen = rig.pulledFrames }
            return framesWhenSeen != nil
        }
        #expect(framesWhenSeen != nil && framesWhenSeen! >= 4096, "seen after \(String(describing: framesWhenSeen))")
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
