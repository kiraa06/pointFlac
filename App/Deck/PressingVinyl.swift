import PFDesign
import SwiftUI

/// A pressing's vinyl (spec §3 and §8.2–3): translucent in its pressing colour, with its own opacity curve, a light
/// wash, the lamp's streaks glowing through it and a bright rim; or, for Onyx, the deck's opaque black vinyl.
enum PressingVinyl: Equatable {
    case black
    case translucent(PressingRGB)

    /// The translucent body, drawn under the grooves. `free` is a disc lying on its own (the shelf), which gets an
    /// opaque deep base so it reads the same on any background; on the deck the platter shows through instead.
    static func body(
        _ context: inout GraphicsContext, center c: CGPoint, radius r: CGFloat, label: CGFloat, tone: PressingRGB,
        free: Bool = false
    ) {
        let disc = PressingPaint.circle(c, r)
        let line = max(0.5, r / 150)
        if free {
            context.fill(
                disc,
                with: .radialGradient(
                    Gradient(colors: [Color(tone.mixed(with: .black, 0.55)), Color(tone.mixed(with: .black, 0.32))]),
                    center: c, startRadius: label, endRadius: r))
        }
        // Denser toward the rim, where light crosses more vinyl, and brighter at the very edge.
        context.fill(
            disc,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(tone, opacity: free ? 0.45 : 0.52), location: 0),
                    .init(color: Color(tone, opacity: free ? 0.6 : 0.62), location: 0.55),
                    .init(color: Color(tone, opacity: free ? 0.8 : 0.76), location: 0.94),
                    .init(color: Color(tone.mixed(with: .white, 0.12), opacity: 0.9), location: 1),
                ]), center: c, startRadius: label, endRadius: r))
        context.fill(disc, with: .color(.black.opacity(0.08)))
        // Light passing through the vinyl: the colour glows brighter inside the lamp's two wedges.
        var glow = context
        glow.blendMode = .screen
        glow.fill(
            disc.subtracting(PressingPaint.circle(c, label)),
            with: RecordLight.streaks(
                center: c, near: 0.3, far: 0.2, spread: 1.35, colour: Color(tone.mixed(with: .white, 0.25))))
        // And along the rim, where it pipes out of the edge.
        context.stroke(
            PressingPaint.circle(c, r - 1.5 * line),
            with: .color(Color(tone.mixed(with: .white, 0.35), opacity: free ? 0.55 : 0.42)), lineWidth: 1.8 * line)
    }
}
