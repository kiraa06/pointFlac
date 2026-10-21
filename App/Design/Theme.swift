import PFCore
import SwiftUI
import UIKit

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
    /// The Hi-Res text's gold: delivered above 48 kHz at 24 bits or more.
    let hiRes: Color
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
    /// True for the greyscale twin made by `monochrome()`.
    var isMonochrome = false

    static func deck(dark: Bool) -> Theme {
        dark
            ? Theme(
                isDark: true, background: Color(red: 0.07, green: 0.07, blue: 0.09), ink: .white,
                inkSecondary: .white.opacity(0.6), hairline: .white.opacity(0.22),
                ok: Color(red: 0.49, green: 1, blue: 0.70), altered: Color(red: 0.69, green: 0.55, blue: 1),
                warn: Color(red: 1, green: 0.75, blue: 0.35), hiRes: Color(red: 1, green: 0.82, blue: 0.40),
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
                warn: Color(red: 0.78, green: 0.45, blue: 0.05), hiRes: Color(red: 0.55, green: 0.39, blue: 0.0),
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
                hiRes: Color(red: 1, green: 0.82, blue: 0.40),
                playFill: .white, playGlyph: .black,
                plinthTop: .clear, plinthBottom: .clear, plinthEdge: .clear, strobe: .clear,
                lcdBack: .clear, lcdInk: .clear, glow: 0.5)
            : Theme(
                isDark: false, background: Color(red: 0.985, green: 0.98, blue: 0.97), ink: Color(white: 0.06),
                inkSecondary: Color(white: 0.38), hairline: .black.opacity(0.14),
                ok: Color(red: 0.12, green: 0.62, blue: 0.39), altered: Color(red: 0.48, green: 0.25, blue: 0.95),
                warn: Color(red: 0.78, green: 0.45, blue: 0.05), hiRes: Color(red: 0.55, green: 0.39, blue: 0.0),
                playFill: Color(white: 0.07), playGlyph: .white, plinthTop: .clear, plinthBottom: .clear,
                plinthEdge: .clear, strobe: .clear, lcdBack: .clear, lcdInk: .clear, glow: 0.32)
    }
}

// MARK: Monochrome

extension Color {
    /// The colour as a grey of the same perceived brightness (Rec. 709 luma), resolved for the light or dark style
    /// and keeping its opacity.
    fileprivate func greyscale(dark: Bool) -> (grey: Double, alpha: Double) {
        let resolved = UIColor(self).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Luma.grey(r: r, g: g, b: b), a)
    }

    /// The greyscale twin of the colour.
    func monochrome(dark: Bool) -> Color {
        let m = greyscale(dark: dark)
        return Color(white: m.grey, opacity: m.alpha)
    }
}

extension Theme {
    /// The greyscale twin of this look: every token at the same perceived brightness, so contrast and hierarchy are
    /// as designed. Text colours are nudged only as far as needed to keep 4.5:1 on the background, because hue no
    /// longer helps them stand out.
    func monochrome() -> Theme {
        let back = background.greyscale(dark: isDark).grey
        func grey(_ c: Color) -> Color { c.monochrome(dark: isDark) }
        func text(_ c: Color) -> Color {
            let m = c.greyscale(dark: isDark)
            return Color(white: Luma.readable(m.grey, alpha: m.alpha, on: back), opacity: m.alpha)
        }
        var twin = Theme(
            isDark: isDark, background: grey(background), ink: grey(ink), inkSecondary: text(inkSecondary),
            hairline: grey(hairline), ok: text(ok), altered: text(altered), warn: text(warn), hiRes: text(hiRes),
            playFill: grey(playFill), playGlyph: grey(playGlyph), plinthTop: grey(plinthTop),
            plinthBottom: grey(plinthBottom), plinthEdge: grey(plinthEdge), strobe: grey(strobe),
            lcdBack: grey(lcdBack), lcdInk: grey(lcdInk), glow: glow)
        twin.isMonochrome = true
        return twin
    }

    /// The look for a stage, in greys when Monochrome is on.
    static func look(stage: PlayerStage, dark: Bool, monochrome: Bool) -> Theme {
        if monochrome {
            return monoLooks[LookKey(deck: stage == .deck, dark: dark)] ?? Theme.deck(dark: dark).monochrome()
        }
        return stage == .deck ? deck(dark: dark) : cover(dark: dark)
    }

    private struct LookKey: Hashable {
        let deck: Bool
        let dark: Bool
    }

    /// The four greyscale twins, resolved once: the player reads its theme many times a pass.
    private static let monoLooks: [LookKey: Theme] = {
        var looks: [LookKey: Theme] = [:]
        for deck in [true, false] {
            for dark in [true, false] {
                looks[LookKey(deck: deck, dark: dark)] = (deck ? Theme.deck(dark: dark) : Theme.cover(dark: dark))
                    .monochrome()
            }
        }
        return looks
    }()

    /// Monochrome's control tint: near-black on light, a mid grey on dark. Not the dark ink itself: an on switch fills
    /// its track with the tint, and a white track would swallow the white knob. 0.62 keeps the knob visible (2.7:1) and
    /// tinted text readable on the dark background (7:1).
    static let monochromeTint = Color(
        uiColor: UIColor {
            UIColor(white: $0.userInterfaceStyle == .dark ? 0.62 : 0.08, alpha: 1)
        })
}

/// Whether Monochrome mode is on, for views that draw a colour of their own instead of taking it from a `Theme`.
extension EnvironmentValues {
    @Entry var isMonochrome = false
}

extension View {
    /// Foreground in `colour`, or in the secondary grey when Monochrome is on.
    func monoForeground(_ colour: Color) -> some View { modifier(MonoForeground(colour: colour)) }
}

private struct MonoForeground: ViewModifier {
    let colour: Color
    @Environment(\.isMonochrome) private var mono
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if mono {
            content.foregroundStyle(colour.monochrome(dark: scheme == .dark))
        } else {
            content.foregroundStyle(colour)
        }
    }
}

/// Destructive-role buttons are system red whatever the tint, so under Monochrome they get a grey of their own:
/// a swipe action's background, and a plain button's label. `role: .destructive` stays for VoiceOver.
private struct MonoDestructive: ViewModifier {
    @Environment(\.isMonochrome) private var mono
    func body(content: Content) -> some View {
        if mono {
            content.tint(Color(white: 0.35)).foregroundStyle(.primary)
        } else {
            content
        }
    }
}

extension View {
    /// Greys a destructive-role button under Monochrome; unchanged otherwise.
    func monoDestructive() -> some View { modifier(MonoDestructive()) }
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
    /// `base`'s hue, deep enough to draw a line with on a light background (the progress wave in light mode).
    let line: Color

    init(base: Color, deep: Color, night: Color, sun: Color, sea: Color, line: Color) {
        self.base = base
        self.deep = deep
        self.night = night
        self.sun = sun
        self.sea = sea
        self.line = line
    }

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
        line = Color(hue: hue(0), saturation: 0.85, brightness: 0.68)
    }
}

extension ArtPalette {
    /// The palette in greys, for what tints the interface (the glow, the wash, the progress wave). The sleeve and the
    /// art are always drawn from the original.
    @MainActor private static var monoCache: [ArtPalette: ArtPalette] = [:]

    @MainActor func monochrome() -> ArtPalette {
        if let cached = Self.monoCache[self] { return cached }
        let twin = greyTwin()
        if Self.monoCache.count > 256 { Self.monoCache.removeAll() }
        Self.monoCache[self] = twin
        return twin
    }

    private func greyTwin() -> ArtPalette {
        ArtPalette(
            base: base.monochrome(dark: false), deep: deep.monochrome(dark: false),
            night: night.monochrome(dark: false),
            sun: sun.monochrome(dark: false), sea: sea.monochrome(dark: false), line: line.monochrome(dark: false))
    }

    /// The palette for tinting `theme`'s glass: greys when the theme is monochrome.
    @MainActor func tint(for theme: Theme) -> ArtPalette { theme.isMonochrome ? monochrome() : self }
}
