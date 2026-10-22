import Foundation
import Synchronization
import Testing

@testable import PFDSP

/// The level-matched A/B comparison (Task 14): held, the runner plays the original, lined up with the chain's output
/// and brought to its K-weighted loudness; released, the processed signal again, each switch a 20 ms crossfade.
///
/// Loudness is read with BS.1770-4's own 48 kHz K-weighting coefficients (its tables 1 and 2), in a filter written
/// here, so the measure shares nothing with `LoudnessMatcher`'s design. Clicks are the largest sample step against the
/// tone's own slope, as in `SoundChainTests`.
@Suite("Level-matched A/B")
struct LoudnessMatcherTests {
    static let rate = SoundChainTests.rate

    // MARK: Signals and measures

    /// Uniform white noise in ±`amplitude`, the same on every run for a seed.
    static func noise(frames: Int, channels: Int = 2, amplitude: Double, seed: UInt64 = 1) -> [Float] {
        var state = seed
        var x = [Float](repeating: 0, count: frames * channels)
        for i in x.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u = Double(state >> 11) / Double(UInt64(1) << 53)
            x[i] = Float(amplitude * (2 * u - 1))
        }
        return x
    }

    /// BS.1770-4's K-weighting at 48 kHz, its tables 1 (the pre-filter) and 2 (the RLB high-pass).
    static let tableShelf = BiquadCoefficients(
        b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241,
        a2: 0.73248077421585)
    static let tableHighPass = BiquadCoefficients(
        b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)

    /// A second-order section in transposed direct form II, written here rather than taken from PFDSP.
    private struct Section {
        let c: BiquadCoefficients
        var z1 = 0.0
        var z2 = 0.0

        init(_ c: BiquadCoefficients) { self.c = c }

        mutating func run(_ x: Double) -> Double {
            let y = c.b0 * x + z1
            z1 = c.b1 * x - c.a1 * y + z2
            z2 = c.b2 * x - c.a2 * y
            return y
        }
    }

    /// The K-weighted loudness of frames `start..<end` of interleaved `x`, in LKFS: −0.691 + 10·log10 of the channels'
    /// summed mean squares. The filters run from frame 0, so they have settled by the span.
    static func loudness(_ x: [Float], channels: Int = 2, from start: Int, to end: Int) -> Double {
        var sum = 0.0
        for c in 0..<channels {
            var shelf = Section(tableShelf)
            var highPass = Section(tableHighPass)
            for frame in 0..<end {
                let y = highPass.run(shelf.run(Double(x[frame * channels + c])))
                if frame >= start { sum += y * y }
            }
        }
        return -0.691 + 10 * log10(sum / Double(end - start))
    }

    /// The normalised correlation of frames `start..<end` of `y` with `x` delayed by `lag` frames, every channel.
    static func correlation(_ y: [Float], _ x: [Float], lag: Int, from start: Int, to end: Int, channels: Int = 2)
        -> Double
    {
        var xy = 0.0
        var xx = 0.0
        var yy = 0.0
        for frame in start..<end {
            for c in 0..<channels {
                let a = Double(y[frame * channels + c])
                let b = Double(x[(frame - lag) * channels + c])
                xy += a * b
                xx += b * b
                yy += a * a
            }
        }
        return xy / (xx * yy).squareRoot()
    }

    /// The largest magnitude in frames `start..<end`.
    static func peak(_ y: [Float], from start: Int, to end: Int, channels: Int = 2) -> Double {
        y[(start * channels)..<(end * channels)].map { Double($0.magnitude) }.max() ?? 0
    }

    /// A broadband +6 dB EQ: a high shelf at 20 Hz, with the automatic headroom off, so the level rises by 6 dB.
    static let broadband = SoundChainTests.eq(
        [EQBand(type: .highShelf, frequency: 20, gainDb: 6, q: 0.707)], autoHeadroom: false)

    /// A coloured curve as the app plays it: the graphic EQ's Loudness preset, the automatic headroom on.
    static let loudnessPreset = SoundChainTests.settings {
        $0.eq = EQSettings(enabled: true, mode: .graphic, graphicGainsDb: EQPresets.all[4].gainsDb)
    }

    static func chain(_ s: SoundSettings, rate: Double = rate, channels: Int = 2) -> SoundChain {
        SoundChain(s, sampleRate: rate, channels: channels)
    }

    // MARK: The level match

    @Test("At 48 kHz the K-weighting is BS.1770-4's own (its tables 1 and 2)")
    func kWeightingIsBS1770() {
        let tuning = LoudnessMatcher.Tuning(sampleRate: 48_000)
        for (mine, table) in [(tuning.shelf, Self.tableShelf), (tuning.highPass, Self.tableHighPass)] {
            for (a, b) in [(mine.b0, table.b0), (mine.b1, table.b1), (mine.b2, table.b2), (mine.a1, table.a1)] {
                #expect(abs(a - b) < 1e-9, "\(mine) against \(table)")
            }
            #expect(abs(mine.a2 - table.a2) < 1e-9, "\(mine) against \(table)")
        }
    }

    @Test(
        "Held with a +6 dB broadband EQ (and a coloured curve), the original is within 0.5 LU of the processed signal",
        arguments: ["broadband", "loudnessPreset"])
    func bypassIsLevelMatched(_ curve: String) {
        let s = curve == "broadband" ? Self.broadband : Self.loudnessPreset
        let frames = 3 * 48_000
        let input = Self.noise(frames: frames, amplitude: 0.1)
        let processed = ChainRunner()
        let wetChain = Self.chain(s)
        processed.install(wetChain)
        let wet = SoundChainTests.run(processed, input)
        let compared = ChainRunner()
        compared.install(Self.chain(s))
        compared.abBypass.store(true, ordering: .relaxed)
        let held = SoundChainTests.run(compared, input)

        let start = 48_000
        let heldLoudness = Self.loudness(held, from: start, to: frames)
        let wetLoudness = Self.loudness(wet, from: start, to: frames)
        let original = Self.loudness(input, from: start, to: frames)
        #expect(
            abs(heldLoudness - wetLoudness) < 0.5,
            "held \(heldLoudness) LKFS, processed \(wetLoudness), the original unmatched \(original)")
        // Matching had work to do: unmatched, the original is more than 0.5 LU away.
        #expect(abs(original - wetLoudness) > 0.5, "original \(original) LKFS, processed \(wetLoudness)")
        // What plays is the original: the input delayed by the chain's latency, times one slowly moving gain.
        let latency = wetChain.latencyFrames
        let lined = Self.correlation(held, input, lag: latency, from: start, to: frames)
        #expect(lined > 0.9999, "correlation with the original at the chain's latency: \(lined)")
    }

    @Test("Toggling A/B on a tone never steps past 1.5 × the tone's slope, though the two differ in phase")
    func togglingIsClickFree() {
        // A low shelf under the tone: at 440 Hz it boosts by about 5 dB and shifts the phase, so a hard switch would
        // step, and an unmatched one would jump in level.
        let s = SoundChainTests.eq([EQBand(type: .lowShelf, frequency: 1000, gainDb: 6, q: 0.707)], autoHeadroom: false)
        let block = 256
        let settle = 188
        let every = 8
        let toggles = 40
        let blocks = settle + every * toggles + 40
        let input = SoundChainTests.tone(440, amplitude: 0.25, frames: blocks * block)
        let runner = ChainRunner()
        runner.install(Self.chain(s))
        let output = SoundChainTests.run(runner, input, block: block) { index in
            guard index >= settle, index < settle + every * toggles, (index - settle) % every == 0 else { return }
            runner.abBypass.store((index - settle) / every % 2 == 0, ordering: .relaxed)
        }
        let plainRunner = ChainRunner()
        plainRunner.install(Self.chain(s))
        let plain = SoundChainTests.run(plainRunner, input, block: block)

        let from = (settle - 20) * block
        let ratios = SoundChainTests.largestStepRatios(Array(output[(from * 2)...]), channels: 2, hz: 440)
        #expect(ratios.local < 1.5, "largest step \(ratios.local) × the local slope")
        #expect(ratios.global < 1.5, "largest step \(ratios.global) × the loudest slope")

        // Each hold was heard: it plays the original's phase, not the shelf's. (From 21 ms in: the crossfade is over.)
        let heldFrom = (settle + 4) * block
        let heldTo = (settle + every) * block
        var apart = 0.0
        for i in (heldFrom * 2)..<(heldTo * 2) { apart = max(apart, Double(abs(output[i] - plain[i]))) }
        #expect(apart > 0.05, "held, the output strays at most \(apart) from the processed one")
        // At the processed level: one tone, so the K-weighted match is a match of amplitudes.
        let heldPeak = Self.peak(output, from: heldFrom, to: heldTo)
        let plainPeak = Self.peak(plain, from: heldFrom, to: heldTo)
        #expect(abs(20 * log10(heldPeak / plainPeak)) < 0.1, "held peak \(heldPeak), processed \(plainPeak)")
    }

    @Test("Held across a chain install, the original stays lined up with the chain's output and is matched anew")
    func bypassStaysAlignedAcrossAnInstall() {
        let first = Self.broadband
        let second = SoundChainTests.eq([EQBand(type: .peak, frequency: 2000, gainDb: 9, q: 0.7)], autoHeadroom: false)
        let block = 256
        let seconds = 4
        let frames = seconds * 48_000
        let input = Self.noise(frames: frames, amplitude: 0.1, seed: 7)
        let runner = ChainRunner()
        let firstChain = Self.chain(first)
        let latency = firstChain.latencyFrames
        runner.install(firstChain)
        let holdAt = 48_000 / 2 / block
        let installAt = 2 * 48_000 / block
        let output = SoundChainTests.run(runner, input, block: block) { index in
            if index == holdAt { runner.abBypass.store(true, ordering: .relaxed) }
            if index == installAt { runner.install(Self.chain(second)) }
        }
        let wetFirst = {
            let r = ChainRunner()
            r.install(Self.chain(first))
            return SoundChainTests.run(r, input, block: block)
        }()
        let wetSecond = {
            let r = ChainRunner()
            r.install(Self.chain(second))
            return SoundChainTests.run(r, input, block: block)
        }()

        // Lined up in every 10 ms window from a tenth of a second after the press, through the install: with the
        // original at the chain's latency, and with neither frame either side of it (white noise).
        var worst = 1.0
        var nearest = 0.0
        for start in stride(from: (holdAt * block) + 4_800, to: frames - 480, by: 480) {
            worst = min(worst, Self.correlation(output, input, lag: latency, from: start, to: start + 480))
            for lag in [latency - 1, latency + 1] {
                nearest = max(nearest, abs(Self.correlation(output, input, lag: lag, from: start, to: start + 480)))
            }
        }
        #expect(worst > 0.9999, "lowest correlation at the latency: \(worst)")
        #expect(nearest < 0.25, "highest correlation a frame off: \(nearest)")

        // Matched to each chain in turn: the windows kept moving while the hold went on.
        let before = Self.loudness(output, from: 3 * 48_000 / 2, to: 2 * 48_000)
        let firstLoudness = Self.loudness(wetFirst, from: 3 * 48_000 / 2, to: 2 * 48_000)
        let after = Self.loudness(output, from: 7 * 48_000 / 2, to: frames)
        let secondLoudness = Self.loudness(wetSecond, from: 7 * 48_000 / 2, to: frames)
        #expect(abs(before - firstLoudness) < 0.5, "held \(before) LKFS before the install, processed \(firstLoudness)")
        #expect(abs(after - secondLoudness) < 0.5, "held \(after) LKFS after the install, processed \(secondLoudness)")
        let apart = secondLoudness - firstLoudness
        #expect(abs(apart) > 2, "the two chains are \(apart) LU apart")
    }

    @Test("Held across a format change (a reset to a 96 kHz chain), the original opens on its latency, lined up")
    func bypassStaysAlignedAcrossAFormatChange() {
        let runner = ChainRunner()
        runner.install(Self.chain(Self.broadband))
        runner.abBypass.store(true, ordering: .relaxed)
        _ = SoundChainTests.run(runner, Self.noise(frames: 48_000, amplitude: 0.1, seed: 3))
        let fast = Self.chain(Self.broadband, rate: 96_000)
        let latency = fast.latencyFrames
        runner.reset(to: fast)
        let frames = 96_000
        let input = Self.noise(frames: frames, amplitude: 0.1, seed: 4)
        let output = SoundChainTests.run(runner, input)
        #expect(output[0..<(latency * 2)].allSatisfy { $0 == 0 }, "the first \(latency) frames are not silent")
        let lined = Self.correlation(output, input, lag: latency, from: latency + 960, to: frames)
        #expect(lined > 0.9999, "correlation at the 96 kHz chain's latency: \(lined)")
        let loud = Self.loudness(output, from: frames / 2, to: frames)
        let original = Self.loudness(input, from: frames / 2, to: frames)
        // K-weighting at 96 kHz differs a little from the 48 kHz tables this reads with, alike for both.
        #expect(abs(loud - original - 6) < 0.5, "the held original reads \(loud - original) LU over itself")
    }

    // MARK: Silence and faults

    /// Feeds `dry` (lined up) and `wet` through `matcher` in pieces of 512 frames, with `scale` multiplied in place.
    static func feed(
        _ matcher: LoudnessMatcher, dry: [Double], wet: [Float], scale: inout [Double], channels: Int = 2
    ) {
        let frames = dry.count / channels
        dry.withUnsafeBufferPointer { d in
            wet.withUnsafeBufferPointer { w in
                scale.withUnsafeMutableBufferPointer { s in
                    var done = 0
                    while done < frames {
                        let n = min(512, frames - done)
                        matcher.process(
                            dry: d.baseAddress! + done * channels, wet: w.baseAddress! + done * channels,
                            scale: s.baseAddress! + done * channels, frames: n, channels: channels)
                        done += n
                    }
                }
            }
        }
    }

    static func doubles(_ x: [Float]) -> [Double] { x.map(Double.init) }

    @Test("Silence on either side, or one side below the absolute gate, leaves the gain where it was, finite")
    func silenceLeavesTheGain() {
        let frames = 2 * 48_000
        let loud = Self.noise(frames: frames, amplitude: 0.25, seed: 11)
        let silence = [Float](repeating: 0, count: frames * 2)
        let faint = Self.noise(frames: frames, amplitude: 1e-5, seed: 12)
        let cases: [(name: String, dry: [Float], wet: [Float])] = [
            ("both silent", silence, silence),
            ("the original silent", silence, loud),
            ("the processed signal silent", loud, silence),
            ("the original at −100 dBFS", faint, loud),
        ]
        for c in cases {
            let matcher = LoudnessMatcher(sampleRate: Self.rate, maxFrames: 512, maxChannels: 2)
            var scale = [Double](repeating: 1, count: frames * 2)
            Self.feed(matcher, dry: Self.doubles(c.dry), wet: c.wet, scale: &scale)
            #expect(matcher.gain == 1, "\(c.name): gain \(matcher.gain)")
            #expect(matcher.targetGain == 1, "\(c.name): target \(matcher.targetGain)")
            #expect(scale.allSatisfy { $0 == 1 }, "\(c.name): the scaled frames moved")
        }
    }

    @Test("A gain the match would take past ±12 dB stops at the clamp")
    func gainIsClamped() {
        let frames = 2 * 48_000
        let loud = Self.noise(frames: frames, amplitude: 0.25, seed: 21)
        // −50 dBFS: above the −70 LKFS gate, and 38 dB below the loud side.
        let quiet = Self.noise(frames: frames, amplitude: 0.003, seed: 22)
        for (dry, wet, expected) in [(quiet, loud, 12.0), (loud, quiet, -12.0)] {
            let matcher = LoudnessMatcher(sampleRate: Self.rate, maxFrames: 512, maxChannels: 2)
            var scale = [Double](repeating: 1, count: frames * 2)
            Self.feed(matcher, dry: Self.doubles(dry), wet: wet, scale: &scale)
            let limit = pow(10, expected / 20)
            #expect(matcher.targetGain == limit, "target \(20 * log10(matcher.targetGain)) dB")
            #expect(abs(matcher.gain - limit) < 1e-9 * limit, "gain \(20 * log10(matcher.gain)) dB")
            #expect(abs(scale[scale.count - 1] - limit) < 1e-9 * limit)
            #expect(scale.allSatisfy { $0.isFinite && $0 <= max(limit, 1) && $0 >= min(limit, 1) })
        }
    }

    @Test("NaN and infinite samples count as silence: the gain stays finite, and matches again once they stop")
    func nonFiniteSamplesAreSilence() {
        let frames = 2 * 48_000
        var dry = Self.doubles(Self.noise(frames: frames, amplitude: 0.1, seed: 31))
        // The processed signal is the original at +6.02 dB (twice the amplitude).
        var wet = dry.map { Float(2 * $0) }
        for i in stride(from: 0, to: frames, by: 97) { dry[i] = .nan }
        for i in stride(from: 5, to: frames, by: 101) { wet[i] = .infinity }
        for i in stride(from: 9, to: frames, by: 103) { dry[i] = -.infinity }
        for i in stride(from: 13, to: frames, by: 89) { wet[i] = -.nan }
        let matcher = LoudnessMatcher(sampleRate: Self.rate, maxFrames: 512, maxChannels: 2)
        var scale = [Double](repeating: 0.5, count: frames * 2)
        Self.feed(matcher, dry: dry, wet: wet, scale: &scale)
        #expect(matcher.gain.isFinite && matcher.targetGain.isFinite)
        #expect(scale.allSatisfy { $0.isFinite })
        // Clean again: the window refills and the gain settles on 2.
        let clean = Self.doubles(Self.noise(frames: frames, amplitude: 0.1, seed: 32))
        var rest = [Double](repeating: 1, count: frames * 2)
        Self.feed(matcher, dry: clean, wet: clean.map { Float(2 * $0) }, scale: &rest)
        #expect(abs(matcher.gain - 2) < 1e-4, "gain \(matcher.gain)")
    }

    @Test("Held over silence, the runner plays exact silence: no NaN, no gain run away")
    func silenceThroughTheRunner() {
        let runner = ChainRunner()
        runner.install(Self.chain(Self.broadband))
        runner.abBypass.store(true, ordering: .relaxed)
        let output = SoundChainTests.run(runner, [Float](repeating: 0, count: 48_000 * 2))
        #expect(output.allSatisfy { $0 == 0 })
        #expect(runner.meters.matchGainDb == 0)
    }

    // MARK: Pure, the ceiling, the meters

    @Test("In Pure, a held A/B changes nothing: bit-identical, and the runner stays idle")
    func pureIgnoresTheBypass() {
        let input = Self.noise(frames: 4_096, amplitude: 0.5, seed: 41)
        let never = ChainRunner()
        never.abBypass.store(true, ordering: .relaxed)
        #expect(SoundChainTests.identical(SoundChainTests.run(never, input)[...], input[...]))
        #expect(never.isIdle)

        // After a chain faded out to Pure under a held A/B, the release runs its course, then Pure is exact again.
        let after = ChainRunner()
        after.install(Self.chain(Self.broadband))
        after.abBypass.store(true, ordering: .relaxed)
        _ = SoundChainTests.run(after, Self.noise(frames: 48_000, amplitude: 0.1, seed: 42))
        after.install(nil)
        let release = SoundChainTests.run(after, Self.noise(frames: 4_800, amplitude: 0.1, seed: 43))
        #expect(release.allSatisfy { $0.isFinite })
        let later = SoundChainTests.run(after, input)
        #expect(SoundChainTests.identical(later[...], input[...]))
        #expect(after.isIdle)
    }

    @Test("Raised to match a louder chain, the original passes the same true-peak ceiling as the processed signal")
    func originalKeepsTheCeiling() {
        // Quiet noise with a loud 1 kHz burst every half second: its loudness is the noise's, its peaks the bursts'.
        // Trim +9 dB: the chain's limiter holds the bursts at −0.3 dBTP, the noise rises 9 dB, so the original is
        // raised by about 8 dB, which would take the bursts far past full scale.
        let s = SoundChainTests.settings { $0.preamp.trimDb = 9 }
        let frames = 2 * 48_000
        var input = Self.noise(frames: frames, amplitude: 0.05, seed: 51)
        for start in stride(from: 12_000, to: frames - 48, by: 24_000) {
            for n in 0..<48 {
                let window = 0.5 - 0.5 * cos(2 * .pi * Double(n) / 47)
                let x = 0.85 * window * sin(2 * .pi * 1_000 * Double(n) / Self.rate)
                input[(start + n) * 2] += Float(x)
                input[(start + n) * 2 + 1] -= Float(x)
            }
        }
        let runner = ChainRunner()
        runner.install(Self.chain(s))
        runner.abBypass.store(true, ordering: .relaxed)
        let output = SoundChainTests.run(runner, input)
        let gainDb = runner.meters.matchGainDb
        #expect(gainDb > 6, "the original is raised by \(gainDb) dB only")
        #expect(0.85 * pow(10, gainDb / 20) > 1.5, "the raised bursts would not pass full scale")
        let ceiling = pow(10, LimiterSettings().ceilingDbTP / 20)
        let loudest = Self.peak(output, from: 0, to: frames)
        #expect(loudest <= ceiling * (1 + 1e-6), "the held original peaks at \(20 * log10(loudest)) dBFS")
    }

    @Test("The meters report the gain the original gets: +6.02 dB under a 6.02 dB trim")
    func metersReportTheMatch() {
        let s = SoundChainTests.settings { $0.preamp.trimDb = 20 * log10(2.0) }
        let runner = ChainRunner()
        runner.install(Self.chain(s))
        _ = SoundChainTests.run(runner, Self.noise(frames: 48_000, amplitude: 0.05, seed: 61))
        // Measured whether held or not, so the gain is ready the moment a finger lands.
        #expect(abs(runner.meters.matchGainDb - 20 * log10(2.0)) < 0.01, "\(runner.meters.matchGainDb) dB")
        #expect(SoundMeters(peakDbFS: -120, clipCount: 0, gainReductionDb: 0).matchGainDb == 0)
    }

    // MARK: Concurrency

    @Test("A render thread runs flat out while the A/B is held and released and chains are installed: always finite")
    func rendersWhileComparing() {
        let runner = ChainRunner(maxFrames: 512)
        let shared = SoundChainTests.Shared()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            var buffer = [Float](repeating: 0, count: 256 * 2)
            var frame = 0
            while !shared.stop.load(ordering: .acquiring) {
                for i in 0..<256 {
                    let x = Float(0.5 * sin(2 * .pi * 440 * Double(frame + i) / Self.rate))
                    buffer[2 * i] = x
                    buffer[2 * i + 1] = -x
                }
                frame += 256
                buffer.withUnsafeMutableBufferPointer { runner.process($0.baseAddress!, frames: 256, channels: 2) }
                if !buffer.allSatisfy({ $0.isFinite }) { shared.nonFinite.add(1, ordering: .relaxed) }
                shared.blocks.add(1, ordering: .relaxed)
            }
            finished.signal()
        }
        thread.start()
        for i in 0..<300 {
            runner.abBypass.store(i % 3 != 0, ordering: .relaxed)
            if i % 11 == 5 {
                runner.install(nil)
            } else if i % 4 == 0 {
                let db = Double(i % 25) - 12
                runner.install(Self.chain(SoundChainTests.settings { $0.preamp.trimDb = db }))
            }
            _ = runner.meters
            Thread.sleep(forTimeInterval: 0.0005)
        }
        shared.stop.store(true, ordering: .releasing)
        finished.wait()
        #expect(shared.blocks.load(ordering: .relaxed) > 0)
        #expect(shared.nonFinite.load(ordering: .relaxed) == 0)
    }
}
