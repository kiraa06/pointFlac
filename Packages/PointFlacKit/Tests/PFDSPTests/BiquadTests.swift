import Testing

@testable import PFDSP

/// The matched second-order designs (Vicanek 2016) that the EQ, the tone controls and headphone correction are built
/// from, and the transposed direct form II filter that runs them.
@Suite("Matched biquads")
struct BiquadTests {
    static let rates = [44_100.0, 48_000, 96_000, 192_000]

    /// Uniform white noise in [−1, 1) from xorshift64*, seeded so every run filters the same samples.
    struct WhiteNoise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func next() -> Double {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return Double((state &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 52) - 1
        }
    }

    @Test("A 16 kHz high shelf at 44.1 kHz keeps the analog shape up to 20 kHz, where a bilinear design cramps it")
    func matchesAnalogNearNyquist() {
        let shelf = BiquadCoefficients.design(.highShelf, frequency: 16_000, gainDb: 6, q: 0.707, sampleRate: 44_100)
        for hz in [18_000.0, 20_000] {
            let analog = BiquadCoefficients.analogMagnitudeDb(
                .highShelf, frequency: 16_000, gainDb: 6, q: 0.707, atHz: hz)
            #expect(abs(shelf.magnitudeDb(atHz: hz, sampleRate: 44_100) - analog) < 0.25, "at \(hz) Hz")
        }
    }

    @Test("A peak reaches its gain at its centre frequency at every output rate")
    func peakHitsItsGain() {
        for rate in Self.rates {
            let peak = BiquadCoefficients.design(.peak, frequency: 1_000, gainDb: 9, q: 1.41, sampleRate: rate)
            #expect(abs(peak.magnitudeDb(atHz: 1_000, sampleRate: rate) - 9) < 0.01, "at \(rate) Hz")
        }
    }

    @Test("Low- and high-pass filters are 3 dB down at their cutoff, and the low-pass is 40 dB down by 20 kHz")
    func passesAreRightAtCutoff() {
        for rate in Self.rates {
            let lowPass = BiquadCoefficients.design(.lowPass, frequency: 1_000, gainDb: 0, q: 0.7071, sampleRate: rate)
            let highPass = BiquadCoefficients.design(
                .highPass, frequency: 1_000, gainDb: 0, q: 0.7071, sampleRate: rate)
            #expect(abs(lowPass.magnitudeDb(atHz: 1_000, sampleRate: rate) + 3.01) < 0.05, "low-pass at \(rate) Hz")
            #expect(abs(highPass.magnitudeDb(atHz: 1_000, sampleRate: rate) + 3.01) < 0.05, "high-pass at \(rate) Hz")
            #expect(lowPass.magnitudeDb(atHz: 20_000, sampleRate: rate) < -40, "low-pass at \(rate) Hz")
        }
    }

    @Test("A notch takes its centre frequency down by more than 60 dB")
    func notchIsDeep() {
        for rate in Self.rates {
            let notch = BiquadCoefficients.design(.notch, frequency: 1_000, gainDb: 0, q: 4, sampleRate: rate)
            #expect(notch.magnitudeDb(atHz: 1_000, sampleRate: rate) < -60, "at \(rate) Hz")
        }
    }

    @Test(
        "Every design is stable and filters noise to finite output at the extremes of frequency, gain, Q and rate",
        arguments: FilterType.allCases)
    func stableEverywhere(type: FilterType) {
        for rate in Self.rates + [384_000] {
            for hz in [20, 1_000, 10_000, 0.45 * rate] {
                for gain in [-24.0, 0, 24] {
                    for q in [0.1, 1, 20] {
                        let c = BiquadCoefficients.design(type, frequency: hz, gainDb: gain, q: q, sampleRate: rate)
                        let settings = "\(hz) Hz, \(gain) dB, Q \(q) at \(rate) Hz"
                        #expect(abs(c.a2) < 1 && abs(c.a1) < 1 + c.a2, "poles outside the unit circle: \(settings)")
                        var filter = Biquad(c)
                        var noise = WhiteNoise()
                        var nonFinite = 0
                        for _ in 0..<10_000 {
                            if !filter.process(noise.next()).isFinite { nonFinite += 1 }
                        }
                        #expect(nonFinite == 0, "non-finite output: \(settings)")
                    }
                }
            }
        }
    }

    @Test("A cut is the exact mirror of the same boost, as it is in the analog prototypes")
    func cutsMirrorBoosts() {
        let rate = 48_000.0
        func design(_ type: FilterType, _ hz: Double, _ gain: Double, _ q: Double) -> BiquadCoefficients {
            .design(type, frequency: hz, gainDb: gain, q: q, sampleRate: rate)
        }
        for type in [FilterType.peak, .lowShelf, .highShelf] {
            for hz in [100.0, 1_000, 16_000] {
                for gain in [3.0, 12, 24] {
                    for q in [0.5, 0.7071, 4] {
                        let boost = design(type, hz, gain, q)
                        let cut = design(type, hz, -gain, q)
                        for probe in [30.0, 300, 3_000, hz, 15_000, 23_000] {
                            let sum =
                                boost.magnitudeDb(atHz: probe, sampleRate: rate)
                                + cut.magnitudeDb(atHz: probe, sampleRate: rate)
                            #expect(abs(sum) < 1e-9, "\(type) \(hz) Hz ±\(gain) dB Q \(q), probed at \(probe) Hz")
                        }
                    }
                }
            }
        }
    }

    @Test("Out-of-range settings are clamped: frequency to 1 Hz…0.49 × the rate, Q to 0.1…20, gain to ±24 dB")
    func designClampsItsInputs() {
        func peak(_ hz: Double, _ gain: Double, _ q: Double) -> BiquadCoefficients {
            .design(.peak, frequency: hz, gainDb: gain, q: q, sampleRate: 48_000)
        }
        #expect(peak(30_000, 6, 1) == peak(0.49 * 48_000, 6, 1))
        #expect(peak(0, 6, 1) == peak(1, 6, 1))
        #expect(peak(1_000, 6, 0) == peak(1_000, 6, 0.1))
        #expect(peak(1_000, 6, 100) == peak(1_000, 6, 20))
        #expect(peak(1_000, 40, 1) == peak(1_000, 24, 1))
        #expect(peak(1_000, -40, 1) == peak(1_000, -24, 1))
    }

    @Test("The filter runs its coefficients' difference equation in transposed direct form II")
    func filterRunsTheDifferenceEquation() {
        let c = BiquadCoefficients(b0: 0.5, b1: 0.25, b2: -0.125, a1: -0.5, a2: 0.25)
        var filter = Biquad(c)
        let x = [1.0, 0, 0, 0.5, -1]
        var y: [Double] = []
        for (n, sample) in x.enumerated() {
            let x1 = n >= 1 ? x[n - 1] : 0
            let x2 = n >= 2 ? x[n - 2] : 0
            let y1 = n >= 1 ? y[n - 1] : 0
            let y2 = n >= 2 ? y[n - 2] : 0
            y.append(c.b0 * sample + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2)
            #expect(abs(filter.process(sample) - y[n]) < 1e-15, "sample \(n)")
        }
    }
}
