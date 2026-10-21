import Foundation

/// The filter shapes of the EQ, the tone controls and headphone correction.
///
/// Each is the analog prototype of that name in the RBJ Audio EQ Cookbook (W3C Note), which fixes what frequency, gain
/// and Q mean; ``BiquadCoefficients/design(_:frequency:gainDb:q:sampleRate:)`` matches it digitally. The raw values
/// are stored in settings, so they never change.
public enum FilterType: String, Codable, CaseIterable, Sendable {
    /// A bell: the gain at the frequency, 0 dB far either side, narrower as Q rises.
    case peak
    /// The gain below the frequency and 0 dB above it, with half the gain (in dB) at the frequency.
    case lowShelf
    /// 0 dB below the frequency and the gain above it, with half the gain (in dB) at the frequency.
    case highShelf
    /// Falls 12 dB per octave above the frequency, where its level is Q (−3 dB at Q 0.7071). Ignores the gain.
    case lowPass
    /// Falls 12 dB per octave below the frequency, where its level is Q. Ignores the gain.
    case highPass
    /// Silent at the frequency, 0 dB far either side, narrower as Q rises. Ignores the gain.
    case notch
}

/// A second-order section's coefficients, normalised so that a0 = 1:
/// H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²).
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }
}

// MARK: Matched designs

extension BiquadCoefficients {
    /// The matched design of a ``FilterType`` (M. Vicanek, "Matched Second Order Digital Filters", 2016).
    ///
    /// RBJ's cookbook designs by the bilinear transform, which squeezes the whole analog frequency axis into the band
    /// below Nyquist, so responses cramp near Nyquist: a 16 kHz shelf at 44.1 kHz is off by decibels. A matched design
    /// keeps the analog prototype's poles, mapped by impulse invariance (z = e^{sT}), and chooses the zeros so that the
    /// digital magnitude equals the analog one at a few frequencies:
    /// - low-pass and shelves: at DC, at Nyquist and at `frequency` (the paper's squared-magnitude matching, §4);
    /// - peak: unity at DC, and the gain at `frequency` with an extremum there (§4.4, eqs. 44–45);
    /// - high-pass: a double zero at DC, which the analog 12 dB per octave needs, and Q at `frequency` (§4.2, eq. 36);
    /// - notch: its zeros exactly on the unit circle at `frequency`, and unity at DC.
    ///
    /// A shelf's analog poles sit at `frequency`·√A or `frequency`/√A (RBJ's A is the square root of the linear
    /// gain): above `frequency`, up to twice it, for a high-shelf boost or a low-shelf cut. Impulse invariance folds
    /// poles above Nyquist back below it, where no choice of zeros recovers the shape. So those two are designed as the
    /// exact inverse of the opposite gain, whose poles sit at or below `frequency`, as the analog prototypes are
    /// inverses (H at −g is 1/H at +g). A peak's cut is the inverse of its boost too: the boost's sharp resonance is in
    /// its poles, which impulse invariance keeps exactly, where a cut's would be in zeros that are only fitted. Every
    /// cut thus mirrors its boost exactly, and a boost then the same cut is flat.
    ///
    /// The frequency is clamped to 1 Hz…0.49 × `sampleRate`, Q to 0.1…20 and the gain to ±24 dB. The gain is ignored
    /// by the low-pass, high-pass and notch.
    public static func design(
        _ type: FilterType, frequency: Double, gainDb: Double, q: Double, sampleRate: Double
    ) -> BiquadCoefficients {
        let frequency = min(max(frequency, 1), 0.49 * sampleRate)
        let q = min(max(q, 0.1), 20)
        let gainDb = min(max(gainDb, -24), 24)
        let asInverse =
            switch type {
            case .peak, .lowShelf: gainDb < 0
            case .highShelf: gainDb > 0
            case .lowPass, .highPass, .notch: false
            }
        guard asInverse else {
            return matched(type, frequency: frequency, gainDb: gainDb, q: q, sampleRate: sampleRate)
        }
        return matched(type, frequency: frequency, gainDb: -gainDb, q: q, sampleRate: sampleRate).inverse
    }

    /// The digital magnitude response at `f` Hz, in dB: −infinity at an exact zero.
    public func magnitudeDb(atHz f: Double, sampleRate: Double) -> Double {
        let omega = 2 * .pi * f / sampleRate
        let numerator = Self.squaredMagnitude(b0, b1, b2, omega: omega)
        return 10 * log10(numerator / Self.squaredMagnitude(1, a1, a2, omega: omega))
    }

    /// The analog prototype's magnitude response at `atHz`, in dB: what ``design(_:frequency:gainDb:q:sampleRate:)``
    /// matches. Takes its settings as given (`frequency` and `q` above zero), unclamped.
    public static func analogMagnitudeDb(
        _ type: FilterType, frequency: Double, gainDb: Double, q: Double, atHz: Double
    ) -> Double {
        10 * log10(analogPowerGain(type, sqrtGain: pow(10, gainDb / 40), q: q, ratio: atHz / frequency))
    }

    /// The matched design for already-clamped settings, taken as given (no inversion).
    private static func matched(
        _ type: FilterType, frequency: Double, gainDb: Double, q: Double, sampleRate: Double
    ) -> BiquadCoefficients {
        let w0 = 2 * .pi * frequency / sampleRate
        // The paper's φ₁ = sin²(ω₀/2) and φ₀ = 1 − φ₁, at the matching frequency.
        let phi1 = sin(w0 / 2) * sin(w0 / 2)
        let phi0 = 1 - phi1
        let sqrtGain = pow(10, gainDb / 40)
        // The analog poles' natural frequency, as a multiple of ω₀, and damping, read off RBJ's denominators.
        let (scale, damping): (Double, Double) =
            switch type {
            case .peak: (1, 1 / (2 * sqrtGain * q))
            case .lowShelf: (1 / sqrtGain.squareRoot(), 1 / (2 * q))
            case .highShelf: (sqrtGain.squareRoot(), 1 / (2 * q))
            case .lowPass, .highPass, .notch: (1, 1 / (2 * q))
            }
        let (a1, a2) = matchedPoles(omega: scale * w0, damping: damping)
        // The paper's A₀, A₁, A₂ (eq. 27): the denominator's squared magnitude is A₀φ₀ + A₁φ₁ + 4A₂φ₀φ₁.
        let aa0 = (1 + a1 + a2) * (1 + a1 + a2)
        let aa1 = (1 - a1 + a2) * (1 - a1 + a2)
        let aa2 = -4 * a2
        let powerAtW0 = analogPowerGain(type, sqrtGain: sqrtGain, q: q, ratio: 1)
        // The numerator's squared magnitude at ω₀ that matches the analog there.
        let targetAtW0 = squaredMagnitude(1, a1, a2, omega: w0) * powerAtW0

        switch type {
        case .highPass:
            // b = b0·(1, −2, 1), whose squared magnitude at ω₀ is (4·b0·φ₁)².
            let b0 = targetAtW0.squareRoot() / (4 * phi1)
            return BiquadCoefficients(b0: b0, b1: -2 * b0, b2: b0, a1: a1, a2: a2)
        case .notch:
            // b = b0·(1, −2·cos ω₀, 1), which is 4·b0·φ₁ at DC, against the denominator's 1 + a1 + a2.
            let b0 = (1 + a1 + a2) / (4 * phi1)
            return BiquadCoefficients(b0: b0, b1: -2 * b0 * cos(w0), b2: b0, a1: a1, a2: a2)
        case .peak:
            // Eqs. 44–45 with B₀ = A₀ (unity at DC): R₁ is the squared magnitude at ω₀ and R₂ its slope in φ, both the
            // denominator's times the analog power gain, so that ω₀ is also an extremum.
            let r2 = (-aa0 + aa1 + 4 * (phi0 - phi1) * aa2) * powerAtW0
            let bb2 = (targetAtW0 - r2 * phi1 - aa0) / (4 * phi1 * phi1)
            let bb1 = r2 + aa0 + 4 * (phi1 - phi0) * bb2
            return withNumerator(bb0: aa0, bb1: bb1, bb2: bb2, a1: a1, a2: a2)
        case .lowPass, .lowShelf, .highShelf:
            // B₀ and B₁ are the numerator's squared magnitudes at DC and Nyquist (the analog's there times the
            // denominator's), and B₂ then follows from the match at ω₀.
            let bb0 = aa0 * analogPowerGain(type, sqrtGain: sqrtGain, q: q, ratio: 0)
            let bb1 = aa1 * analogPowerGain(type, sqrtGain: sqrtGain, q: q, ratio: .pi / w0)
            let bb2 = (targetAtW0 - bb0 * phi0 - bb1 * phi1) / (4 * phi0 * phi1)
            return withNumerator(bb0: bb0, bb1: bb1, bb2: bb2, a1: a1, a2: a2)
        }
    }

    /// The poles of the analog s² + 2ζωs + ω² mapped by impulse invariance, z = e^{s} with s in radians per sample
    /// (the paper's eq. 12): complex for ζ ≤ 1, real otherwise, and inside the unit circle for any ω, ζ > 0.
    private static func matchedPoles(omega: Double, damping zeta: Double) -> (a1: Double, a2: Double) {
        let decay = exp(-zeta * omega)
        guard zeta > 1 else { return (-2 * decay * cos((1 - zeta * zeta).squareRoot() * omega), decay * decay) }
        return (-2 * decay * cosh((zeta * zeta - 1).squareRoot() * omega), decay * decay)
    }

    /// The minimum-phase numerator (zeros inside the unit circle) for the paper's B₀ = (b0 + b1 + b2)², the squared
    /// magnitude at DC, B₁ = (b0 − b1 + b2)², at Nyquist, and B₂ = −4·b0·b2 (eq. 29).
    private static func withNumerator(
        bb0: Double, bb1: Double, bb2: Double, a1: Double, a2: Double
    ) -> BiquadCoefficients {
        // A realisable response has B₁ ≥ 0 and W² + B₂ = (b0 − b2)² ≥ 0; the clamps only stop rounding from making NaN.
        let root0 = bb0.squareRoot()
        let root1 = max(bb1, 0).squareRoot()
        let w = (root0 + root1) / 2
        let b0 = (w + max(w * w + bb2, 0).squareRoot()) / 2
        return BiquadCoefficients(b0: b0, b1: (root0 - root1) / 2, b2: -bb2 / (4 * b0), a1: a1, a2: a2)
    }

    /// 1/H, normalised. Its poles are this design's zeros, which the matched numerators keep inside the unit circle.
    private var inverse: BiquadCoefficients {
        BiquadCoefficients(b0: 1 / b0, b1: a1 / b0, b2: a2 / b0, a1: b1 / b0, a2: b2 / b0)
    }

    /// |c0 + c1·e^{−jω} + c2·e^{−2jω}|², written as [(c0 + c2)·cos ω + c1]² + [(c0 − c2)·sin ω]² (the paper's eq. 24).
    /// Near a low-frequency resonance the first term all but cancels and the second carries the value, which keeps
    /// the precision that the φ-weighted sum of eq. 25 loses there.
    private static func squaredMagnitude(_ c0: Double, _ c1: Double, _ c2: Double, omega: Double) -> Double {
        let real = (c0 + c2) * cos(omega) + c1
        let imaginary = (c0 - c2) * sin(omega)
        return real * real + imaginary * imaginary
    }

    /// |H(jΩ)|² of the RBJ prototype, where Ω (`ratio`) is the frequency as a multiple of the filter's and `sqrtGain`
    /// is RBJ's A, the square root of the linear gain.
    private static func analogPowerGain(_ type: FilterType, sqrtGain a: Double, q: Double, ratio: Double) -> Double {
        let w2 = ratio * ratio
        let qSquared = q * q
        let undamped = (1 - w2) * (1 - w2)
        switch type {
        case .lowPass: return 1 / (undamped + w2 / qSquared)
        case .highPass: return w2 * w2 / (undamped + w2 / qSquared)
        case .notch: return undamped / (undamped + w2 / qSquared)
        case .peak: return (undamped + w2 * a * a / qSquared) / (undamped + w2 / (a * a * qSquared))
        case .lowShelf, .highShelf:
            // The low shelf is A·(s² + (√A/Q)·s + A) / (A·s² + (√A/Q)·s + 1); the high shelf swaps A·s² and A.
            let lowTerm = (a - w2) * (a - w2) + a * w2 / qSquared  // |A − Ω² + j·(√A/Q)·Ω|²
            let highTerm = (1 - a * w2) * (1 - a * w2) + a * w2 / qSquared  // |1 − A·Ω² + j·(√A/Q)·Ω|²
            return type == .lowShelf ? a * a * lowTerm / highTerm : a * a * highTerm / lowTerm
        }
    }
}

// MARK: Filter

/// One second-order section, run in transposed direct form II in Float64 (spec §5.2: the DSP graph is Float64): two
/// state variables, and real-time safe, as the render thread needs.
public struct Biquad: Sendable {
    /// The coefficients. Changing them keeps the state, so the filter carries on from where it was.
    public var c: BiquadCoefficients
    private var z1 = 0.0
    private var z2 = 0.0

    /// A filter at rest.
    public init(_ c: BiquadCoefficients) {
        self.c = c
    }

    /// Filters one sample. No allocation, locks or reference counting.
    public mutating func process(_ x: Double) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}
