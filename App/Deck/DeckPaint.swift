import PFDesign
import SwiftUI

/// A design's colours as the deck draws them, resolved once for the look: through `DeckColors` (greys of matching luma
/// in Monochrome), with Glasshouse's frosted plinth and display taken from the app's theme, as the original deck's
/// were. Equatable, so the layers drawn from it are drawn once and never per frame.
struct DeckPaint: Equatable {
    let design: DeckDesign
    let monochrome: Bool
    let dark: Bool
    /// The theme's glass and display tokens, for Glasshouse.
    let glassTop: Color
    let glassBottom: Color
    let glassEdge: Color
    let themeInk: Color
    let themeBack: Color

    init(design: DeckDesign, theme: Theme) {
        self.design = design
        monochrome = theme.isMonochrome
        dark = theme.isDark
        glassTop = theme.plinthTop
        glassBottom = theme.plinthBottom
        glassEdge = theme.plinthEdge
        themeInk = theme.lcdInk
        themeBack = theme.lcdBack
    }

    var isGlass: Bool { design.plinth == .frostedGlass }

    /// A design colour, 0xRRGGBB.
    func callAsFunction(_ hex: UInt32) -> Color {
        DeckColors(monochrome: monochrome, dark: dark)(hex)
    }

    var accent: Color { self(design.accent) }
    var base: Color { self(design.plinthBase) }
    var edge: Color { self(design.plinthEdge) }

    /// The dot-matrix display: the design's ink and window, or, on Glasshouse, the theme's, exactly as before.
    var displayInk: Color { isGlass ? themeInk : self(design.display.ink) }
    var displayBack: Color { isGlass ? themeBack : self(design.display.back) }

    /// The plinth's corner radius at a width: crisp on a wooden box, soft on the suitcase.
    func cornerRadius(width w: CGFloat) -> CGFloat {
        switch design.plinth {
        case .frostedGlass: 26
        case .brushedMetal, .matteBlack: w * 0.036
        case .walnut: w * 0.022
        case .lacquer: w * 0.03
        case .smokedAcrylic: w * 0.028
        case .leatherette: w * 0.06
        }
    }

    /// The arm's metal as three tones (highlight, body, shade) for a cylinder lit from the top left. Glasshouse's
    /// chrome darkens with the dark look, as the original arm did.
    var armMetal: Metal {
        switch design.armFinish {
        case .chrome:
            isGlass && dark
                ? Metal(light: self(0xD9DBDF), body: self(0x8A9097), shade: self(0x4B5057))
                : Metal(light: self(0xF7F8FA), body: self(0xA6ACB4), shade: self(0x5E646C))
        case .black: Metal(light: self(0x55585F), body: self(0x232428), shade: self(0x0B0B0D))
        case .silver: Metal(light: self(0xEDEFF2), body: self(0xB4B9C0), shade: self(0x767B83))
        case .brass: Metal(light: self(0xF6E2A8), body: self(0xC39A45), shade: self(0x7A5A1E))
        }
    }

    /// Small bright hardware (screws, the spindle, the clamp): brass on the walnut box and the suitcase, champagne on
    /// the acrylic deck, steel elsewhere.
    var hardware: Metal {
        switch design.plinth {
        case .walnut, .leatherette: Metal(light: self(0xF6E2A8), body: self(0xC9A24B), shade: self(0x7A5A1E))
        case .smokedAcrylic: Metal(light: self(0xF4ECD6), body: self(0xD9C9A3), shade: self(0x8C7B55))
        default: Metal(light: self(0xFFFFFF), body: self(0xB9BEC5), shade: self(0x6B7078))
        }
    }

    struct Metal: Equatable {
        let light: Color
        let body: Color
        let shade: Color

        /// Bands across a cylinder lit from the top left: a bright line near the lit edge, the body, a dark core
        /// line and a soft bounce on the far edge.
        var cylinder: Gradient {
            Gradient(stops: [
                .init(color: shade, location: 0), .init(color: light, location: 0.22),
                .init(color: body, location: 0.5), .init(color: shade, location: 0.8),
                .init(color: body, location: 1),
            ])
        }

        /// A domed cap seen from above, its highlight to the top left.
        func dome(center: CGPoint, radius: CGFloat) -> GraphicsContext.Shading {
            .radialGradient(
                Gradient(colors: [light, body, shade]),
                center: CGPoint(x: center.x - radius * 0.35, y: center.y - radius * 0.4),
                startRadius: 0, endRadius: radius * 1.35)
        }
    }
}

/// A deterministic random source (SplitMix64), so a texture is the same every time it is drawn.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    init(_ text: String) {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        self.init(seed: hash)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
}

/// Fine grain for matte surfaces, tiled: speckles of light and dark at low opacity. Made once, as a small image, so a
/// plinth's grain costs one tiled fill instead of thousands of dots.
enum DeckGrain {
    /// Light and dark speckles on clear, 128 pt square.
    static let speckle: Image = make(seed: 7, size: 128, density: 0.5, alpha: 0.5, blob: 1)
    /// Coarser pebbling, for leatherette.
    static let pebble: Image = make(seed: 11, size: 128, density: 0.32, alpha: 0.55, blob: 2)

    private static func make(seed: UInt64, size: Int, density: Double, alpha: Double, blob: Int) -> Image {
        var random = SeededRandom(seed: seed)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in stride(from: 0, to: size, by: blob) {
            for x in stride(from: 0, to: size, by: blob) where random.unit() < density {
                let a = UInt8(random.unit() * alpha * 255)
                let light = random.unit() < 0.5
                for dy in 0..<blob {
                    for dx in 0..<blob {
                        let i = ((y + dy) % size * size + (x + dx) % size) * 4
                        // Premultiplied: white speckles carry their alpha in the colour channels too.
                        let v = light ? a : 0
                        pixels[i] = v
                        pixels[i + 1] = v
                        pixels[i + 2] = v
                        pixels[i + 3] = a
                    }
                }
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: space, bitmapInfo: info)?
                .makeImage()
        }
        guard let image else { return Image(systemName: "circle") }
        return Image(decorative: image, scale: 2)
    }
}

extension GraphicsContext {
    /// Tiles a grain image over `rect` at `opacity`.
    func grain(_ image: Image, in rect: CGRect, opacity: Double) {
        var copy = self
        copy.opacity = opacity
        copy.fill(
            Path(rect), with: .tiledImage(image, origin: .zero, sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    /// A knurled knob seen from above: a soft drop shadow, a domed cap lit from the top left, fine teeth round the
    /// edge and, if given, a pointer line.
    func knob(
        center c: CGPoint, radius r: CGFloat, metal: DeckPaint.Metal, pointer: Color?, pointing angle: Double = -90
    ) {
        var shadow = self
        shadow.addFilter(.blur(radius: r * 0.25))
        shadow.fill(
            Path(ellipseIn: CGRect(x: c.x - r + r * 0.12, y: c.y - r + r * 0.22, width: r * 2, height: r * 2)),
            with: .color(.black.opacity(0.45)))
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        fill(disc, with: metal.dome(center: c, radius: r))
        let teeth = max(24, Int(r * 5))
        var knurl = Path()
        for i in 0..<teeth {
            let a = Double(i) / Double(teeth) * 2 * .pi
            knurl.move(to: CGPoint(x: c.x + cos(a) * r * 0.8, y: c.y + sin(a) * r * 0.8))
            knurl.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.98, y: c.y + sin(a) * r * 0.98))
        }
        stroke(knurl, with: .color(.black.opacity(0.22)), lineWidth: max(0.35, r * 0.06))
        // The flat top, a shade brighter than the knurled skirt.
        let top = Path(ellipseIn: CGRect(x: c.x - r * 0.72, y: c.y - r * 0.72, width: r * 1.44, height: r * 1.44))
        fill(top, with: metal.dome(center: c, radius: r * 0.8))
        stroke(top, with: .color(.white.opacity(0.25)), lineWidth: 0.4)
        if let pointer {
            let a = angle * .pi / 180
            var line = Path()
            line.move(to: CGPoint(x: c.x + cos(a) * r * 0.2, y: c.y + sin(a) * r * 0.2))
            line.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.66, y: c.y + sin(a) * r * 0.66))
            stroke(line, with: .color(pointer), style: StrokeStyle(lineWidth: max(0.8, r * 0.14), lineCap: .round))
        }
    }

    /// A screw head: a domed slot-head in `metal`, with its slot at `angle`.
    func screw(center c: CGPoint, radius r: CGFloat, metal: DeckPaint.Metal, angle: Double) {
        fill(
            Path(ellipseIn: CGRect(x: c.x - r + 0.4, y: c.y - r + 0.7, width: r * 2, height: r * 2)),
            with: .color(.black.opacity(0.4)))
        fill(
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
            with: metal.dome(center: c, radius: r))
        let a = angle * .pi / 180
        var slot = Path()
        slot.move(to: CGPoint(x: c.x - cos(a) * r * 0.62, y: c.y - sin(a) * r * 0.62))
        slot.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.62, y: c.y + sin(a) * r * 0.62))
        stroke(slot, with: .color(.black.opacity(0.55)), lineWidth: max(0.5, r * 0.28))
    }

    /// Small engraved type: dark on light finishes, light on dark ones.
    func engrave(_ text: String, at point: CGPoint, size: CGFloat, color: Color, anchor: UnitPoint = .center) {
        let resolved = resolve(
            Text(text).font(.system(size: size, weight: .semibold, design: .default)).tracking(size * 0.12)
                .foregroundStyle(color))
        draw(resolved, at: point, anchor: anchor)
    }
}
