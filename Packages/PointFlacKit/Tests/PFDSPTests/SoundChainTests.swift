import Accelerate
import Foundation
import Synchronization
import Testing

@testable import PFDSP

/// The compiled Sound chain and the runner that swaps chains on the render thread without a click.
///
/// Levels are checked against references built offline from the same parts (Task 1's biquads, Task 3's headroom and
/// the limiter's delay). Clicks are the largest sample step against the tone's own slope. True peaks are read on an
/// FFT-exact reconstruction of a periodic output, which shares no code or filter with the limiter's detector.
///
/// Tests that check chains are freed hold weak references to their own chains, so chains other suites make in
/// parallel can't affect them.
@Suite("Sound chain")
struct SoundChainTests {
    static let rate = 48_000.0

    /// Settings with Pure off and `edit` applied.
    static func settings(_ edit: (inout SoundSettings) -> Void = { _ in }) -> SoundSettings {
        var s = SoundSettings()
        s.pure = false
        edit(&s)
        return s
    }

    /// One parametric EQ band and nothing else.
    static func eq(_ bands: [EQBand], autoHeadroom: Bool = true) -> SoundSettings {
        settings {
            $0.eq = EQSettings(enabled: true, mode: .parametric, bands: bands)
            $0.preamp.autoHeadroom = autoHeadroom
        }
    }

    /// `frames` interleaved Float32 frames, filled by `sample(frame, channel)`.
    static func signal(frames: Int, channels: Int, _ sample: (Int, Int) -> Double) -> [Float] {
        var x = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels { x[frame * channels + channel] = Float(sample(frame, channel)) }
        }
        return x
    }

    /// A sine per channel, each at its own phase.
    static func tone(_ hz: Double, amplitude: Double, frames: Int, channels: Int = 2, rate: Double = rate) -> [Float] {
        signal(frames: frames, channels: channels) { frame, channel in
            amplitude * sin(2 * .pi * hz * Double(frame) / rate + Double(channel))
        }
    }

    /// Runs `input` through `runner` in blocks of `block` frames, calling `before(index)` ahead of each block.
    static func run(
        _ runner: ChainRunner, _ input: [Float], channels: Int = 2, block: Int = 256, before: (Int) -> Void = { _ in }
    ) -> [Float] {
        var io = input
        let frames = input.count / channels
        io.withUnsafeMutableBufferPointer { buffer in
            var done = 0
            var index = 0
            while done < frames {
                before(index)
                let n = min(block, frames - done)
                runner.process(buffer.baseAddress! + done * channels, frames: n, channels: channels)
                done += n
                index += 1
            }
        }
        return io
    }

    static func identical(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
    }

    /// Frames a Pure-to-chain install takes before the chain alone is heard: its latency, then the 10 ms fade.
    static func settled(_ chain: SoundChain) -> Int { chain.latencyFrames + chain.fadeFrames }

    /// A weak reference to a chain, to see that it was freed.
    final class Freed {
        weak var chain: SoundChain?
        init(_ chain: SoundChain) { self.chain = chain }
    }

    // MARK: Pure

    @Test("With no chain, process leaves every byte alone, NaN payloads included, and again once a chain fades out")
    func pureIsUntouched() {
        var noise = BiquadTests.WhiteNoise()
        func randomBits(_ count: Int) -> [Float] {
            var x = (0..<count).map { _ in
                Float(bitPattern: UInt32(truncatingIfNeeded: Int64((noise.next() + 1) * 2_147_483_647)))
            }
            let odd: [Float] = [
                .nan, Float(bitPattern: 0x7FC0_1234), Float(bitPattern: 0xFFA0_0001), .infinity, -.infinity, -0.0,
                .leastNonzeroMagnitude, -.leastNormalMagnitude, 3, -7,
            ]
            for (i, v) in odd.enumerated() { x[i * 37] = v }
            return x
        }
        let runner = ChainRunner()
        let input = randomBits(4_096)
        #expect(Self.identical(Self.run(runner, input)[...], input[...]), "never installed")
        runner.install(nil)
        #expect(Self.identical(Self.run(runner, input, block: 333)[...], input[...]), "after install(nil)")

        // A chain, then Pure again: once the fade to Pure is over, the bytes are untouched again.
        runner.install(
            SoundChain(
                Self.eq([EQBand(type: .peak, frequency: 1_000, gainDb: 6, q: 1)]), sampleRate: Self.rate, channels: 2))
        _ = Self.run(runner, Self.tone(1_000, amplitude: 0.5, frames: 4_096))
        runner.install(nil)
        _ = Self.run(runner, Self.tone(1_000, amplitude: 0.5, frames: 4_096))
        let again = randomBits(2_048)
        #expect(Self.identical(Self.run(runner, again, block: 100)[...], again[...]), "after a chain faded out")
        #expect(runner.meters.gainReductionDb == 0)
    }

    // MARK: Levels

    @Test("EQ +6 dB at 1 kHz equals the Task 1 biquad after the Task 3 headroom, delayed by the limiter, within 1e-6")
    func matchesOfflineFilters() {
        let s = Self.eq([EQBand(type: .peak, frequency: 1_000, gainDb: 6, q: 1)])
        let chain = SoundChain(s, sampleRate: Self.rate, channels: 2)
        let latency = chain.latencyFrames
        #expect(latency == TruePeakLimiter(channels: 2, sampleRate: Self.rate, ceilingDbTP: -0.3).latencyFrames)
        let headroom = SoundResponse.autoHeadroomDb(s, sampleRate: Self.rate)
        #expect(abs(headroom + 6) < 0.05)
        #expect(chain.preampDb == headroom)

        var noise = BiquadTests.WhiteNoise()
        let frames = 16_384
        let input = Self.signal(frames: frames, channels: 2) { frame, channel in
            0.2 * noise.next() + 0.25 * sin(2 * .pi * (channel == 0 ? 1_000 : 2_500) * Double(frame) / Self.rate)
        }
        let runner = ChainRunner()
        runner.install(chain)
        let output = Self.run(runner, input, block: 512)

        let gain = pow(10, headroom / 20)
        var worst = 0.0
        for channel in 0..<2 {
            var filter = Biquad(.design(.peak, frequency: 1_000, gainDb: 6, q: 1, sampleRate: Self.rate))
            let reference = (0..<frames).map { filter.process(Double(input[$0 * 2 + channel]) * gain) }
            for frame in Self.settled(chain)..<frames {
                worst = max(worst, abs(Double(output[frame * 2 + channel]) - reference[frame - latency]))
            }
        }
        #expect(worst <= 1e-6, "largest difference \(worst)")
        #expect(runner.meters.gainReductionDb == 0, "the limiter stays transparent")
    }

    @Test("With correction on, the preamp is the correction's preamp plus the auto headroom plus the trim (R4-T6a)")
    func appliesCorrectionPreamp() {
        let correctionBand = EQBand(type: .peak, frequency: 3_000, gainDb: 6, q: 2)
        let eqBand = EQBand(type: .peak, frequency: 1_000, gainDb: 6, q: 1)
        let s = Self.settings {
            $0.correction = CorrectionSettings(enabled: true, preampDb: -6, bands: [correctionBand])
            $0.eq = EQSettings(enabled: true, mode: .parametric, bands: [eqBand])
            $0.preamp.trimDb = -1.5
        }
        let headroom = SoundResponse.autoHeadroomDb(s, sampleRate: Self.rate)
        let expectedDb = -6 + headroom - 1.5
        let chain = SoundChain(s, sampleRate: Self.rate, channels: 2)
        #expect(abs(chain.preampDb - expectedDb) < 1e-12, "preamp \(chain.preampDb) dB, expected \(expectedDb) dB")

        var noise = BiquadTests.WhiteNoise()
        let frames = 16_384
        let input = Self.signal(frames: frames, channels: 2) { _, _ in 0.5 * noise.next() }
        let runner = ChainRunner()
        runner.install(chain)
        let output = Self.run(runner, input)
        let gain = pow(10, expectedDb / 20)
        var worst = 0.0
        var outputPower = 0.0
        var referencePower = 0.0
        for channel in 0..<2 {
            var correction = Biquad(.design(.peak, frequency: 3_000, gainDb: 6, q: 2, sampleRate: Self.rate))
            var equaliser = Biquad(.design(.peak, frequency: 1_000, gainDb: 6, q: 1, sampleRate: Self.rate))
            let reference = (0..<frames).map {
                equaliser.process(correction.process(Double(input[$0 * 2 + channel]) * gain))
            }
            for frame in Self.settled(chain)..<frames {
                let y = Double(output[frame * 2 + channel])
                let r = reference[frame - chain.latencyFrames]
                worst = max(worst, abs(y - r))
                outputPower += y * y
                referencePower += r * r
            }
        }
        #expect(worst <= 1e-6, "largest difference \(worst)")
        // Leaving out the correction's −6 dB would put the level 6 dB high; the curve's peak is under 0 dB instead.
        #expect(abs(10 * log10(outputPower / referencePower)) < 1e-4)
    }

    @Test("Non-finite settings never reach the audio: such bands are dropped and such gains count as 0 dB")
    func nonFiniteSettingsAreDropped() {
        let good = EQBand(type: .peak, frequency: 1_000, gainDb: 6, q: 1)
        let bad = [
            EQBand(type: .peak, frequency: .nan, gainDb: 6, q: 1),
            EQBand(type: .lowShelf, frequency: 200, gainDb: .nan, q: 0.7),
            EQBand(type: .highShelf, frequency: 8_000, gainDb: 3, q: .nan),
        ]
        let broken = Self.settings {
            $0.correction = CorrectionSettings(enabled: true, preampDb: .nan, bands: bad + [good])
            $0.eq = EQSettings(enabled: true, mode: .parametric, bands: [good] + bad)
            $0.tone = ToneSettings(enabled: true, bassDb: .nan, trebleDb: 3, tiltDb: .nan)
            $0.preamp.trimDb = .nan
            $0.limiter.ceilingDbTP = .nan
        }
        let clean = Self.settings {
            $0.correction = CorrectionSettings(enabled: true, preampDb: 0, bands: [good])
            $0.eq = EQSettings(enabled: true, mode: .parametric, bands: [good])
            $0.tone = ToneSettings(enabled: true, bassDb: 0, trebleDb: 3, tiltDb: 0)
        }
        let brokenChain = SoundChain(broken, sampleRate: Self.rate, channels: 2)
        let cleanChain = SoundChain(clean, sampleRate: Self.rate, channels: 2)
        #expect(brokenChain.preampDb.isFinite)
        #expect(brokenChain.preampDb == cleanChain.preampDb)

        var noise = BiquadTests.WhiteNoise()
        let input = Self.signal(frames: 8_192, channels: 2) { _, _ in 0.9 * noise.next() }
        let brokenRunner = ChainRunner()
        brokenRunner.install(brokenChain)
        let cleanRunner = ChainRunner()
        cleanRunner.install(cleanChain)
        let brokenOutput = Self.run(brokenRunner, input)
        #expect(brokenOutput.allSatisfy { $0.isFinite })
        #expect(Self.identical(brokenOutput[...], Self.run(cleanRunner, input)[...]))

        // A NaN graphic slider, too.
        var graphic = Self.settings { $0.eq = EQSettings(enabled: true, mode: .graphic) }
        graphic.eq.graphicGainsDb[3] = .nan
        let graphicRunner = ChainRunner()
        graphicRunner.install(SoundChain(graphic, sampleRate: Self.rate, channels: 2))
        #expect(Self.run(graphicRunner, input).allSatisfy { $0.isFinite })
    }

    // MARK: Installs

    /// The largest sample step of every channel of `output`, as a multiple of the steepest a sine at `hz` can be at
    /// the level around it (its amplitude over the neighbouring periods), and as a multiple of its steepest at the
    /// loudest level in the run (the plan's measure).
    static func largestStepRatios(_ output: [Float], channels: Int, hz: Double) -> (local: Double, global: Double) {
        let omega = 2 * .pi * hz / rate
        let period = Int((rate / hz).rounded(.up))
        let frames = output.count / channels
        var local = 0.0
        var global = 0.0
        for channel in 0..<channels {
            let y = (0..<frames).map { Double(output[$0 * channels + channel]) }
            let loudest = y.map(\.magnitude).max() ?? 0
            // The level around frame n: the largest magnitude over the periods before, at and after n's.
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

    /// 1 000 chains installed on `runner` one per 64-frame block over a 440 Hz sine, sweeping −12…+12 dB, and then
    /// 3 × Pure. `pureEvery` > 0 also installs Pure at the start of every such run of blocks and leaves it for half of
    /// it.
    static func sweep(
        _ kind: String, pureEvery: Int = 0, on runner: ChainRunner = ChainRunner()
    ) -> (output: [Float], pureBlocks: Int, chains: [Freed]) {
        var chains: [Freed] = []
        let block = 64
        let installs = 1_000
        let amplitude = 0.25
        let input = tone(440, amplitude: amplitude, frames: (installs + 64) * block)
        let output = run(runner, input, block: block) { index in
            guard index < installs else { return }
            if pureEvery > 0 {
                let phase = index % pureEvery
                if phase == 0 {
                    runner.install(nil)
                    return
                }
                if phase < pureEvery / 2 { return }
            }
            let db = -12 + 24 * Double(index) / Double(installs - 1)
            let s: SoundSettings =
                kind == "trim"
                ? settings { $0.preamp.trimDb = db }
                // Dragging an EQ handle: a peak on the tone, no auto headroom, so the level follows the gain.
                : eq([EQBand(type: .peak, frequency: 440, gainDb: db, q: 1.41)], autoHeadroom: false)
            let chain = SoundChain(s, sampleRate: rate, channels: 2)
            chains.append(Freed(chain))
            runner.install(chain)
        }
        // Blocks played back untouched: where Pure took over.
        var pureBlocks = 0
        for start in stride(from: 0, to: input.count, by: block * 2) {
            let end = start + block * 2
            if identical(output[start..<end], input[start..<end]) { pureBlocks += 1 }
        }
        let tail = tone(440, amplitude: amplitude, frames: 1_024)
        for _ in 0..<3 {
            runner.install(nil)
            _ = run(runner, tail, block: block)
        }
        return (output, pureBlocks, chains)
    }

    @Test("1 000 installs, one per 64-frame block, sweeping −12…+12 dB, never step past 1.5 × the tone's slope")
    func installsCrossfadeWithoutClicks() {
        for kind in ["trim", "eq"] {
            let (output, _, _) = Self.sweep(kind)
            let ratios = Self.largestStepRatios(output, channels: 2, hz: 440)
            #expect(output.allSatisfy { $0.isFinite })
            #expect(ratios.local < 1.5, "\(kind): largest step \(ratios.local) × the local slope")
            #expect(ratios.global < 1.5, "\(kind): largest step \(ratios.global) × the loudest slope")
        }
    }

    @Test("Fading between a delayed chain and the undelayed Pure signal, both ways, is click-free too")
    func pureTransitionsWithoutClicks() {
        for kind in ["trim", "eq"] {
            let (output, pureBlocks, _) = Self.sweep(kind, pureEvery: 40)
            let ratios = Self.largestStepRatios(output, channels: 2, hz: 440)
            #expect(pureBlocks >= 25, "\(kind): Pure took over \(pureBlocks) times")
            #expect(ratios.local < 1.5, "\(kind): largest step \(ratios.local) × the local slope")
            #expect(ratios.global < 1.5, "\(kind): largest step \(ratios.global) × the loudest slope")
        }
    }

    @Test(
        "One chain swapped for a very different one is click-free: ±12 and ±1 dB trims, an EQ band, crossfeed",
        arguments: [
            "trim −12 → +12", "trim +12 → −12", "trim −1 → +1", "EQ band appears", "EQ band goes", "crossfeed on",
        ])
    func chainSwapsWithoutClicks(jump: String) {
        let band = [EQBand(type: .peak, frequency: 440, gainDb: 12, q: 1.41)]
        let pair: (from: SoundSettings, to: SoundSettings) =
            switch jump {
            case "trim −12 → +12": (Self.settings { $0.preamp.trimDb = -12 }, Self.settings { $0.preamp.trimDb = 12 })
            case "trim +12 → −12": (Self.settings { $0.preamp.trimDb = 12 }, Self.settings { $0.preamp.trimDb = -12 })
            case "trim −1 → +1": (Self.settings { $0.preamp.trimDb = -1 }, Self.settings { $0.preamp.trimDb = 1 })
            case "EQ band appears": (Self.eq([], autoHeadroom: false), Self.eq(band, autoHeadroom: false))
            case "EQ band goes": (Self.eq(band, autoHeadroom: false), Self.eq([], autoHeadroom: false))
            default: (Self.settings(), Self.settings { $0.crossfeed.enabled = true })
            }
        // A 440 Hz tone, left and right a radian apart, so crossfeed changes both channels.
        let input = Self.tone(440, amplitude: 0.25, frames: 24_000)
        let runner = ChainRunner()
        runner.install(SoundChain(pair.from, sampleRate: Self.rate, channels: 2))
        // The first chain has long faded in from Pure by block 40 (frame 10 240): the swap is a chain-to-chain fade.
        let output = Self.run(runner, input, block: 256) { index in
            if index == 40 { runner.install(SoundChain(pair.to, sampleRate: Self.rate, channels: 2)) }
        }
        let ratios = Self.largestStepRatios(output, channels: 2, hz: 440)
        #expect(ratios.local < 1.5, "\(jump): largest step \(ratios.local) × the local slope")
        #expect(ratios.global < 1.5, "\(jump): largest step \(ratios.global) × the loudest slope")
        // And the swap took effect: the end differs from what the first chain alone gives.
        let alone = ChainRunner()
        alone.install(SoundChain(pair.from, sampleRate: Self.rate, channels: 2))
        let unswapped = Self.run(alone, input, block: 256)
        #expect(!Self.identical(output[40_000...], unswapped[40_000...]), "\(jump): the second chain plays")
    }

    @Test("After that run and three installs of Pure, every chain is freed while the runner lives")
    func retiredChainsAreFreed() {
        let runner = ChainRunner()
        let (_, _, chains) = Self.sweep("eq", pureEvery: 40, on: runner)
        runner.waitForFrees()
        // The runner is still alive, so the retire path freed them, not its deinit.
        withExtendedLifetime(runner) {
            let alive = chains.filter { $0.chain != nil }.count
            #expect(chains.count == 500)
            #expect(alive == 0, "\(alive) of \(chains.count) chains still alive")
            #expect(runner.strandedCount == 0, "nothing stranded: no render call stalled")
        }
    }

    @Test("A runner frees the chain it is playing, and the one in its mailbox, when it goes")
    func runnerFreesItsChainsWhenItGoes() {
        var tracked: [Freed] = []
        do {
            let runner = ChainRunner()
            let playing = SoundChain(Self.settings(), sampleRate: Self.rate, channels: 2)
            tracked.append(Freed(playing))
            runner.install(playing)
            _ = Self.run(runner, Self.tone(1_000, amplitude: 0.5, frames: 1_024))
            let waiting = SoundChain(Self.settings { $0.preamp.trimDb = -3 }, sampleRate: Self.rate, channels: 2)
            tracked.append(Freed(waiting))
            runner.install(waiting)
            withExtendedLifetime(runner) { #expect(tracked.allSatisfy { $0.chain != nil }, "both held while it lives") }
        }
        #expect(tracked.allSatisfy { $0.chain == nil })
    }

    @Test("Reinstalling the same settings every block, or the same chain, is inaudible: state carries over")
    func reinstallingIsSeamless() {
        // High-Q and low bands (which ring for long from rest), crossfeed, and the limiter at work.
        let s = Self.settings {
            $0.eq = EQSettings(
                enabled: true, mode: .parametric,
                bands: [
                    EQBand(type: .peak, frequency: 60, gainDb: 9, q: 8),
                    EQBand(type: .lowShelf, frequency: 120, gainDb: 6, q: 0.7),
                    EQBand(type: .peak, frequency: 3_000, gainDb: 6, q: 4),
                ])
            $0.crossfeed.enabled = true
            $0.preamp.trimDb = 9
        }
        var noise = BiquadTests.WhiteNoise()
        let input = Self.signal(frames: 24_000, channels: 2) { frame, _ in
            0.3 * noise.next() + 0.4 * sin(2 * .pi * 60 * Double(frame) / Self.rate)
        }
        let once = ChainRunner()
        once.install(SoundChain(s, sampleRate: Self.rate, channels: 2))
        let reference = Self.run(once, input)
        #expect(once.meters.gainReductionDb > 1, "the limiter is working")

        let fresh = ChainRunner()
        let everyBlock = Self.run(fresh, input) { _ in fresh.install(SoundChain(s, sampleRate: Self.rate, channels: 2))
        }
        let same = ChainRunner()
        let chain = SoundChain(s, sampleRate: Self.rate, channels: 2)
        let sameChain = Self.run(same, input) { _ in same.install(chain) }
        for (name, output) in [("fresh chains", everyBlock), ("the same chain", sameChain)] {
            let worst = zip(output, reference).map { abs($0 - $1) }.max() ?? 0
            #expect(worst <= 1e-6, "\(name): largest difference \(worst)")
        }
    }

    @Test("A fade's end weights take one side whole: priming from Pure is bit for bit, and no dry NaN leaks after")
    func fadeEndsAreExact() {
        let s = Self.eq([EQBand(type: .peak, frequency: 1_000, gainDb: 6, q: 1)])
        let chain = SoundChain(s, sampleRate: Self.rate, channels: 2)
        let latency = chain.latencyFrames
        var input = Self.tone(1_000, amplitude: 0.5, frames: 4_096)
        // Odd values while the new chain primes (the dry signal heard alone), and at the fade's last frame.
        let odd: [Float] = [-0.0, .nan, Float(bitPattern: 0x7FA0_0001), .infinity, -.leastNonzeroMagnitude]
        for (i, v) in odd.enumerated() { input[2 * (10 + i)] = v }
        let last = Self.settled(chain) - 1
        input[2 * last] = .nan
        input[2 * last + 1] = .infinity
        let runner = ChainRunner()
        runner.install(chain)
        let output = Self.run(runner, input, block: 64)
        #expect(Self.identical(output[..<(2 * latency)], input[..<(2 * latency)]), "priming is the input, bit for bit")
        #expect(output[(2 * last)...].allSatisfy { $0.isFinite }, "from the fade's last frame on, the chain alone")
    }

    // MARK: Formats

    @Test("1, 2, 6 and 8 channels all run; crossfeed is applied only to 2")
    func multichannelAndMono() {
        let band = EQBand(type: .peak, frequency: 1_000, gainDb: 6, q: 1)
        let withCrossfeed = Self.settings {
            $0.eq = EQSettings(enabled: true, mode: .parametric, bands: [band])
            $0.crossfeed.enabled = true
        }
        var withoutCrossfeed = withCrossfeed
        withoutCrossfeed.crossfeed.enabled = false
        for channels in [1, 2, 6, 8] {
            // Music in the first channel only, the rest silent.
            let input = Self.signal(frames: 8_192, channels: channels) { frame, channel in
                channel == 0 ? 0.5 * sin(2 * .pi * 300 * Double(frame) / Self.rate) : 0
            }
            let runner = ChainRunner()
            runner.install(SoundChain(withCrossfeed, sampleRate: Self.rate, channels: channels))
            let output = Self.run(runner, input, channels: channels)
            #expect(output.allSatisfy { $0.isFinite }, "\(channels) channels")
            let others =
                (4_096..<8_192).map { frame in
                    (1..<channels).map { Double(output[frame * channels + $0]).magnitude }.max() ?? 0
                }.max() ?? 0
            if channels == 2 {
                #expect(others > 0.02, "the right channel hears the left through crossfeed (\(others))")
            } else {
                #expect(others == 0, "\(channels) channels: nothing crosses over (\(others))")
                let plain = ChainRunner()
                plain.install(SoundChain(withoutCrossfeed, sampleRate: Self.rate, channels: channels))
                #expect(Self.identical(output[...], Self.run(plain, input, channels: channels)[...]))
            }
        }
    }

    @Test("Blocks of another channel count, too many channels or too many frames never trap or read out of bounds")
    func oddBlocksAreSafe() {
        let s = Self.eq([EQBand(type: .peak, frequency: 1_000, gainDb: 6, q: 1)])
        let runner = ChainRunner(maxFrames: 256, maxChannels: 2)
        runner.install(SoundChain(s, sampleRate: Self.rate, channels: 2))
        _ = Self.run(runner, Self.tone(1_000, amplitude: 0.5, frames: 2_048))
        // Mono, and nine channels: untouched, bit for bit.
        let mono = Self.tone(700, amplitude: 0.5, frames: 1_000, channels: 1)
        #expect(Self.identical(Self.run(runner, mono, channels: 1, block: 1_000)[...], mono[...]))
        let nine = Self.tone(700, amplitude: 0.5, frames: 300, channels: 9)
        #expect(Self.identical(Self.run(runner, nine, channels: 9, block: 300)[...], nine[...]))
        var nothing: [Float] = [1, 2]
        nothing.withUnsafeMutableBufferPointer { runner.process($0.baseAddress!, frames: 0, channels: 2) }
        nothing.withUnsafeMutableBufferPointer { runner.process($0.baseAddress!, frames: 1, channels: 0) }
        #expect(nothing == [1, 2])

        // A block longer than maxFrames is processed in pieces, the same as short blocks.
        let input = Self.tone(1_000, amplitude: 0.5, frames: 5_000)
        let long = ChainRunner(maxFrames: 256)
        long.install(SoundChain(s, sampleRate: Self.rate, channels: 2))
        let short = ChainRunner()
        short.install(SoundChain(s, sampleRate: Self.rate, channels: 2))
        #expect(Self.identical(Self.run(long, input, block: 5_000)[...], Self.run(short, input, block: 128)[...]))
    }

    // MARK: Meters

    @Test("Meters: the peak since the last read, clips above full scale, and the limiter's reduction")
    func metersReport() {
        let runner = ChainRunner()
        runner.install(SoundChain(Self.settings { $0.preamp.trimDb = 6 }, sampleRate: Self.rate, channels: 2))
        _ = Self.run(runner, Self.tone(997, amplitude: 0.9, frames: 24_000))
        let first = runner.meters
        // 0.9 × +6 dB is 5.09 dBFS: 5.39 dB over the −0.3 dBTP ceiling.
        let over = 20 * log10(0.9 * pow(10, 6.0 / 20)) + 0.3
        #expect(abs(first.gainReductionDb - over) < 0.05, "reduction \(first.gainReductionDb) dB, over \(over) dB")
        #expect(first.peakDbFS <= -0.3 + 1e-5 && first.peakDbFS > -0.5, "peak \(first.peakDbFS) dBFS")
        #expect(first.clipCount == 0)
        #expect(runner.meters.peakDbFS == -120, "a read starts a new interval")

        // The dry signal of a fade from Pure carries its own overs, and they are counted.
        let fromPure = ChainRunner()
        fromPure.install(SoundChain(Self.settings(), sampleRate: Self.rate, channels: 2))
        let hot = [Float](repeating: 1.5, count: 2 * 64)
        _ = Self.run(fromPure, hot, block: 64)
        let meters = fromPure.meters
        #expect(meters.clipCount == 128, "clips \(meters.clipCount)")
        #expect(abs(meters.peakDbFS - 20 * log10(1.5)) < 1e-6, "peak \(meters.peakDbFS) dBFS")
    }

    // MARK: Concurrency

    /// Flags shared with the render thread in `rendersWhileInstalling`.
    final class Shared: @unchecked Sendable {
        let stop = Atomic<Bool>(false)
        let blocks = Atomic<Int>(0)
        let nonFinite = Atomic<Int>(0)
    }

    @Test("A render thread runs flat out while chains and Pure are installed from another: always finite")
    func rendersWhileInstalling() {
        let runner = ChainRunner(maxFrames: 512)
        let shared = Shared()
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
            if i % 7 == 3 {
                runner.install(nil)
            } else {
                let db = Double(i % 25) - 12
                runner.install(SoundChain(Self.settings { $0.preamp.trimDb = db }, sampleRate: Self.rate, channels: 2))
            }
            _ = runner.meters
            Thread.sleep(forTimeInterval: 0.0005)
        }
        shared.stop.store(true, ordering: .releasing)
        finished.wait()
        #expect(shared.blocks.load(ordering: .relaxed) > 0)
        #expect(shared.nonFinite.load(ordering: .relaxed) == 0)
    }

    // MARK: Extremes

    /// The band-limited reconstruction of one period of a periodic signal on a 32× grid: its spectrum zero-padded
    /// 32×. The trigonometric interpolant of a periodic signal is exactly its band-limited reconstruction, flat to all
    /// of fs/2, with no window and no edge, and it shares no code or filter with the limiter's detector. Read on the
    /// grid, a crest between two points is under-read by at most cos(π f / 32 fs): 0.0085 dB at 0.45·fs.
    static func reconstruction(_ x: [Double], factor: Int = 32) -> [Double] {
        let n = x.count
        let m = factor * n
        let forward = try! vDSP.DiscreteFourierTransform(
            count: n, direction: .forward, transformType: .complexComplex, ofType: Double.self)
        let inverse = try! vDSP.DiscreteFourierTransform(
            count: m, direction: .inverse, transformType: .complexComplex, ofType: Double.self)
        let spectrum = forward.transform(real: x, imaginary: [Double](repeating: 0, count: n))
        var real = [Double](repeating: 0, count: m)
        var imaginary = [Double](repeating: 0, count: m)
        for k in 0..<n / 2 {
            real[k] = spectrum.real[k]
            imaginary[k] = spectrum.imaginary[k]
        }
        for k in (n / 2 + 1)..<n {
            real[m - n + k] = spectrum.real[k]
            imaginary[m - n + k] = spectrum.imaginary[k]
        }
        // The Nyquist bin, split between ±fs/2.
        real[n / 2] = spectrum.real[n / 2] / 2
        real[m - n / 2] = spectrum.real[n / 2] / 2
        let upsampled = inverse.transform(real: real, imaginary: imaginary).real.map { $0 / Double(n) }
        // The reconstruction passes through every sample: the reference's own check.
        let worst = (0..<n).map { abs(upsampled[factor * $0] - x[$0]) }.max() ?? 0
        #expect(worst < 1e-9, "the reference misses its samples by \(worst)")
        return upsampled
    }

    /// The true peak of one period of a periodic signal, in dBTP; infinity if any sample is not finite.
    static func truePeakDb(_ x: [Double]) -> Double {
        guard x.allSatisfy({ $0.isFinite }) else { return .infinity }
        return 20 * log10(reconstruction(x).map(\.magnitude).max() ?? 0)
    }

    @Test("The true-peak reference matches the analytic signal between samples, up to 0.45·fs, within 1e-9")
    func truePeakReferenceIsExact() {
        let n = 4_096
        // Tones on bins up to 0.45·fs (bin 1 843), so periodic in n and known exactly between samples.
        let tones: [(bin: Double, amplitude: Double, phase: Double)] = [
            (1, 0.1, 0.3), (517, 0.2, 1.1), (1_024, 0.15, 2), (1_500, 0.2, -0.7), (1_843, 0.3, 0.5),
        ]
        func value(_ t: Double) -> Double {
            tones.reduce(0) { $0 + $1.amplitude * cos(2 * .pi * $1.bin * t / Double(n) + $1.phase) }
        }
        let x = (0..<n).map { value(Double($0)) }
        let u = Self.reconstruction(x)
        let worst = (0..<u.count).map { abs(u[$0] - value(Double($0) / 32)) }.max() ?? 0
        #expect(worst < 1e-9, "largest difference \(worst)")
        // A 0.45·fs sine with its crest halfway between two samples reads 0 dBTP.
        let crest = (0..<n).map { cos(2 * .pi * 1_843 * (Double($0) - 0.5) / Double(n)) }
        #expect(abs(Self.truePeakDb(crest)) < 1e-9)
    }

    /// Periodic white noise band-limited to 0.45·fs: random-phase bins of equal magnitude up to 0.45·fs, so its
    /// spectrum is a brick wall there.
    static func bandLimitedNoise(period n: Int, seed: UInt64) -> [Double] {
        var noise = BiquadTests.WhiteNoise(state: seed)
        let inverse = try! vDSP.DiscreteFourierTransform(
            count: n, direction: .inverse, transformType: .complexComplex, ofType: Double.self)
        var real = [Double](repeating: 0, count: n)
        var imaginary = [Double](repeating: 0, count: n)
        for k in 1...Int(0.45 * Double(n)) {
            let phase = Double.pi * noise.next()
            real[k] = cos(phase)
            imaginary[k] = sin(phase)
            real[n - k] = cos(phase)
            imaginary[n - k] = -sin(phase)
        }
        let x = inverse.transform(real: real, imaginary: imaginary).real
        let rms = (x.map { $0 * $0 }.reduce(0, +) / Double(n)).squareRoot()
        return x.map { 0.25 * $0 / rms }
    }

    @Test(
        "Twenty +24 dB Q 20 bands at the EQ's 20 kHz cap, and tone and graphic EQ at their limits, hold the ceiling",
        arguments: [44_100.0, 48_000])
    func ceilingHoldsAtExtremes(rate: Double) {
        let ceiling = -0.3
        let stacked = [EQBand](repeating: EQBand(type: .peak, frequency: 20_000, gainDb: 24, q: 20), count: 20)
        // 0.44 × 44.1 kHz, under the noise's 0.45·fs edge at both rates.
        let inBand = [EQBand](repeating: EQBand(type: .peak, frequency: 19_404, gainDb: 24, q: 20), count: 20)
        let cases: [(name: String, settings: SoundSettings)] = [
            (
                "20 kHz stack, auto headroom, +12 dB trim",
                Self.settings {
                    $0.eq = EQSettings(enabled: true, mode: .parametric, bands: stacked)
                    $0.preamp.trimDb = 12
                }
            ),
            (
                "20 kHz stack, no auto headroom, +12 dB trim",
                Self.settings {
                    $0.eq = EQSettings(enabled: true, mode: .parametric, bands: stacked)
                    $0.preamp = PreampSettings(autoHeadroom: false, trimDb: 12)
                }
            ),
            (
                "19.4 kHz stack (inside the band at 44.1 kHz too), no auto headroom, +12 dB trim",
                Self.settings {
                    $0.eq = EQSettings(enabled: true, mode: .parametric, bands: inBand)
                    $0.preamp = PreampSettings(autoHeadroom: false, trimDb: 12)
                }
            ),
            (
                "graphic and tone at +12 dB, no auto headroom, +12 dB trim",
                Self.settings {
                    $0.eq = EQSettings(
                        enabled: true, mode: .graphic, graphicGainsDb: [Double](repeating: 12, count: 10))
                    $0.tone = ToneSettings(enabled: true, bassDb: 12, trebleDb: 12, tiltDb: 12)
                    $0.preamp = PreampSettings(autoHeadroom: false, trimDb: 12)
                }
            ),
        ]
        let period = 16_384
        let periods = 4
        let left = Self.bandLimitedNoise(period: period, seed: 0x1234_5678_9ABC_DEF1)
        let right = Self.bandLimitedNoise(period: period, seed: 0x0FED_CBA9_8765_4321)
        var input = [Float](repeating: 0, count: period * periods * 2)
        for frame in 0..<(period * periods) {
            input[2 * frame] = Float(left[frame % period])
            input[2 * frame + 1] = Float(right[frame % period])
        }
        for (name, s) in cases {
            var s = s
            s.limiter.ceilingDbTP = ceiling
            let runner = ChainRunner()
            runner.install(SoundChain(s, sampleRate: rate, channels: 2))
            let output = Self.run(runner, input, block: 512)
            #expect(output.allSatisfy { $0.isFinite }, "\(name) at \(rate) Hz")
            let reduction = runner.meters.gainReductionDb
            var worst = -Double.infinity
            for channel in 0..<2 {
                let last = (0..<period).map { Double(output[2 * ((periods - 1) * period + $0) + channel]) }
                let before = (0..<period).map { Double(output[2 * ((periods - 2) * period + $0) + channel]) }
                let drift = zip(last, before).map { abs($0 - $1) }.max() ?? 0
                #expect(drift < 1e-5, "\(name) at \(rate) Hz: the output has settled to periodic (\(drift))")
                worst = max(worst, Self.truePeakDb(last))
            }
            #expect(worst <= ceiling + 0.1, "\(name) at \(rate) Hz: \(worst) dBTP, reduction \(reduction) dB")
        }
    }
}
