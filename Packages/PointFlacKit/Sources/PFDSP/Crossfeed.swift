import Foundation

/// Headphone crossfeed: a port of libbs2b's filter (Bauer stereophonic-to-binaural DSP).
///
/// Ported from libbs2b 3.1.0 `src/bs2b.c` (`init()` and `cross_feed_d()`), MIT licence, copyright (c) 2005 Boris
/// Mikhaylov; the notice is in `App/ThirdPartyNotices.txt`. Each channel runs through a first-order low-pass (the cross
/// path, which feeds the opposite ear) and a first-order high-shelf (the direct path). The output is
/// `L = (hi[L] + lo[R]) * gain`, `R = (hi[R] + lo[L]) * gain`; `gain` makes up the attenuation the summed paths cause.
///
/// A plain value type with Double state and no allocation, locks or ARC traffic, so `process` is safe on the render
/// thread. Identical left and right input stays identical, because both paths are symmetric.
public struct Crossfeed: Sendable {
    // Low-pass (cross path) and high-boost (direct path) coefficients; libbs2b's a0_lo/b1_lo/a0_hi/a1_hi/b1_hi/gain.
    private let a0Lo: Double
    private let b1Lo: Double
    private let a0Hi: Double
    private let a1Hi: Double
    private let b1Hi: Double
    private let gain: Double

    // Recursive state per channel: low-pass output, high-boost output, previous input.
    private var loL = 0.0
    private var loR = 0.0
    private var hiL = 0.0
    private var hiR = 0.0
    private var prevL = 0.0
    private var prevR = 0.0

    /// Magnitudes below this are flushed to zero. Far below any audible or dither-relevant level (about −600 dBFS) and
    /// well above the subnormal range, so a silent tail never lets the recursive state decay into slow denormals.
    private static let flushThreshold = 1e-30

    /// libbs2b clamps the sample rate to 2 kHz … 384 kHz.
    public init(preset: CrossfeedPreset, sampleRate: Double) {
        let (cutHz, feedDb) = preset.parameters
        let rate = min(max(sampleRate, 2_000), 384_000)

        let gbLo = feedDb * -5.0 / 6.0 - 3.0  // low-pass gain, dB
        let gbHi = feedDb / 6.0 - 3.0  // high-boost gain, dB
        let gLo = pow(10, gbLo / 20)
        let gHi = 1 - pow(10, gbHi / 20)
        let fcHi = cutHz * pow(2, (gbLo - 20 * log10(gHi)) / 12)

        var x = exp(-2 * Double.pi * cutHz / rate)
        b1Lo = x
        a0Lo = gLo * (1 - x)

        x = exp(-2 * Double.pi * fcHi / rate)
        b1Hi = x
        a0Hi = 1 - gHi * (1 - x)
        a1Hi = -x

        gain = 1 / (1 - gHi + gLo)
    }

    /// Crossfeeds one stereo frame in place.
    public mutating func process(left: inout Double, right: inout Double) {
        let inL = left
        let inR = right
        loL = Self.flush(a0Lo * inL + b1Lo * loL)
        loR = Self.flush(a0Lo * inR + b1Lo * loR)
        hiL = Self.flush(a0Hi * inL + a1Hi * prevL + b1Hi * hiL)
        hiR = Self.flush(a0Hi * inR + a1Hi * prevR + b1Hi * hiR)
        prevL = inL
        prevR = inR
        left = (hiL + loR) * gain
        right = (hiR + loL) * gain
    }

    @inline(__always)
    private static func flush(_ value: Double) -> Double {
        abs(value) < flushThreshold ? 0 : value
    }
}
