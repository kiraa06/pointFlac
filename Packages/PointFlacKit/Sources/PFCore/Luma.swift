import Foundation

/// Greyscale arithmetic for Monochrome mode: the grey with the same perceived brightness as a colour, and the
/// contrast checks that keep text readable once its hue is gone. Pure maths, so it is tested here.
public enum Luma {
    /// Rec. 709 luma of gamma-encoded sRGB components (0...1): pure red is 0.2126, white stays 1.
    public static func grey(r: Double, g: Double, b: Double) -> Double {
        min(max(0.2126 * r + 0.7152 * g + 0.0722 * b, 0), 1)
    }

    /// WCAG relative luminance of a grey given as a gamma-encoded value.
    public static func relativeLuminance(ofGrey grey: Double) -> Double {
        grey <= 0.04045 ? grey / 12.92 : pow((grey + 0.055) / 1.055, 2.4)
    }

    /// WCAG contrast ratio (1...21) between two greys.
    public static func contrast(_ a: Double, _ b: Double) -> Double {
        let la = relativeLuminance(ofGrey: a)
        let lb = relativeLuminance(ofGrey: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `grey`, pushed away from `background` (darker on a light one, lighter on a dark one) until the contrast
    /// reaches `ratio`. Unchanged when it already does.
    public static func readable(_ grey: Double, on background: Double, ratio: Double = 4.5) -> Double {
        guard contrast(grey, background) < ratio else { return grey }
        let step = background >= 0.5 ? -0.005 : 0.005
        var g = grey
        while contrast(g, background) < ratio, g > 0, g < 1 { g = min(max(g + step, 0), 1) }
        return g
    }
}
