import Foundation
import Testing

@testable import PFDSP

/// The master limiter at the end of the Sound chain: it holds a true-peak ceiling, catches overs that fall between
/// samples, is an exact delay while nothing would cross the ceiling, and stays finite whatever it is fed.
///
/// Every true peak here is measured by `truePeakDb`, an offline 16× reconstruction that shares no code or filter with
/// the limiter's own 4× detector, so the limiter is never marked by its own measure.
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
        let weights: [[Double]] = (0..<phases).map { phase in
            let t = Double(phase) / Double(phases)
            return ((1 - half)...half).map { i in
                let u = Double(i) - t
                let sinc = u == 0 ? 1 : sin(.pi * u) / (.pi * u)
                return sinc * blackmanHarris(u, half: Double(half))
            }
        }
        let frames = x.count / channels
        var peak = 0.0
        x.withUnsafeBufferPointer { samples in
            for channel in 0..<channels {
                for frame in max(start, half)..<(frames - half) {
                    for taps in weights {
                        var v = 0.0
                        for (k, w) in taps.enumerated() {
                            v += w * samples[(frame + 1 - half + k) * channels + channel]
                        }
                        peak = max(peak, abs(v))
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
        let input = Self.signal(seconds: 0.1) { frame, channel in
            2.0 * sin(2 * .pi * 997 * Double(frame) / Self.rate + Double(channel))
        }
        let peak = Self.truePeakDb(Self.run(limiter, input), from: Self.settleFrames)
        #expect(peak <= -0.25, "true peak \(peak) dBFS")
        // And it takes off no more than it needs to, which the meter reports: 2.0 down to −0.3 dBFS is 6.32 dB.
        #expect(peak >= -0.35, "true peak \(peak) dBFS")
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
        #expect(worst <= 1e-12, "largest difference \(worst)")
        #expect(limiter.gainReductionDb == 0)
    }

    @Test("A full-scale sine at fs/4 with a 45° phase, whose samples peak at −3 dB, is held to a −1 dBTP ceiling")
    func interSamplePeaksCaught() {
        let limiter = TruePeakLimiter(channels: Self.channels, sampleRate: Self.rate, ceilingDbTP: -1)
        let input = Self.signal(seconds: 0.1) { frame, _ in sin(.pi / 2 * Double(frame) + .pi / 4) }
        let samplePeak = input.map { abs($0) }.max() ?? 0
        #expect(abs(Self.db(samplePeak) + 3.0103) < 0.001, "the samples alone stay under the ceiling")
        #expect(abs(Self.truePeakDb(input, from: 0)) < 0.01, "the meter sees the 0 dBTP peak between samples")
        let peak = Self.truePeakDb(Self.run(limiter, input), from: Self.settleFrames)
        #expect(peak <= -0.95, "true peak \(peak) dBTP")
        #expect(peak >= -1.1, "true peak \(peak) dBTP")
    }

    @Test("Input at ±1e6, and even non-finite samples, give finite output under full scale")
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
        #expect(output.allSatisfy { abs($0) <= 1 }, "largest sample \(output.map { abs($0) }.max() ?? 0)")
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
