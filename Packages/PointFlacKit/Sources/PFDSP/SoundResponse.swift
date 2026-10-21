import Foundation

/// The combined frequency response of the equaliser-like stages: what the EQ graph draws and what the automatic
/// headroom is sized from. It reads the same bands the audio path does, so the graph never disagrees with the sound.
public enum SoundResponse {
    /// The lowest level reported for any band or the sum. A notch's centre is an exact zero (−∞ dB); flooring it keeps
    /// the curve and the headroom finite.
    private static let floorDb = -120.0

    /// The filters in chain order (correction, then EQ, then tone), skipping disabled blocks and bands. Empty in Pure.
    public static func filters(_ s: SoundSettings, sampleRate: Double) -> [BiquadCoefficients] {
        bands(s.clamped()).map {
            BiquadCoefficients.design(
                $0.type, frequency: $0.frequency, gainDb: $0.gainDb, q: $0.q, sampleRate: sampleRate)
        }
    }

    /// The combined response, log-spaced from 20 Hz to `min(20 000, 0.49·fs)`, including the correction's preamp.
    public static func curveDb(
        _ s: SoundSettings, sampleRate: Double, points: Int = 256
    ) -> [(hz: Double, db: Double)] {
        let s = s.clamped()
        let filters = filters(s, sampleRate: sampleRate)
        let preamp = preampDb(s)
        return grid(sampleRate: sampleRate, points: points).map {
            (hz: $0, db: response($0, filters, preamp, sampleRate))
        }
    }

    /// The gain (zero or negative) that keeps the combined response from exceeding 0 dB, so boosts cannot clip.
    /// Found on a 1024-point log grid, then refined by golden-section search between the best point's neighbours,
    /// because a narrow peak can fall between grid points and understate the boost.
    public static func autoHeadroomDb(_ s: SoundSettings, sampleRate: Double) -> Double {
        let s = s.clamped()
        let filters = filters(s, sampleRate: sampleRate)
        let preamp = preampDb(s)
        let f: (Double) -> Double = { response($0, filters, preamp, sampleRate) }
        let hz = grid(sampleRate: sampleRate, points: 1024)
        var best = 0
        var peak = -Double.infinity
        for (i, h) in hz.enumerated() {
            let v = f(h)
            if v > peak {
                peak = v
                best = i
            }
        }
        let invPhi = (5.0.squareRoot() - 1) / 2
        // Search in log frequency, where the grid and the filters' shapes are even.
        var a = log(hz[max(best - 1, 0)])
        var b = log(hz[min(best + 1, hz.count - 1)])
        var c = b - invPhi * (b - a)
        var d = a + invPhi * (b - a)
        var fc = f(exp(c))
        var fd = f(exp(d))
        for _ in 0..<40 {
            if fc > fd {
                b = d
                d = c
                fd = fc
                c = b - invPhi * (b - a)
                fc = f(exp(c))
            } else {
                a = c
                c = d
                fc = fd
                d = a + invPhi * (b - a)
                fd = f(exp(d))
            }
        }
        peak = max(peak, fc, fd)
        return min(0, -peak)
    }

    private static func bands(_ s: SoundSettings) -> [EQBand] {
        guard !s.pure else { return [] }
        var all: [EQBand] = []
        if s.correction.enabled { all += s.correction.bands }
        if s.eq.enabled { all += s.eq.effectiveBands }
        if s.tone.enabled { all += s.tone.effectiveBands }
        return all.filter(\.enabled)
    }

    /// The correction preset's own pre-gain, which is part of the curve while the correction is in the chain.
    private static func preampDb(_ s: SoundSettings) -> Double {
        !s.pure && s.correction.enabled ? s.correction.preampDb : 0
    }

    private static func response(
        _ hz: Double, _ filters: [BiquadCoefficients], _ preamp: Double, _ sampleRate: Double
    ) -> Double {
        let sum = filters.reduce(preamp) { $0 + max($1.magnitudeDb(atHz: hz, sampleRate: sampleRate), floorDb) }
        return max(sum, floorDb)
    }

    private static func grid(sampleRate: Double, points: Int) -> [Double] {
        let lo = 20.0
        let hi = max(min(20_000, 0.49 * sampleRate), lo)
        guard points > 1 else { return [lo] }
        let ratio = hi / lo
        return (0..<points).map { i in
            i == points - 1 ? hi : lo * pow(ratio, Double(i) / Double(points - 1))
        }
    }
}
