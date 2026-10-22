import Foundation
import PFCore
import PFDSP
import PFFlac
import PFTestSupport
import Synchronization
import Testing

@testable import PFAudio

// MARK: - Sources

/// A sum of sines, 24-bit stereo with both channels alike: a level at a known frequency can then be measured exactly.
private struct Tone: Sendable {
    struct Partial: Sendable {
        var hz: Double
        /// Of full scale.
        var amplitude: Double
    }

    var rate: Int
    var partials: [Partial]
    var frames: Int64
    /// Where in the endless tone this item starts, so two items can join into one.
    var offset: Int64 = 0

    var format: AudioFormat { AudioFormat(sampleRate: rate, bitsPerSample: 24, channels: 2) }

    func value(_ frame: Int64) -> Int32 {
        var x = 0.0
        let frame = frame + offset
        for p in partials { x += p.amplitude * sin(2 * .pi * p.hz * Double(frame) / Double(rate)) }
        return Int32(min(max((x * 8_388_608).rounded(), -8_388_608), 8_388_607))
    }

    /// Sample `frame` as the Float32 client receives it in Pure: v / 2^23.
    func float(_ frame: Int64) -> Float {
        Float(value(frame)) * 0x1p-23
    }
}

private let tones: [String: Tone] = [
    // 1 kHz, the EQ's peak, and 100 Hz, far below it, where only the automatic headroom acts.
    "eq": Tone(
        rate: 48_000, partials: [.init(hz: 1_000, amplitude: 0.25), .init(hz: 100, amplitude: 0.125)], frames: 48_000),
    // Long enough that nothing ends mid-test.
    "steady": Tone(rate: 44_100, partials: [.init(hz: 1_000, amplitude: 0.25)], frames: 441_000),
    // The rate change: a 44.1 kHz item, then a 96 kHz one, each with a 10 kHz tone.
    "rate-44k": Tone(rate: 44_100, partials: [.init(hz: 10_000, amplitude: 0.25)], frames: 22_050),
    "rate-96k": Tone(rate: 96_000, partials: [.init(hz: 10_000, amplitude: 0.125)], frames: 48_000),
    // A loud first track, whose tail must not reach the next.
    "loud-44k": Tone(rate: 44_100, partials: [.init(hz: 1_000, amplitude: 0.5)], frames: 11_025),
    // Two halves of one tone, which join gaplessly, and the whole.
    "join-a": Tone(rate: 48_000, partials: [.init(hz: 1_000, amplitude: 0.25)], frames: 30_000),
    "join-b": Tone(rate: 48_000, partials: [.init(hz: 1_000, amplitude: 0.25)], frames: 30_000, offset: 30_000),
    "join-whole": Tone(rate: 48_000, partials: [.init(hz: 1_000, amplitude: 0.25)], frames: 60_000),
    // The stress run's items, two seconds each.
    "stress-44k": Tone(rate: 44_100, partials: [.init(hz: 440, amplitude: 0.25)], frames: 88_200),
    "stress-96k": Tone(rate: 96_000, partials: [.init(hz: 440, amplitude: 0.25)], frames: 192_000),
]

private final class ToneDecoder: PCMDecoding {
    let tone: Tone
    private var position: Int64 = 0

    init(_ tone: Tone) {
        self.tone = tone
    }

    var format: AudioFormat { tone.format }
    var totalFrames: Int64 { tone.frames }

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        let n = Int(min(Int64(min(maxFrames, buffer.count / 2)), tone.frames - position))
        for i in 0..<n {
            let v = tone.value(position + Int64(i))
            buffer[2 * i] = v
            buffer[2 * i + 1] = v
        }
        position += Int64(n)
        return n
    }

    func seek(toFrame frame: Int64) throws {
        position = min(max(frame, 0), tone.frames)
    }
}

/// Ten seconds of 32-bit stereo at 48 kHz whose low bits are all in use, so it plays through an Int32 client, and a
/// round trip through Float32 would show.
private final class WordDecoder: PCMDecoding {
    static let item = PlaybackItem(
        id: "words", url: URL(fileURLWithPath: "/dev/null"),
        format: AudioFormat(sampleRate: 48_000, bitsPerSample: 32, channels: 2), totalFrames: 480_000)

    static func value(_ frame: Int64, channel: Int) -> Int32 {
        let tone = (0.25 * 2_147_483_648 * sin(2 * .pi * 1_000 * Double(frame) / 48_000)).rounded()
        let noise = Int32(truncatingIfNeeded: (frame &* 2_654_435_761 &+ Int64(channel) &* 40_503) & 0xFFFF)
        return Int32(tone) &+ noise
    }

    let format = WordDecoder.item.format
    var totalFrames: Int64 { Self.item.totalFrames }
    private var position: Int64 = 0

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        let n = Int(min(Int64(min(maxFrames, buffer.count / 2)), totalFrames - position))
        for i in 0..<n {
            for c in 0..<2 { buffer[2 * i + c] = Self.value(position + Int64(i), channel: c) }
        }
        position += Int64(n)
        return n
    }

    func seek(toFrame frame: Int64) throws {
        position = frame
    }
}

private struct UnknownItem: Error {}

private let toneDecoder: @Sendable (PlaybackItem) throws -> PCMDecoding = { item in
    if item.id == WordDecoder.item.id { return WordDecoder() }
    if item.id.hasPrefix("fixture-") { return try FlacDecoder(url: item.url) }
    guard let tone = tones[item.id] else { throw UnknownItem() }
    return ToneDecoder(tone)
}

private func toneItem(_ id: String) -> QueueItem {
    let tone = tones[id]!
    return QueueItem(
        id: id, url: URL(fileURLWithPath: "/dev/null"), title: id, artist: "", album: "", format: tone.format,
        totalFrames: tone.frames)
}

private func fixtureItem(_ name: String) -> QueueItem {
    let f = Fixtures.named(name)
    return QueueItem(
        id: "fixture-\(name)", url: Fixtures.url(f), title: name, artist: "", album: "",
        format: AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels),
        totalFrames: f.frames)
}

// MARK: - Settings

/// Settings with Pure off and `edit` applied.
private func sound(_ edit: (inout SoundSettings) -> Void) -> SoundSettings {
    var s = SoundSettings()
    s.pure = false
    edit(&s)
    return s
}

/// One parametric EQ peak.
private func peak(_ hz: Double, _ gainDb: Double, autoHeadroom: Bool = true) -> SoundSettings {
    sound {
        $0.eq = EQSettings(
            enabled: true, mode: .parametric, bands: [EQBand(type: .peak, frequency: hz, gainDb: gainDb, q: 1.41)])
        $0.preamp.autoHeadroom = autoHeadroom
    }
}

/// The preamp trim alone (with the limiter, which joins every active block).
private func trim(_ db: Double) -> SoundSettings {
    sound { $0.preamp.trimDb = db }
}

// MARK: - Measuring

/// The amplitude of each frequency in `hz` in `x`, sampled at `rate`: a least-squares fit of a cosine and a sine at
/// each, plus a constant, over all of `x`. Exact for a steady sum of those sines, whatever their phases and however
/// many periods `x` spans.
private func amplitudes(_ x: [Double], hz: [Double], rate: Double) -> [Double] {
    let m = 1 + 2 * hz.count
    func basis(_ n: Int) -> [Double] {
        var row = [1.0]
        for f in hz {
            let phase = 2 * .pi * f * Double(n) / rate
            row += [cos(phase), sin(phase)]
        }
        return row
    }
    var a = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: m)
    for (n, value) in x.enumerated() {
        let row = basis(n)
        for i in 0..<m {
            for j in 0..<m { a[i][j] += row[i] * row[j] }
            a[i][m] += row[i] * value
        }
    }
    // Gaussian elimination with partial pivoting on the normal equations.
    for column in 0..<m {
        let pivot = (column..<m).max { abs(a[$0][column]) < abs(a[$1][column]) }!
        a.swapAt(column, pivot)
        for r in 0..<m where r != column {
            let factor = a[r][column] / a[column][column]
            for k in column...m { a[r][k] -= factor * a[column][k] }
        }
    }
    let solution = (0..<m).map { a[$0][m] / a[$0][$0] }
    return hz.indices.map { k in hypot(solution[1 + 2 * k], solution[2 + 2 * k]) }
}

/// The left channel of interleaved stereo `frames`.
private func left(_ x: ArraySlice<Float>, frames: Range<Int>) -> [Double] {
    frames.map { Double(x[x.startIndex + 2 * $0]) }
}

private func db(_ ratio: Double) -> Double { 20 * log10(ratio) }

/// Where `a` and `b` first differ, or nil when they are the same length and agree throughout.
private func firstDifference<T>(_ a: [T], _ b: [T], _ same: (T, T) -> Bool) -> Int? {
    if let i = zip(a, b).enumerated().first(where: { !same($0.element.0, $0.element.1) })?.offset { return i }
    return a.count == b.count ? nil : min(a.count, b.count)
}

/// The least-squares gain of `y` over `x`.
private func gain(_ y: [Double], over x: [Double]) -> Double {
    zip(y, x).map { $0 * $1 }.reduce(0, +) / x.map { $0 * $0 }.reduce(0, +)
}

// MARK: - Rig

@MainActor
private final class SilentNowPlaying: NowPlayingPublishing {
    var onCommand: ((RemoteCommand) -> Void)?
    func show(_ item: QueueItem, elapsed: Duration, playing: Bool) {}
    func clear() {}
}

/// A player on a `FakeOutput`. The test plays the render thread by pulling.
@MainActor
private final class SoundRig {
    let session = FakeSession()
    let output = FakeOutput()
    let player: Player
    private(set) var pulled = 0

    init() {
        let output = output
        player = Player(
            session: session, makeOutput: { output }, capabilities: OutputCapabilities(int32Passthrough: false),
            nowPlaying: SilentNowPlaying(), makeDecoder: toneDecoder)
    }

    /// One render call of `frames` frames; returns the real frames.
    @discardableResult
    func pullOnce(_ frames: Int = 512) -> Int {
        let n = output.pull(frames: frames)
        pulled += n
        return n
    }

    /// Pulls until `frames` more real frames have been pulled, in calls of at most 512. Paced so the decode thread
    /// stays ahead: a chain runs over every frame handed to iOS, underrun silence included, so a capture measured
    /// through one must have no underruns (each test that measures checks `underruns`).
    func pull(_ frames: Int) async -> Bool {
        let target = pulled + frames
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(20))
        while pulled < target {
            guard ContinuousClock.now < deadline else { return false }
            if pullOnce(min(512, target - pulled)) == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                try? await Task.sleep(for: .microseconds(300))
            }
        }
        return true
    }

    /// Pulls (paced as `pull`) until `done()` holds.
    func pump(until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(20))
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            if pullOnce() == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                try? await Task.sleep(for: .microseconds(300))
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

    /// Plays `items` and waits, without pulling, for the first to start: its `trackStarted` is due at frame 0.
    func play(_ items: [QueueItem]) async -> Bool {
        await player.play(items, startingAt: 0)
        return await eventually { player.status == .playing }
    }

    /// Plays `items` to the end with `settings` and returns everything captured.
    func render(_ items: [QueueItem], with settings: SoundSettings) async -> [Float] {
        player.setSound(settings)
        await player.play(items, startingAt: 0)
        #expect(await pump { player.status == .ended }, "status: \(player.status)")
        return output.capturedFloat
    }

    /// Frames of underrun silence in the current pipeline.
    var underruns: Int64 { player.pipeline?.underrunFrames ?? 0 }
}

/// A flag a test thread polls.
private final class Flag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .acquiring) }
    func set() { value.store(true, ordering: .releasing) }
}

// MARK: - Tests

/// The Sound chain in the render path (Task 7): after the ring or the scrub voice, before iOS. Pure must stay
/// bit-exact; anything else is heard within a render call, and compiled for the rate it plays at.
///
/// Serialized: every test runs decode threads and a pull loop, and waits on wall-clock deadlines.
@MainActor @Suite(.serialized) struct SoundPipelineTests {
    /// Pure (the default) hands iOS exactly what it handed it before the chain existed: `PlayerTests`'
    /// `resumeContinuesFromPausedFrameBitExact` capture, with `setSound(SoundSettings())` before the start, after a
    /// chain was set and taken off again while stopped, and again mid-play.
    @Test func pureStaysBitExact() async {
        let f = Fixtures.named("s24-48000")
        let rig = SoundRig()
        rig.player.setSound(peak(1_000, 6))
        rig.player.setSound(SoundSettings())
        #expect(await rig.play([fixtureItem("s24-48000")]))
        rig.player.setSound(SoundSettings())
        #expect(await rig.pull(1500 - rig.pulled))
        rig.player.pause()
        #expect(rig.player.position == .microseconds(31_250))
        rig.player.resume()
        #expect(await rig.eventually { rig.player.status == .playing })
        rig.player.setSound(SoundSettings())
        #expect(await rig.pump { rig.player.status == .ended })
        let want = Fixtures.rawSamples(f).map { Float($0) * 0x1p-23 }
        let got = rig.output.capturedFloat
        #expect(got.count == want.count)
        let first = firstDifference(got, want) { $0.bitPattern == $1.bitPattern }
        #expect(first == nil, "first difference at sample \(first ?? -1)")
        #expect(rig.player.signal.indicator == .pure)
    }

    /// Pure through an Int32 client (a 32-bit source with passthrough): the chain is converted through Float32 only
    /// where it plays. A chain on, then Pure again: from the end of its 10 ms fade (480 frames into the next call,
    /// whose last 32 frames the runner leaves alone), every word is the source's again, low bits and all.
    @Test func pureStaysBitExactThroughAnInt32Client() async {
        let output = FakeOutput()
        let pipeline = PlaybackPipeline(
            output: output, capabilities: OutputCapabilities(int32Passthrough: true), negotiateRate: { $0 },
            makeDecoder: toneDecoder)
        pipeline.setSound(trim(-6))
        await pipeline.start([WordDecoder.item], at: 0, fromFrame: 0)
        var pulled = 0
        func pull(_ frames: Int) async -> Bool {
            let target = pulled + frames
            let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(20))
            while pulled < target {
                guard ContinuousClock.now < deadline else { return false }
                let n = output.pull(frames: min(512, target - pulled))
                pulled += n
                try? await Task.sleep(for: .microseconds(n == 0 ? 200 : 300))
            }
            return true
        }
        #expect(await pull(8_192))
        #expect(output.plans.map(\.client) == [.int32])
        // The chain played: half the level.
        let during = output.capturedInt32
        let x = (2_048..<6_144).map { Double(WordDecoder.value(Int64($0), channel: 0)) }
        let latency = SoundChain(trim(-6), sampleRate: 48_000, channels: 2).latencyFrames
        let y = (2_048..<6_144).map { Double(during[2 * ($0 + latency)]) }
        #expect(abs(db(gain(y, over: x)) + 6) < 0.01)

        pipeline.setSound(SoundSettings())
        let pureFrom = pulled + 480
        #expect(await pull(8_192))
        let after = Array(output.capturedInt32[(2 * pureFrom)...])
        let want = (pureFrom..<pulled).flatMap { n in (0..<2).map { WordDecoder.value(Int64(n), channel: $0) } }
        #expect(after.count == want.count)
        let first = firstDifference(after, want) { $0 == $1 }
        #expect(first == nil, "first difference at sample \(first ?? -1)")
        #expect(pipeline.underrunFrames == 0)
        pipeline.stop()
    }

    /// EQ +6 dB at 1 kHz on a 1 kHz tone: the level rises 6 dB, and the automatic headroom takes 6 dB off again, so 0
    /// dB ± 0.1. At 100 Hz, far from the peak, only the headroom acts. Set while stopped, so the start compiles it.
    @Test func eqChangesTheOutput() async {
        let settings = peak(1_000, 6)
        let tone = tones["eq"]!
        let rig = SoundRig()
        let captured = await rig.render([toneItem("eq")], with: settings)
        #expect(captured.count == Int(tone.frames) * 2)
        #expect(rig.underruns == 0)
        let span = 9_600..<38_400
        let measured = amplitudes(left(captured[...], frames: span), hz: [1_000, 100], rate: 48_000)
        let source = amplitudes(span.map { Double(tone.float(Int64($0))) }, hz: [1_000, 100], rate: 48_000)
        let chain = SoundChain(settings, sampleRate: 48_000, channels: 2)
        let filter = BiquadCoefficients.design(.peak, frequency: 1_000, gainDb: 6, q: 1.41, sampleRate: 48_000)
        let at1k = db(measured[0] / source[0])
        let at100 = db(measured[1] / source[1])
        let want100 = filter.magnitudeDb(atHz: 100, sampleRate: 48_000) + chain.preampDb
        #expect(abs(at1k) < 0.1, "1 kHz: \(at1k) dB")
        #expect(abs(at100 - want100) < 0.1, "100 Hz: \(at100) dB, want \(want100) dB")
        #expect(want100 < -5, "the headroom is what lowers 100 Hz: \(want100) dB")
        #expect(abs(chain.preampDb + 6) < 0.1, "headroom \(chain.preampDb) dB")
    }

    /// The strip names the blocks at work: EQ and the limiter that joins it.
    @Test func stripSaysProcessing() async {
        let rig = SoundRig()
        rig.player.setSound(peak(1_000, 6))
        #expect(rig.player.signal.activeProcessing == ["EQ", "Limiter"])
        #expect(rig.player.signal.indicator == .idle)
        #expect(await rig.play([toneItem("steady")]))
        #expect(rig.player.signal.indicator == .processing(2))
        rig.player.setSound(SoundSettings())
        #expect(rig.player.signal.indicator == .pure)
        rig.player.setSound(peak(1_000, 6))
        #expect(rig.player.signal.indicator == .processing(2))
        // Clamped on the way in.
        var wild = trim(40)
        wild.eq.bands = [EQBand(type: .peak, frequency: 90_000, gainDb: 99, q: 0)]
        rig.player.setSound(wild)
        #expect(rig.player.sound == wild.clamped())
        #expect(rig.player.sound.preamp.trimDb == 12)
        rig.player.pause()
    }

    /// A change is heard in the very next 512-frame render call, from a steady state: Pure to a chain, then one chain
    /// to another. The new chain primes for its latency (unheard, so those frames are still the old sound, exactly),
    /// then fades in over 10 ms.
    ///
    /// From a steady state only. A change that lands while an earlier one is still fading waits for that fade, at most
    /// a latency plus 10 ms (567 frames, 11.8 ms, at 48 kHz), so it can start just past the next call.
    @Test func heardWithinOneBuffer() async {
        let tone = tones["steady"]!
        let rig = SoundRig()
        #expect(await rig.play([toneItem("steady")]))
        #expect(await rig.pull(8_192 - rig.pulled))
        let x = { (n: Int) in Double(tone.float(Int64(n))) }

        // Pure → trim −6 dB.
        rig.player.setSound(trim(-6))
        let latency = SoundChain(trim(-6), sampleRate: 44_100, channels: 2).latencyFrames
        let start = rig.pulled
        #expect(rig.pullOnce() == 512)
        let pull = left(rig.output.capturedFloat[...], frames: start..<(start + 512))
        let dry = (start..<(start + 512)).map(x)
        let firstChange = firstDifference(pull, dry) { $0 == $1 }
        #expect(firstChange.map { $0 >= latency && $0 < latency + 8 } == true, "first change at \(firstChange ?? -1)")
        let biggest = zip(pull, dry).map { abs($0 - $1) }.max() ?? 0
        #expect(biggest > 0.05, "largest change \(biggest)")

        // Settled at −6 dB (delayed by the latency) → trim −12 dB.
        #expect(await rig.pull(8_192))
        let before = rig.pulled
        let settled = left(rig.output.capturedFloat[...], frames: (before - 1_024)..<before)
        let settledDry = ((before - 1_024)..<before).map { x($0 - latency) }
        #expect(abs(db(gain(settled, over: settledDry)) + 6) < 0.01)
        rig.player.setSound(trim(-12))
        #expect(rig.pullOnce() == 512)
        let next = left(rig.output.capturedFloat[...], frames: before..<(before + 512))
        let nextDry = (before..<(before + 512)).map { x($0 - latency) }
        let priming = gain(Array(next[0..<latency]), over: Array(nextDry[0..<latency]))
        let ending = gain(Array(next[448..<512]), over: Array(nextDry[448..<512]))
        #expect(abs(db(priming) + 6) < 0.01, "while priming: \(db(priming)) dB")
        #expect(db(ending) < -10, "by the end of the call: \(db(ending)) dB")
        #expect(rig.underruns == 0)
        rig.player.pause()
    }

    /// Review Focus 1: a 44.1 kHz item, then a 96 kHz one, through a 10 kHz peak of +6 dB (automatic headroom off).
    /// The second item's 10 kHz level is +6 dB ± 0.1 over its own flat render, which only a filter designed for 96 kHz
    /// gives: the 44.1 kHz design would put the peak at 21.8 kHz.
    @Test func recompiledAtRateChange() async {
        let settings = peak(10_000, 6, autoHeadroom: false)
        let items = [toneItem("rate-44k"), toneItem("rate-96k")]
        let firstFrames = Int(tones["rate-44k"]!.frames)
        let shaped = SoundRig()
        let withChain = await shaped.render(items, with: settings)
        #expect(shaped.output.plans.map(\.clientSampleRate) == [44_100, 96_000])
        let flat = SoundRig()
        let withoutChain = await flat.render(items, with: SoundSettings())
        #expect(withChain.count == withoutChain.count)
        #expect(withChain.count == 2 * (firstFrames + Int(tones["rate-96k"]!.frames)))

        let span = 4_800..<43_200
        let second = withChain[(2 * firstFrames)...]
        let secondFlat = withoutChain[(2 * firstFrames)...]
        let level = amplitudes(left(second, frames: span), hz: [10_000], rate: 96_000)[0]
        let flatLevel = amplitudes(left(secondFlat, frames: span), hz: [10_000], rate: 96_000)[0]
        let rise = db(level / flatLevel)
        #expect(abs(rise - 6) < 0.1, "10 kHz at 96 kHz: \(rise) dB")
        // What a 44.1 kHz design would have given there, so the test can tell the two apart.
        let stale = BiquadCoefficients.design(.peak, frequency: 10_000, gainDb: 6, q: 1.41, sampleRate: 44_100)
            .magnitudeDb(atHz: 10_000, sampleRate: 96_000)
        #expect(abs(stale - 6) > 1, "a stale design reads \(stale) dB")
        // The first item played through the 44.1 kHz design.
        let first = amplitudes(left(withChain[...], frames: 2_205..<19_845), hz: [10_000], rate: 44_100)[0]
        let firstFlat = amplitudes(left(withoutChain[...], frames: 2_205..<19_845), hz: [10_000], rate: 44_100)[0]
        let designed = BiquadCoefficients.design(.peak, frequency: 10_000, gainDb: 6, q: 1.41, sampleRate: 44_100)
            .magnitudeDb(atHz: 10_000, sampleRate: 44_100)
        #expect(abs(db(first / firstFlat) - designed) < 0.1, "10 kHz at 44.1 kHz: \(db(first / firstFlat)) dB")
        #expect(shaped.underruns == 0)
    }

    /// At a format change the chain starts afresh for the new format: nothing of the last track's tail (in the old
    /// chain's look-ahead and filters) reaches the next. The second item renders exactly as it does on its own.
    @Test func formatChangeHasNoTailBleed() async {
        let settings = peak(10_000, 6)
        let firstFrames = Int(tones["loud-44k"]!.frames)
        let queued = SoundRig()
        let both = await queued.render([toneItem("loud-44k"), toneItem("rate-96k")], with: settings)
        #expect(queued.output.plans.map(\.clientSampleRate) == [44_100, 96_000])
        let alone = SoundRig()
        let solo = await alone.render([toneItem("rate-96k")], with: settings)
        let second = Array(both[(2 * firstFrames)...])
        #expect(second.count == solo.count)
        let first = firstDifference(second, solo) { $0.bitPattern == $1.bitPattern }
        #expect(first == nil, "first difference at sample \(first ?? -1)")
        // The fresh chain's look-ahead starts empty: the second item opens on exactly its latency of silence.
        let latency = SoundChain(settings, sampleRate: 96_000, channels: 2).latencyFrames
        #expect(second.prefix(2 * latency).allSatisfy { $0 == 0 })
        #expect(second[2 * latency..<(2 * latency + 64)].contains { $0 != 0 })
    }

    /// Review M-3: a gapless join with the chain on keeps the chain running (no fresh start at the boundary): two
    /// halves of a tone render exactly as the whole does.
    @Test func gaplessJoinKeepsTheChainRunning() async {
        let settings = peak(1_000, 6)
        let joined = SoundRig()
        let halves = await joined.render([toneItem("join-a"), toneItem("join-b")], with: settings)
        #expect(joined.output.plans.count == 1, "one plan: a gapless join")
        let single = SoundRig()
        let whole = await single.render([toneItem("join-whole")], with: settings)
        #expect(halves.count == whole.count)
        let first = firstDifference(halves, whole) { $0.bitPattern == $1.bitPattern }
        #expect(first == nil, "first difference at sample \(first ?? -1)")
        #expect(joined.underruns == 0)
    }

    /// Review M-3: Pure through the scrub path (the voice under the hand, the motor, and the cross-fade back to the
    /// ring), on Float32 and Int32 clients: a source given the pipeline's runner in Pure hands out exactly what one
    /// with no runner does. Driven by hand on one thread, so both runs are the same run.
    @Test(arguments: [true, false])
    func pureStaysBitExactThroughAScrub(floatClient: Bool) {
        let rate = 44_100
        func value(_ frame: Int64) -> Float { Float(0.25 * sin(2 * .pi * 1_000 * Double(frame) / Double(rate))) }
        /// The ring's word for `frame`. An Int32 client's carries noise in its low bits, as a 32-bit source's does, so
        /// a Float32 round trip anywhere would show.
        func word(_ frame: Int64) -> UInt32 {
            let x = value(frame)
            guard !floatClient else { return x.bitPattern }
            let noise = Int32(truncatingIfNeeded: (frame &* 2_654_435_761) & 0xFF)
            return UInt32(bitPattern: Int32((Double(x) * 2_147_483_648).rounded()) &+ noise)
        }
        func run(sound: ChainRunner?) -> (words: [UInt32], scrubbed: Bool) {
            let format = AudioFormat(sampleRate: rate, bitsPerSample: 16, channels: 2)
            let tap = ScrubTap()
            let window = ScrubWindow(format: format, totalFrames: 441_000, at: 0)
            let filled: Int64 = 200_000
            for frame in 0..<filled {
                let slot = window.storage + Int(frame & Int64(window.mask)) * 2
                slot[0] = value(frame)
                slot[1] = value(frame)
            }
            window.validStart.store(0, ordering: .releasing)
            window.validEnd.store(filled, ordering: .releasing)
            let source = RenderSource(
                channels: 2, capacityFrames: 1 << 15, renderedFrames: 0, inheritingHoldsFrom: nil, clientRate: rate,
                floatClient: floatClient, scrub: tap, sound: sound)
            func feed(from frame: Int64, count: Int) {
                let words = (0..<(count * 2)).map { word(frame + Int64($0 / 2)) }
                _ = words.withUnsafeBufferPointer { source.write($0) }
            }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 512 * 2 * 4, alignment: 16)
            defer { buffer.deallocate() }
            var out: [UInt32] = []
            func pull() {
                _ = source.render(into: buffer, frames: 512)
                out += UnsafeBufferPointer(start: buffer.bindMemory(to: UInt32.self, capacity: 1_024), count: 1_024)
            }
            feed(from: 0, count: 16_384)
            for _ in 0..<4 { pull() }
            // The hand lands on a playing record and turns it at normal speed.
            tap.begin(window: window, anchorFrame: 2_048, anchorRendered: 2_048, startSpeed: 1, ringAllowed: true)
            let generation = tap.generation.load(ordering: .acquiring)
            for i in 0..<40 {
                tap.setHand(offsetFrames: Double(i + 1) * 512, speed: 1)
                pull()
            }
            // Let go: the motor, then the ring lined up 0.15 s ahead of the needle, as the player's seek does.
            tap.motorSecondsBits.store(0.05.bitPattern, ordering: .relaxed)
            tap.phase.store(ScrubTap.Phase.motor.rawValue, ordering: .releasing)
            for _ in 0..<20 { pull() }
            _ = source.requestFlush()
            pull()
            let target = Int64(tap.voicePosition.rounded(.down)) + 6_615
            feed(from: target, count: 16_384)
            tap.handoverFrame.store(target, ordering: .releasing)
            var calls = 0
            while tap.handedOver.load(ordering: .acquiring) != generation, calls < 200 {
                pull()
                calls += 1
            }
            for _ in 0..<8 { pull() }
            let scrubbed =
                tap.voiceStarted.load(ordering: .acquiring) == generation
                && tap.handedOver.load(ordering: .acquiring) == generation
            tap.retireWindow()
            return (out, scrubbed)
        }
        let with = run(sound: ChainRunner())
        let without = run(sound: nil)
        #expect(with.scrubbed && without.scrubbed, "the voice played and handed back to the ring")
        #expect(with.words.count == without.words.count)
        let first = firstDifference(with.words, without.words) { $0 == $1 }
        #expect(first == nil, "first difference at word \(first ?? -1)")
    }

    /// The meters read the chain: its peak since the last read, and nothing in Pure or with nothing playing.
    @Test func soundMetersFollowTheChain() async {
        let rig = SoundRig()
        #expect(rig.player.soundMeters.peakDbFS == -120)
        #expect(await rig.play([toneItem("steady")]))
        #expect(await rig.pull(4_096))
        #expect(rig.player.soundMeters.peakDbFS == -120, "Pure is never read")
        rig.player.setSound(trim(-6))
        #expect(await rig.pull(4_096))
        // That interval held the fade in, from the dry signal: read it away.
        _ = rig.player.soundMeters
        #expect(await rig.pull(4_096))
        let meters = rig.player.soundMeters
        // A 0.25 tone at −6 dB peaks at about −18 dBFS.
        #expect(abs(meters.peakDbFS - db(0.125)) < 0.1, "peak \(meters.peakDbFS)")
        #expect(meters.clipCount == 0)
        #expect(meters.gainReductionDb == 0)
        #expect(rig.player.soundMeters.peakDbFS == -120, "a second read starts a new interval")
        rig.player.pause()
        #expect(rig.player.soundMeters.peakDbFS == -120)
    }

    /// EQ is part of the sound, so the chain plays during a scrub too: the voice, at normal speed under the hand, comes
    /// out 6 dB down with a −6 dB trim.
    @Test func chainPlaysWhileScrubbing() async {
        let rig = SoundRig()
        rig.player.setSound(trim(-6))
        #expect(await rig.play([toneItem("steady")]))
        #expect(await rig.pull(8_820))
        #expect(rig.player.beginScrub())
        guard let tap = rig.player.pipeline?.scrubTap else {
            Issue.record("no pipeline")
            return
        }
        // Until the music under the needle is decoded, the ring plays on.
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(10))
        while tap.voiceStarted.load(ordering: .acquiring) != tap.generation.load(ordering: .acquiring),
            ContinuousClock.now < deadline
        {
            _ = await rig.pull(512)
            try? await Task.sleep(for: .milliseconds(3))
        }
        var offset = 0.0
        for _ in 0..<40 {
            offset += 512.0 / 44_100
            rig.player.scrub(offsetSeconds: offset, speed: 1)
            _ = await rig.pull(512)
            try? await Task.sleep(for: .milliseconds(3))
        }
        let captured = rig.output.capturedFloat
        let frames = captured.count / 2
        // RMS, not a fit at 1 kHz: the hand's pitch wanders a little.
        let tail = left(captured[...], frames: (frames - 8_192)..<frames)
        let rms = (tail.map { $0 * $0 }.reduce(0, +) / Double(tail.count)).squareRoot()
        let level = db(rms / (0.25 / 2.0.squareRoot()))
        #expect(abs(level + 6) < 0.5, "scrubbed at \(level) dB")
        rig.player.pause()
    }

    /// A render thread pulls on its own while the main actor changes the sound every millisecond or so, reading the
    /// meters too, all the way through a queue that crosses a format change: the installs, the format change's fresh
    /// start on the decode thread and the render thread never race (run under the thread sanitizer by
    /// `scripts/test.sh`).
    @Test func setSoundWhileRendering() async {
        let rig = SoundRig()
        let output = rig.output
        let stop = Flag()
        let done = Flag()
        Thread {
            while !stop.isSet {
                if output.pull(frames: 512) == 0 { usleep(100) } else { usleep(1_000) }
            }
            done.set()
        }.start()
        await rig.player.play([toneItem("stress-44k"), toneItem("stress-96k")], startingAt: 0)
        var changes = 0
        var whilePlaying = 0
        let deadline = ContinuousClock.now + LatencyBudget.scaled(.seconds(60))
        while ContinuousClock.now < deadline, rig.player.status != .ended {
            if rig.player.status == .playing { whilePlaying += 1 }
            rig.player.setSound(changes % 7 == 6 ? SoundSettings() : trim(Double(changes % 13) - 9))
            changes += 1
            _ = rig.player.soundMeters
            try? await Task.sleep(for: .milliseconds(1))
        }
        stop.set()
        #expect(await rig.eventually { done.isSet })
        #expect(rig.player.status == .ended)
        #expect(whilePlaying >= 20, "\(whilePlaying) of \(changes) changes while playing")
        #expect(output.plans.map(\.clientSampleRate) == [44_100, 96_000])
    }

    /// The level-matched A/B (Task 14) reaches the pipeline's runner. Held, the output is the original: a notch's
    /// 1 kHz comes back, at the original's balance with 100 Hz (one gain for the whole signal, the K-weighted match).
    /// A hold set before the start reaches the pipeline that start makes, and a pause and resume keeps it.
    @Test func abBypassPlaysTheOriginal() async {
        let notch = sound {
            $0.eq = EQSettings(
                enabled: true, mode: .parametric, bands: [EQBand(type: .notch, frequency: 1_000, gainDb: 0, q: 4)])
        }
        let span = 28_800..<48_000
        let plain = SoundRig()
        let processed = await plain.render([toneItem("eq")], with: notch)
        let notched = amplitudes(left(processed[...], frames: span), hz: [1_000, 100], rate: 48_000)
        #expect(notched[0] < 0.01, "processed, 1 kHz is at \(notched[0])")

        let rig = SoundRig()
        rig.player.setABBypass(true)
        #expect(rig.player.abBypass)
        let held = await rig.render([toneItem("eq")], with: notch)
        #expect(held.count == processed.count)
        let original = amplitudes(left(held[...], frames: span), hz: [1_000, 100], rate: 48_000)
        #expect(original[0] > 0.05, "held, 1 kHz is at \(original[0])")
        #expect(abs(original[0] / original[1] - 2) < 0.01, "held, 1 kHz over 100 Hz is \(original[0] / original[1])")

        // Live: the playing pipeline follows, a pause and resume (a new pipeline) keeps the hold, and a release ends it.
        #expect(await rig.play([toneItem("steady")]))
        #expect(rig.player.pipeline?.abBypass == true)
        rig.player.setABBypass(false)
        #expect(rig.player.pipeline?.abBypass == false)
        rig.player.setABBypass(true)
        rig.player.pause()
        rig.player.resume()
        #expect(await rig.eventually { rig.player.status == .playing })
        #expect(rig.player.pipeline?.abBypass == true)
        rig.player.setABBypass(false)
        #expect(rig.player.pipeline?.abBypass == false)
        rig.player.pause()
    }
}
