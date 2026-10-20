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

    /// Pulls until exactly `target` real frames have been pulled in all, then stops. False on timeout.
    @discardableResult
    func pull(upTo target: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
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

/// Waits, without pulling, until `condition` holds or the timeout passes, and returns whether it held.
private func wait(upTo timeout: Duration, for condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
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
        let budget = LatencyBudget.scaled(.milliseconds(50))
        #expect(
            latency != nil && latency! < budget,
            "seek latency \(String(describing: latency)), \(LatencyBudget.describe(.milliseconds(50)))")
        let fresh = Array(rig.output.capturedFloat[mark...])
        #expect(!fresh.isEmpty && mismatch(fresh, floats(raw[4000..<(4000 + fresh.count)], bits: 24)) == nil)
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
            await wait(upTo: LatencyBudget.scaled(.milliseconds(50))) {
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
            await wait(upTo: LatencyBudget.scaled(.milliseconds(50))) {
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

    /// The realistic seek: mid-playback of a long track, with the decode thread blocked writing into a full ring.
    @Test func seekWhileDecodingCompletesWithin50ms() async {
        let rig = Rig(makeDecoder: { _ in PatternDecoder() })
        await rig.play([PatternDecoder.item])
        #expect(await rig.pump { rig.pulledFrames >= 8192 })
        // Let the decode thread refill the half-second ring and block on it.
        try? await Task.sleep(for: .milliseconds(20))
        let mark = rig.output.capturedFloat.count
        let clock = ContinuousClock()
        let start = clock.now
        await rig.pipeline.seek(toFrame: 300_000)
        var latency: Duration?
        while clock.now - start < .seconds(2) {
            if rig.pull() > 0 {
                latency = clock.now - start
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let budget = LatencyBudget.scaled(.milliseconds(50))
        #expect(
            latency != nil && latency! < budget,
            "seek latency \(String(describing: latency)), \(LatencyBudget.describe(.milliseconds(50)))")
        let fresh = Array(rig.output.capturedFloat[mark...])
        let expected = floats(PatternDecoder.samples(from: 300_000, count: fresh.count / 2), bits: 16)
        #expect(!fresh.isEmpty && mismatch(fresh, expected) == nil)
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
    /// rendered, never on hold or underrun silence. One that never gets a frame (superseded, or the pipeline stopped)
    /// ends as abandoned.
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
        #expect(await rig.pump { rig.pulledFrames > 512 })
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
