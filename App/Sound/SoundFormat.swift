import Foundation
import PFDSP

/// How the Sound tab writes its values: monospaced digits with their units, a true minus sign, three significant
/// figures for frequencies ("31.5 Hz", "1.2 kHz") and a decimal for decibels ("−3.5 dB"). Each has a spoken twin for
/// VoiceOver, with the units in words.
enum SoundFormat {
    static let minus = "\u{2212}"

    /// `value` to `figures` significant figures.
    static func rounded(_ value: Double, figures: Int = 3) -> Double {
        guard value.isFinite, value != 0 else { return value }
        let scale = pow(10, Double(figures) - ceil(log10(abs(value))))
        return (value * scale).rounded() / scale
    }

    /// Decibels to a tenth.
    static func tenth(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// Q to two decimals below 10, one above.
    static func roundedQ(_ q: Double) -> Double {
        q < 10 ? (q * 100).rounded() / 100 : (q * 10).rounded() / 10
    }

    /// "31.5 Hz", "125 Hz", "1.2 kHz", "12.5 kHz".
    static func frequency(_ hz: Double) -> String {
        let r = rounded(hz)
        return r >= 1000 ? "\(trimmed(r / 1000)) kHz" : "\(trimmed(r)) Hz"
    }

    static func frequencySpoken(_ hz: Double) -> String {
        let r = rounded(hz)
        return r >= 1000 ? "\(trimmed(r / 1000)) kilohertz" : "\(trimmed(r)) hertz"
    }

    /// The graphic sliders' labels: "31", "63", "1k", "16k".
    static func frequencyShort(_ hz: Double) -> String {
        hz >= 1000 ? "\(trimmed(rounded(hz) / 1000))k" : "\(Int(hz))"
    }

    /// Up to three decimals, without trailing zeros.
    static func trimmed(_ value: Double) -> String {
        var s = String(format: "%.3f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// "+3.5", "−3.5", "0.0": a sign except at zero.
    static func signed(_ value: Double, decimals: Int = 1) -> String {
        let text = String(format: "%.\(decimals)f", abs(value))
        if Double(text) == 0 { return text }
        return (value < 0 ? minus : "+") + text
    }

    /// "+2", "−1.5", "0": a sign except at zero, and only the decimals it needs.
    static func signedTrimmed(_ value: Double) -> String {
        let text = trimmed(abs(tenth(value)))
        if text == "0" { return text }
        return (value < 0 ? minus : "+") + text
    }

    /// "+3.5 dB".
    static func gain(_ db: Double, unit: String = "dB") -> String {
        "\(signed(db)) \(unit)"
    }

    static func gainSpoken(_ db: Double) -> String {
        let text = trimmed(abs(tenth(db)))
        if text == "0" { return "0 decibels" }
        return "\(db < 0 ? "minus" : "plus") \(text) decibels"
    }

    /// "0.71", "12.0".
    static func q(_ q: Double) -> String {
        String(format: q < 10 ? "%.2f" : "%.1f", q)
    }

    static func qSpoken(_ q: Double) -> String {
        "Q \(SoundFormat.q(q))"
    }

    /// A meter level: "−12.3", or "−∞" at the floor.
    static func level(_ dbfs: Double) -> String {
        dbfs <= -119.95 ? "\(minus)∞" : signed(dbfs)
    }
}

extension FilterType {
    var title: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        case .lowPass: "Low-pass"
        case .highPass: "High-pass"
        case .notch: "Notch"
        }
    }

    /// The low-pass, the high-pass and the notch ignore the gain.
    var usesGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf: true
        case .lowPass, .highPass, .notch: false
        }
    }
}
