import SwiftUI

/// The appearance override in Settings (spec §4.2): follow the phone, or force light or dark.
enum AppearanceOverride: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil follows the phone.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Colour tokens for the four designed looks: Deck light (frosted glass), Deck dark (smoked glass and chrome), Cover
/// dark (editorial) and Cover light (editorial on paper-white). Everything the player draws takes its colours from
/// here, so a look is changed in one place.
struct Theme {
    let isDark: Bool
    let background: Color
    let ink: Color
    let inkSecondary: Color
    let hairline: Color
    /// The "● Pure" green: the strip's only saturated colour, so the eye finds it.
    let ok: Color
    /// Something changed the sound on its way out (resampled, reduced, processed, a lossy route): electric violet,
    /// lively rather than alarming. `warn` stays for real warnings, such as a USB volume below full scale.
    let altered: Color
    let warn: Color
    let playFill: Color
    let playGlyph: Color
    let plinthTop: Color
    let plinthBottom: Color
    let plinthEdge: Color
    let strobe: Color
    let lcdBack: Color
    let lcdInk: Color
    /// How strongly the artwork's colours glow behind the glass, or wash the cover.
    let glow: Double

    static func deck(dark: Bool) -> Theme {
        dark
            ? Theme(
                isDark: true, background: Color(red: 0.07, green: 0.07, blue: 0.09), ink: .white,
                inkSecondary: .white.opacity(0.6), hairline: .white.opacity(0.22),
                ok: Color(red: 0.49, green: 1, blue: 0.70), altered: Color(red: 0.69, green: 0.55, blue: 1),
                warn: Color(red: 1, green: 0.75, blue: 0.35),
                playFill: .white, playGlyph: .black,
                plinthTop: Color(red: 0.20, green: 0.21, blue: 0.24).opacity(0.85),
                plinthBottom: Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.6),
                plinthEdge: .white.opacity(0.16), strobe: Color(red: 0.62, green: 0.64, blue: 0.70),
                lcdBack: Color(red: 0.03, green: 0.06, blue: 0.05), lcdInk: Color(red: 0.55, green: 1, blue: 0.77),
                glow: 0.16)
            : Theme(
                isDark: false, background: Color(red: 0.953, green: 0.949, blue: 0.937), ink: Color(white: 0.08),
                inkSecondary: Color(white: 0.45), hairline: .black.opacity(0.15),
                ok: Color(red: 0.12, green: 0.62, blue: 0.39), altered: Color(red: 0.48, green: 0.25, blue: 0.95),
                warn: Color(red: 0.78, green: 0.45, blue: 0.05),
                playFill: Color(white: 0.07), playGlyph: .white,
                plinthTop: .white.opacity(0.8), plinthBottom: Color(red: 0.92, green: 0.93, blue: 0.96).opacity(0.5),
                plinthEdge: .white.opacity(0.95), strobe: Color(red: 0.54, green: 0.55, blue: 0.58),
                lcdBack: Color(red: 0.05, green: 0.08, blue: 0.07), lcdInk: Color(red: 0.55, green: 1, blue: 0.77),
                glow: 0.28)
    }

    static func cover(dark: Bool) -> Theme {
        dark
            ? Theme(
                isDark: true, background: Color(white: 0.04), ink: .white, inkSecondary: .white.opacity(0.72),
                hairline: .white.opacity(0.25), ok: Color(red: 0.49, green: 1, blue: 0.70),
                altered: Color(red: 0.69, green: 0.55, blue: 1), warn: Color(red: 1, green: 0.75, blue: 0.35),
                playFill: .white, playGlyph: .black,
                plinthTop: .clear, plinthBottom: .clear, plinthEdge: .clear, strobe: .clear,
                lcdBack: .clear, lcdInk: .clear, glow: 0.5)
            : Theme(
                isDark: false, background: Color(red: 0.985, green: 0.98, blue: 0.97), ink: Color(white: 0.06),
                inkSecondary: Color(white: 0.38), hairline: .black.opacity(0.14),
                ok: Color(red: 0.12, green: 0.62, blue: 0.39), altered: Color(red: 0.48, green: 0.25, blue: 0.95),
                warn: Color(red: 0.78, green: 0.45, blue: 0.05),
                playFill: Color(white: 0.07), playGlyph: .white, plinthTop: .clear, plinthBottom: .clear,
                plinthEdge: .clear, strobe: .clear, lcdBack: .clear, lcdInk: .clear, glow: 0.32)
    }
}

/// Type tokens (spec §4.9): a grotesk for UI and titles, monospaced for numbers and signal data, and a dot-matrix
/// face for the deck's screen. The system's SF Pro and SF Mono stand in until Inter and Silkscreen (both OFL) are
/// bundled; the dot matrix is SF Mono drawn through a pixel grid (`DotMatrixText`).
enum Typeface {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .default) }
    static let artist = Font.system(.subheadline, design: .default)
    static let mono = Font.system(.caption, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .medium, design: .monospaced)
    /// The signal strip's values: a step below the artist line, so FORMAT · DEPTH · DAC · SIGNAL reads as a readout,
    /// not a second title.
    static let cellValue = Font.system(.footnote, design: .monospaced).weight(.semibold)
    static let cellLabel = Font.system(size: 9, weight: .medium, design: .monospaced)
}

/// The colours a sleeve is drawn with. Albums without art get a generated sleeve, and every album's glow and wash
/// come from these, so the player tints itself to the record.
struct ArtPalette: Hashable {
    let base: Color
    let deep: Color
    let night: Color
    let sun: Color
    let sea: Color

    /// A stable palette from any string (the album's id): the same album always gets the same sleeve.
    init(seed: String) {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let h = Double(hash % 1000) / 1000
        func hue(_ x: Double) -> Double { (h + x).truncatingRemainder(dividingBy: 1) }
        base = Color(hue: hue(0), saturation: 0.76, brightness: 1)
        deep = Color(hue: hue(0.78), saturation: 0.68, brightness: 0.56)
        night = Color(hue: hue(0.6), saturation: 0.72, brightness: 0.27)
        sun = Color(hue: hue(0.1), saturation: 0.66, brightness: 0.97)
        sea = Color(hue: hue(0.45), saturation: 0.8, brightness: 0.71)
    }
}
