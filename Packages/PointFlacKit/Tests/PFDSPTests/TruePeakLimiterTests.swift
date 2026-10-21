import Foundation
import Testing

@testable import PFDSP

/// The master limiter at the end of the Sound chain: it holds a true-peak ceiling, catches overs that fall between
/// samples, is an exact delay while nothing would cross the ceiling, and stays finite whatever it is fed.
///
/// True peaks are measured either by `truePeakDb`, an offline 16× reconstruction that shares no code or filter with
/// the limiter's detector, or, for steady tones, exactly: once settled, the output is the input times one gain, so its
/// true peak is that gain times the tone's amplitude. Either way the limiter is never marked by its own measure.
@Suite("True-peak limiter")
struct TruePeakLimiterTests {
    static let rate = 48_000.0
    static let channels = 2

    static func db(_ x: Double) -> Double { 20 * log10(x) }

    /// `seconds` of interleaved stereo, filled by `sample(frame, channel)`.
    static func signal(seconds: Double, _ sample: (Int, Int) -> Double) -> [Double] {
        let frames = Int(seconds * rate)
        var x = [Double](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels { x[frame * channels + channel] = sample(frame, channel) }
        }
        return x
    }

    /// Runs `input` through `limiter` in place, a block at a time, cycling through `blocks` sizes the way render
    /// callbacks of varying length would.
    static func run(_ limiter: TruePeakLimiter, _ input: [Double], blocks: [Int] = [512]) -> [Double] {
        var io = input
        let frames = input.count / channels
        io.withUnsafeMutableBufferPointer { buffer in
            var done = 0
            var block = 0
            while done < frames {
                let n = min(blocks[block % blocks.count], frames - done)
                limiter.process(buffer.baseAddress! + done * channels, frames: n)
                done += n
                block += 1
            }
        }
        return io
    }

    /// The 4-term Blackman–Harris window over [−half, half].
    static func blackmanHarris(_ u: Double, half: Double) -> Double {
        let x = (u + half) / (2 * half)
        guard x >= 0, x <= 1 else { return 0 }
        return 0.35875 - 0.48829 * cos(2 * .pi * x) + 0.14128 * cos(4 * .pi * x) - 0.01168 * cos(6 * .pi * x)
    }

    /// The true peak of every channel of `x`, in dBFS, from frame `start` on: `x` upsampled 16× by a 256-tap
    /// Blackman–Harris windowed sinc (16 phases of 16 taps, flat to 0.0001 dB up to a quarter of the rate).
    ///
    /// Deliberately independent of the limiter: four times the oversampling, a different window and a wider kernel,
    /// evaluated offline on the whole buffer rather than streamed.
    static func truePeakDb(_ x: [Double], from start: Int) -> Double {
        let phases = 16
        let half = 8
        let span = 2 * half
        var weights = [Double]()
        for phase in 0..<phases {
            let t = Double(phase) / Double(phases)
            for i in (1 - half)...half {
                let u = Double(i) - t
                let sinc = u == 0 ? 1 : sin(.pi * u) / (.pi * u)
                weights.append(sinc * blackmanHarris(u, half: Double(half)))
            }
        }
        let frames = x.count / channels
        var peak = 0.0
        x.withUnsafeBufferPointer { samples in
            weights.withUnsafeBufferPointer { weights in
                let x = samples.baseAddress!
                let w = weights.baseAddress!
                for channel in 0..<channels {
                    var frame = max(start, half)
                    while frame < frames - half {
                        let first = x + (frame + 1 - half) * channels + channel
                        var phase = 0
                        while phase < phases {
                            let row = w + phase * span
                            var v = 0.0
                            var k = 0
                            while k < span {
                                v += row[k] * first[k * channels]
                                k += 1
                            }
                            if v.magnitude > peak { peak = v.magnitude }
                            phase += 1
                        }
                        frame += 1
                    }
                }
            }
        }
        return db(peak)
    }

    /// Output frames that pass before the true peak is judged.
    static let settleFrames = Int(0.010 * rate)

    @Test("A 997 Hz sine at +6 dBFS comes out at the −0.3 dBTP ceiling, measured independently at 16×")
    func holdsTheCeiling() {
        let limiter = TruePeakLimiter(channels: Self.channels, sampleRate: Self.rate, ceilingDbTP: -0.3)
        let input = Self.signal(seconds: 0.5) { frame, channel in
            2.0 * sin(2 * .pi * 997 * Double(frame) / Self.rate + Double(channel))
        }
        let output = Self.run(limiter, input)
        let peak = Self.truePeakDb(output, from: Self.settleFrames)
        #expect(peak <= -0.25, "true peak \(peak) dBFS")
        // And once the abrupt start's deeper reduction has released (0.1 s time constant), it takes off no more than
        // it needs to, which the meter reports: 2.0 down to −0.3 dBFS is 6.32 dB.
        let settled = Self.truePeakDb(output, from: output.count / Self.channels - Int(0.05 * Self.rate))
        #expect(settled >= -0.35, "settled true peak \(settled) dBFS")
        #expect(abs(limiter.gainReductionDb - 6.32) < 0.05, "gain reduction \(limiter.gainReductionDb) dB")
    }

    @Test("Below the ceiling the output is the input delayed by latencyFrames, whatever the block sizes")
    func transparentBelowCeiling() {
        let limiter = TruePeakLimiter(channels: Self.channels, sampleRate: Self.rate, ceilingDbTP: -0.3)
        let amplitude = pow(10, -6.0 / 20)
        let input = Self.signal(seconds: 0.1) { frame, channel in
            amplitude * sin(2 * .pi * (channel == 0 ? 997 : 3_001) * Double(frame) / Self.rate)
        }
        let output = Self.run(limiter, input, blocks: [1, 7, 64, 333, 512, 1_000])
        let latency = limiter.latencyFrames
        let frames = input.count / Self.channels
        #expect(latency > 0)
        var worst = 0.0
        for frame in 0..<frames {
            for channel in 0..<Self.channels {
                let expected = frame < latency ? 0 : input[(frame - latency) * Self.channels + channel]
                worst = max(worst, abs(output[frame * Self.channels + channel] - expected))
            }
        }
        // The brief asks for 1e-12; the design promises bit-exact (R4-6), so pin that.
        #expect(worst == 0, "largest difference \(worst)")
        #expect(limiter.gainReductionDb == 0)
    }

    @Test("A full-scale sine at fs/4 with a 45° phase, whose samples peak at −3 dB, is held to a −1 dBTP ceiling")
    func interSamplePeaksCaught() {
        // π/4 puts the crest halfway between samples, where the samples alone stay at −3 dB, under the ceiling;
        // 3π/8 puts it a quarter of the way, so other phases' taps do the catching.
        for phase in [Double.pi / 4, 3 * .pi / 8] {
            let limiter = TruePeakLimiter(channels: Self.channels, sampleRate: Self.rate, ceilingDbTP: -1)
            let input = Self.signal(seconds: 0.1) { frame, _ in sin(.pi / 2 * Double(frame) + phase) }
            if phase == .pi / 4 {
                let samplePeak = input.map { abs($0) }.max() ?? 0
                #expect(abs(Self.db(samplePeak) + 3.0103) < 0.001, "the samples alone stay under the ceiling")
            }
            #expect(abs(Self.truePeakDb(input, from: 0)) < 0.01, "the meter sees the 0 dBTP peak between samples")
            let peak = Self.truePeakDb(Self.run(limiter, input), from: Self.settleFrames)
            #expect(peak <= -0.95, "phase \(phase): true peak \(peak) dBTP")
            #expect(peak >= -1.1, "phase \(phase): true peak \(peak) dBTP")
        }
    }

    @Test("Steady tones at any phase come out within 0.05 dB of a −0.3 or 0 dBTP ceiling, 0.1 dB if ultrasonic")
    func steadyTonesHoldAtAnyPhase() {
        // Audio-band tones get 0.05 dB. Ultrasonic tones at 176.4 and 192 kHz (0.4 × the rate, like a DSD-sourced
        // file's noise-shaped hash) are read on the 8× grid and get 0.1 dB (ruling R4-T4e).
        let tones: [(rate: Double, hz: [Double], tolerance: Double)] = [
            (44_100, [997, 44_100 / 4, 44_100 / 3, 0.4 * 44_100], 0.05),
            (48_000, [997, 48_000 / 4, 48_000 / 3, 0.4 * 48_000], 0.05),
            (96_000, [20_000], 0.05),
            (176_400, [20_000], 0.05),
            (192_000, [20_000], 0.05),
            (176_400, [0.4 * 176_400], 0.1),
            (192_000, [0.4 * 192_000], 0.1),
        ]
        let amplitude = 2.0
        for (rate, frequencies, tolerance) in tones {
            for hz in frequencies {
                for ceilingDb in [-0.3, 0] {
                    // Crests at k/32 of a sample, which includes the midpoint between detection points, the worst
                    // place for a crest, at every oversampling factor. A fast release settles the start-up in 10 ms.
                    for k in 0..<32 {
                        let crest = Double(k) / 32
                        let limiter = TruePeakLimiter(
                            channels: 1, sampleRate: rate, ceilingDbTP: ceilingDb, releaseSeconds: 0.001)
                        let latency = limiter.latencyFrames
                        let settled = latency + Int(0.01 * rate)
                        let frames = settled + Int(0.005 * rate)
                        let input = (0..<frames).map { n in amplitude * cos(2 * .pi * hz / rate * (Double(n) - crest)) }
                        var output = input
                        output.withUnsafeMutableBufferPointer { limiter.process($0.baseAddress!, frames: frames) }
                        var gain = 0.0
                        for n in settled..<frames where abs(input[n - latency]) > amplitude / 4 {
                            gain = max(gain, output[n] / input[n - latency])
                        }
                        let over = Self.db(gain * amplitude) - ceilingDb
                        let tone = "\(hz) Hz at \(rate) Hz, crest \(crest), ceiling \(ceilingDb)"
                        #expect(over <= tolerance, "\(tone): \(over) dB over")
                        #expect(over >= -0.1, "\(tone): \(-over) dB under, more than it needs")
                    }
                }
            }
        }
    }

    @Test("One hot channel pulls the others down by the same gain, with 1, 2 and 8 channels")
    func channelCountsShareOneGain() {
        let ceiling = pow(10, -0.3 / 20)
        for channels in [1, 2, 8] {
            let limiter = TruePeakLimiter(channels: channels, sampleRate: Self.rate, ceilingDbTP: -0.3)
            let frames = 4_800
            var input = [Double](repeating: 0, count: frames * channels)
            for frame in 0..<frames {
                let t = Double(frame) / Self.rate
                // Channel 0 at +6 dBFS; the rest at −20 dBFS, each at its own frequency.
                input[frame * channels] = 2 * sin(2 * .pi * 997 * t)
                for c in 1..<channels { input[frame * channels + c] = 0.1 * sin(2 * .pi * Double(300 * c) * t) }
            }
            var output = input
            output.withUnsafeMutableBufferPointer { limiter.process($0.baseAddress!, frames: frames) }
            let latency = limiter.latencyFrames
            var largestGain = 0.0
            var smallestGain = 1.0
            var spread = 0.0
            for frame in (latency + Self.settleFrames)..<frames {
                let source = (frame - latency) * channels
                guard abs(input[source]) > 0.5 else { continue }
                let gain = output[frame * channels] / input[source]
                largestGain = max(largestGain, gain)
                smallestGain = min(smallestGain, gain)
                for c in 1..<channels {
                    spread = max(spread, abs(output[frame * channels + c] - gain * input[source + c]))
                }
            }
            #expect(smallestGain < 0.5, "\(channels) channels: it limits (gain \(smallestGain))")
            #expect(Self.db(largestGain * 2) <= -0.25, "\(channels) channels: \(Self.db(largestGain * 2)) dBTP")
            #expect(spread < 1e-14, "\(channels) channels: a quiet channel's gain differs by \(spread)")
            #expect(output.allSatisfy { abs($0) <= ceiling * (1 + 1e-12) })
        }
    }

    @Test("latencyFrames is the 1.5 ms look-ahead plus 15 frames at every rate, and is the real delay")
    func latencyFollowsTheRate() {
        for (rate, expected) in [(44_100.0, 81), (48_000, 87), (96_000, 159), (192_000, 303), (384_000, 591)] {
            let limiter = TruePeakLimiter(channels: Self.channels, sampleRate: rate, ceilingDbTP: -0.3)
            #expect(limiter.latencyFrames == expected, "at \(rate) Hz")
            // A quiet click comes out exactly latencyFrames later, and untouched.
            let frames = expected + 64
            var io = [Double](repeating: 0, count: frames * Self.channels)
            io[10 * Self.channels] = 0.5
            io[10 * Self.channels + 1] = -0.25
            io.withUnsafeMutableBufferPointer { limiter.process($0.baseAddress!, frames: frames) }
            let at = (10 + expected) * Self.channels
            #expect(io[at] == 0.5 && io[at + 1] == -0.25, "at \(rate) Hz")
            #expect(io.filter { $0 != 0 }.count == 2, "at \(rate) Hz")
        }
    }

    @Test("Input at ±1e6, and even non-finite samples, give finite output under the ceiling")
    func extremesStayFinite() {
        let limiter = TruePeakLimiter(channels: Self.channels, sampleRate: Self.rate, ceilingDbTP: -0.3)
        var noise = BiquadTests.WhiteNoise()
        let segment = 1_200
        var input = Self.signal(seconds: 0.125) { frame, channel in
            switch frame / segment {
            case 0: 1e6 * noise.next()
            case 1: frame % 2 == 0 ? 1e6 : -1e6
            case 2: frame < 2 * segment + segment / 2 ? 1e6 : -1e6
            case 3: 1e6 * sin(.pi / 2 * Double(frame) + .pi / 4 + Double(channel))
            default: 0
            }
        }
        // A broken block upstream must not reach the DAC: the limiter is the chain's last line.
        for (i, bad) in [Double.nan, .infinity, -.infinity, .nan].enumerated() { input[(3_000 + i * 17) * 2] = bad }
        let output = Self.run(limiter, input, blocks: [256, 31])
        #expect(output.allSatisfy { $0.isFinite })
        // The detector reads every sample exactly, so no sample ever passes the ceiling.
        let ceiling = pow(10, -0.3 / 20)
        let largest = output.map { abs($0) }.max() ?? 0
        #expect(largest <= ceiling * (1 + 1e-12), "largest sample \(largest)")
        #expect(limiter.gainReductionDb.isFinite && limiter.gainReductionDb >= 0)
    }

    @Test("Once an over has passed, the release lands on exactly unity and the output is bit-exact again")
    func bitExactAgainAfterRelease() {
        let limiter = TruePeakLimiter(
            channels: Self.channels, sampleRate: Self.rate, ceilingDbTP: -0.3, releaseSeconds: 0.01)
        let loudFrames = Int(0.05 * Self.rate)
        let input = Self.signal(seconds: 0.5) { frame, channel in
            (frame < loudFrames ? 2.0 : 0.5) * sin(2 * .pi * 997 * Double(frame) / Self.rate + Double(channel))
        }
        let output = Self.run(limiter, input)
        let latency = limiter.latencyFrames
        // A 0.01 s release climbs from 6.3 dB of reduction to within 1e-9 of unity in about 0.2 s.
        let frames = input.count / Self.channels
        let exact = (Int(0.3 * Self.rate)..<frames).allSatisfy { frame in
            (0..<Self.channels).allSatisfy { channel in
                output[frame * Self.channels + channel] == input[(frame - latency) * Self.channels + channel]
            }
        }
        #expect(exact)
        #expect(limiter.gainReductionDb == 0)
    }
}
