import PFDesign
import SwiftUI

/// The fixed furniture round the platter for each controls layout: buttons, the pitch fader, lamps, knobs, the motor
/// pod, latches and grille. All of it sits clear of the arm's sweep and the display, and is decorative (hidden from
/// VoiceOver), except the DJ layout's start/stop button (`DeckStartStop`). Drawn once per design and size.
struct DeckControls: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout

    var body: some View {
        Canvas { context, _ in
            draw(&context)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var r: CGFloat { layout.recordRadius }
    private var ink: Color { ArmFurniture.markInk(paint) }

    private func draw(_ context: inout GraphicsContext) {
        switch paint.design.controls {
        case .glass: glass(&context)
        case .dj: dj(&context)
        case .minimal: minimal(&context)
        case .bauhaus: bauhaus(&context)
        case .acrylic: acrylic(&context)
        case .linear: linear(&context)
        case .portable: portable(&context)
        }
    }

    // MARK: Layouts

    private func glass(_ context: inout GraphicsContext) {
        // Two frosted speed keys, flush with the glass, their labels etched.
        let f = layout.frontControls
        for (i, label) in ["33", "45"].enumerated() {
            let key = CGRect(x: f.minX + 6 + CGFloat(i) * 38, y: f.midY - 9, width: 30, height: 18)
            Self.key(
                &context, key, fill: .white.opacity(paint.dark ? 0.08 : 0.35), edge: .white.opacity(0.55), corner: 9)
            context.engrave(label, at: CGPoint(x: key.midX, y: key.midY), size: 7.5, color: ink.opacity(0.55))
        }
    }

    private func dj(_ context: inout GraphicsContext) {
        let f = layout.frontControls
        let night = paint.design.plinth == .matteBlack
        let keyFill = paint(night ? 0x26282C : 0x3A3D42)
        // The start/stop key itself is a live button (`DeckStartStop`); its label is engraved here.
        let start = DeckStartStop.frame(layout)
        context.engrave("START · STOP", at: CGPoint(x: start.midX, y: start.maxY + 6), size: 5, color: ink.opacity(0.6))
        // Speed keys, 33 lit as the selected speed.
        for (i, label) in ["33", "45"].enumerated() {
            let key = CGRect(x: start.maxX + 10 + CGFloat(i) * 27, y: start.minY + 9, width: 22, height: 13)
            Self.key(&context, key, fill: keyFill, edge: .white.opacity(0.22), corner: 2.5)
            let led = CGRect(x: key.midX - 3, y: key.minY + 2, width: 6, height: 1.6)
            if i == 0 {
                Self.glow(&context, led, paint.accent)
            } else {
                context.fill(Path(roundedRect: led, cornerRadius: 0.8), with: .color(.black.opacity(0.5)))
            }
            context.engrave(label, at: CGPoint(x: key.midX, y: key.maxY + 6), size: 5, color: ink.opacity(0.6))
        }
        // The strobe lamp, at the platter's front left, shining on the rim's dots.
        let lampAngle = 135.0 * .pi / 180
        let lampDistance = layout.platterRadius + r * 0.1
        let lamp = CGPoint(
            x: layout.recordCenter.x + cos(lampAngle) * lampDistance,
            y: layout.recordCenter.y + sin(lampAngle) * lampDistance)
        Self.lamp(
            &context, at: lamp, radius: r * 0.05, colour: paint(paint.design.strobe ?? paint.design.accent), dim: night)
        // The pop-up target light, rear left.
        Self.lamp(
            &context, at: CGPoint(x: layout.size.width * 0.07, y: layout.size.width * 0.07), radius: r * 0.045,
            colour: paint(0xFFF2C8), dim: night)
        pitchFader(&context)
    }

    /// The pitch fader on the right, below the arm's pivot and right of its rest: a long slot with ±8 % marks, a
    /// centre click in the accent and the fader cap at zero.
    private func pitchFader(_ context: inout GraphicsContext) {
        guard let arm = layout.pivoted else { return }
        let night = paint.design.plinth == .matteBlack
        let x = layout.size.width - layout.size.width * 0.052
        let top = arm.pivot.y + r * 0.62
        let bottom = layout.frontBand.minY - r * 0.06
        let slot = CGRect(x: x - 2.5, y: top, width: 5, height: bottom - top)
        context.fill(
            Path(roundedRect: slot.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(.black.opacity(0.18)))
        context.fill(Path(roundedRect: slot, cornerRadius: 2.5), with: .color(.black.opacity(0.75)))
        context.stroke(
            Path(roundedRect: slot.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0.4), .white.opacity(0.35)]),
                startPoint: CGPoint(x: slot.minX, y: slot.minY),
                endPoint: CGPoint(x: slot.maxX, y: slot.maxY)), lineWidth: 0.6)
        let steps = 16
        for i in 0...steps {
            let y = slot.minY + 4 + (slot.height - 8) * CGFloat(i) / CGFloat(steps)
            let centre = i == steps / 2
            let long = i % 4 == 0
            let tick = CGRect(x: slot.maxX + 3, y: y - 0.35, width: centre ? 6 : (long ? 4.5 : 2.8), height: 0.7)
            if night {
                // The late-night deck's ticks glow faintly in its amber.
                var bloom = context
                bloom.addFilter(.blur(radius: 1.2))
                bloom.fill(
                    Path(tick.insetBy(dx: -0.5, dy: -0.6)), with: .color(paint.accent.opacity(centre ? 0.9 : 0.45)))
                context.fill(Path(tick), with: .color(paint.accent.opacity(centre ? 1 : 0.7)))
            } else {
                context.fill(Path(tick), with: .color(centre ? paint.accent : ink.opacity(0.5)))
            }
        }
        context.engrave("+", at: CGPoint(x: slot.minX - 5, y: slot.maxY - 3), size: 6, color: ink.opacity(0.5))
        context.engrave("−", at: CGPoint(x: slot.minX - 5, y: slot.minY + 3), size: 6, color: ink.opacity(0.5))
        // The cap at zero, with its index line.
        let cap = CGRect(x: x - 8.5, y: slot.midY - 5.5, width: 17, height: 11)
        var shadow = context
        shadow.addFilter(.blur(radius: 1.5))
        shadow.fill(Path(roundedRect: cap.offsetBy(dx: 1, dy: 2), cornerRadius: 2), with: .color(.black.opacity(0.5)))
        context.fill(
            Path(roundedRect: cap, cornerRadius: 2),
            with: .linearGradient(
                Gradient(colors: [paint(0x4A4D53), paint(0x1E1F22)]), startPoint: CGPoint(x: 0, y: cap.minY),
                endPoint: CGPoint(x: 0, y: cap.maxY)))
        var grip = Path()
        for dy in [-2.6, 2.6] {
            grip.move(to: CGPoint(x: cap.minX + 2.5, y: cap.midY + dy))
            grip.addLine(to: CGPoint(x: cap.maxX - 2.5, y: cap.midY + dy))
        }
        context.stroke(grip, with: .color(.black.opacity(0.45)), lineWidth: 0.6)
        context.fill(
            Path(CGRect(x: cap.minX + 1.5, y: cap.midY - 0.45, width: cap.width - 3, height: 0.9)),
            with: .color(paint.accent))
    }

    private func minimal(_ context: inout GraphicsContext) {
        // One speed switch in a slot, its brass toggle at 33, the speeds engraved beside it.
        let f = layout.frontControls
        let slot = CGRect(x: f.minX + 6, y: f.midY - 6, width: 40, height: 12)
        context.fill(Path(roundedRect: slot, cornerRadius: 6), with: .color(.black.opacity(0.45)))
        context.stroke(
            Path(roundedRect: slot, cornerRadius: 6),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0.5), .white.opacity(0.2)]), startPoint: CGPoint(x: 0, y: slot.minY),
                endPoint: CGPoint(x: 0, y: slot.maxY)), lineWidth: 0.6)
        let toggle = CGPoint(x: slot.minX + 7, y: slot.midY)
        context.fill(
            Path(ellipseIn: CGRect(x: toggle.x - 5.5, y: toggle.y - 5.5, width: 11, height: 11)),
            with: paint.hardware.dome(center: toggle, radius: 5.5))
        context.engrave(
            "33", at: CGPoint(x: slot.minX + 7, y: slot.maxY + 7), size: 5.5, color: paint(0xF2DFC4).opacity(0.7))
        context.engrave(
            "45", at: CGPoint(x: slot.maxX - 7, y: slot.maxY + 7), size: 5.5, color: paint(0xF2DFC4).opacity(0.7))
    }

    private func bauhaus(_ context: inout GraphicsContext) {
        // A row of five small knobs on a fine engraved rule, the middle one with its pointer, and one orange dot.
        let f = layout.frontControls
        let knob = r * 0.052
        let y = f.midY - 2
        let rule = CGRect(x: f.minX + 8, y: y + knob + 5, width: knob * 2 * 5 + 4 * 11, height: 0.6)
        context.fill(Path(rule), with: .color(.black.opacity(0.25)))
        let metal = DeckPaint.Metal(light: paint(0xFFFFFF), body: paint(0xD9D6CC), shade: paint(0x9C988C))
        for i in 0..<5 {
            let c = CGPoint(x: f.minX + 8 + knob + CGFloat(i) * (knob * 2 + 11), y: y)
            context.knob(center: c, radius: knob, metal: metal, pointer: i == 2 ? paint(0x555555) : nil, pointing: -60)
        }
        let dot = CGPoint(x: rule.maxX + 14, y: y)
        context.fill(
            Path(ellipseIn: CGRect(x: dot.x - 3.4, y: dot.y - 3.4, width: 6.8, height: 6.8)), with: .color(paint.accent)
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: dot.x - 3.4, y: dot.y - 3.4, width: 6.8, height: 6.8)),
            with: .color(.black.opacity(0.2)), lineWidth: 0.5)
        // The lid's two hinges on the rear edge.
        for x in [layout.size.width * 0.22, layout.size.width * 0.56] {
            let hinge = CGRect(x: x, y: 2.5, width: r * 0.2, height: 5)
            context.fill(
                Path(roundedRect: hinge, cornerRadius: 2.5),
                with: .linearGradient(
                    Gradient(colors: [paint(0xFFFFFF), paint(0xA9ADB3), paint(0x6F737A)]),
                    startPoint: CGPoint(x: 0, y: hinge.minY),
                    endPoint: CGPoint(x: 0, y: hinge.maxY)))
        }
    }

    private func acrylic(_ context: inout GraphicsContext) {
        // The outboard motor pod, rear left, and its belt round the platter's rim.
        let w = layout.size.width
        let pod = CGPoint(x: w * 0.12, y: w * 0.12)
        let podRadius = r * 0.13
        let pulley = r * 0.045
        let hardware = paint.hardware
        var shadow = context
        shadow.addFilter(.blur(radius: 4))
        shadow.fill(
            Path(
                ellipseIn: CGRect(
                    x: pod.x - podRadius + 3, y: pod.y - podRadius + 5, width: podRadius * 2, height: podRadius * 2)),
            with: .color(.black.opacity(0.6)))
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: pod.x - podRadius, y: pod.y - podRadius, width: podRadius * 2, height: podRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [paint(0x1C1C22), paint(0x07070A)]), center: pod, startRadius: 0, endRadius: podRadius)
        )
        context.stroke(
            Path(
                ellipseIn: CGRect(
                    x: pod.x - podRadius, y: pod.y - podRadius, width: podRadius * 2, height: podRadius * 2)),
            with: .linearGradient(
                Gradient(colors: [hardware.light.opacity(0.7), hardware.shade.opacity(0.2)]),
                startPoint: CGPoint(x: pod.x - podRadius, y: pod.y - podRadius),
                endPoint: CGPoint(x: pod.x + podRadius, y: pod.y + podRadius)), lineWidth: 1)
        // The belt: the two runs tangent to the pulley and the platter, and the loop round the rim.
        let c = layout.recordCenter
        let big = layout.platterRadius + 0.6
        let dx = c.x - pod.x
        let dy = c.y - pod.y
        let d = hypot(dx, dy)
        let base = atan2(dy, dx)
        // The outer tangents: each run leaves both wheels at the same angle, `spread` either side of the line
        // between their centres.
        let spread = acos((pulley - big) / d)
        var belt = Path()
        for side in [-1.0, 1.0] {
            let a = base + side * spread
            let onPulley = CGPoint(x: pod.x + cos(a) * pulley, y: pod.y + sin(a) * pulley)
            let onPlatter = CGPoint(x: c.x + cos(a) * big, y: c.y + sin(a) * big)
            belt.move(to: onPulley)
            belt.addLine(to: onPlatter)
        }
        belt.addEllipse(in: CGRect(x: c.x - big, y: c.y - big, width: big * 2, height: big * 2))
        context.stroke(belt, with: .color(.black.opacity(0.85)), lineWidth: 1.1)
        context.fill(
            Path(ellipseIn: CGRect(x: pod.x - pulley, y: pod.y - pulley, width: pulley * 2, height: pulley * 2)),
            with: hardware.dome(center: pod, radius: pulley))
        // Champagne bolts through the slabs' four corners, square to one another, clear of the pod, the arm's
        // counterweight and the display.
        let h = layout.size.height
        let inset: CGFloat = 9
        for (point, angle) in [
            (CGPoint(x: inset, y: inset), 20.0), (CGPoint(x: w - inset, y: inset), 70.0),
            (CGPoint(x: inset, y: h - inset), 110.0), (CGPoint(x: w - inset, y: h - inset), 160.0),
        ] {
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11)),
                with: .color(.black.opacity(0.35)))
            context.screw(center: point, radius: 4, metal: hardware, angle: angle)
        }
    }

    private func linear(_ context: inout GraphicsContext) {
        // Flush touch keys along the front, under a thin strip of glass; the playing key lights (`DeckLamps`).
        let f = layout.frontControls
        let strip = CGRect(x: f.minX, y: f.midY - 7, width: min(f.width, 4 * 26 + 3 * 6 + 12), height: 14)
        context.fill(Path(roundedRect: strip, cornerRadius: 3), with: .color(.black.opacity(0.72)))
        context.stroke(
            Path(roundedRect: strip, cornerRadius: 3),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0.5), .white.opacity(0.45)]), startPoint: CGPoint(x: 0, y: strip.minY),
                endPoint: CGPoint(x: 0, y: strip.maxY)), lineWidth: 0.6)
        for i in 0..<4 {
            let key = Self.linearKey(layout, i)
            context.fill(Path(roundedRect: key, cornerRadius: 1.5), with: .color(paint(0x25272B)))
            context.stroke(Path(roundedRect: key, cornerRadius: 1.5), with: .color(.white.opacity(0.1)), lineWidth: 0.4)
        }
    }

    static func linearKey(_ layout: DeckLayout, _ i: Int) -> CGRect {
        let f = layout.frontControls
        return CGRect(x: f.minX + 6 + CGFloat(i) * 32, y: f.midY - 3.5, width: 26, height: 7)
    }

    private func portable(_ context: inout GraphicsContext) {
        // The speaker grille, front left: a perforated plate over dark cloth.
        let f = layout.frontControls
        // Its bottom stops short of the stitched seam round the case (9 pt in from the edge).
        let seam = layout.size.height - 9
        let grille = CGRect(x: f.minX + 2, y: f.minY + 2, width: f.width * 0.74, height: seam - 6 - (f.minY + 2))
        context.fill(Path(roundedRect: grille, cornerRadius: 5), with: .color(paint(0x3A2E27)))
        var holes = Path()
        var y = grille.minY + 3
        var row = 0
        while y < grille.maxY - 2 {
            var x = grille.minX + 3 + (row % 2 == 0 ? 0 : 1.6)
            while x < grille.maxX - 2 {
                holes.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                x += 3.2
            }
            y += 2.8
            row += 1
        }
        context.fill(holes, with: .color(.black.opacity(0.55)))
        context.stroke(
            Path(roundedRect: grille, cornerRadius: 5),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0.45), .white.opacity(0.2)]),
                startPoint: CGPoint(x: 0, y: grille.minY),
                endPoint: CGPoint(x: 0, y: grille.maxY)), lineWidth: 0.8)
        // Brass latches on the front edge, set squarely over the seam.
        let hardware = paint.hardware
        for x in [layout.size.width * 0.12, f.maxX - 24] {
            let latch = CGRect(x: x, y: seam - 3.25, width: 24, height: 6.5)
            context.fill(
                Path(roundedRect: latch.offsetBy(dx: 0.6, dy: 1), cornerRadius: 1.5), with: .color(.black.opacity(0.4)))
            context.fill(
                Path(roundedRect: latch, cornerRadius: 1.5),
                with: .linearGradient(
                    Gradient(colors: [hardware.light, hardware.body, hardware.shade]),
                    startPoint: CGPoint(x: 0, y: latch.minY),
                    endPoint: CGPoint(x: 0, y: latch.maxY)))
            context.screw(center: CGPoint(x: latch.midX, y: latch.midY), radius: 1.6, metal: hardware, angle: 0)
        }
        // The speed and volume knob, rear left, cream with a pointer.
        let knob = CGPoint(x: layout.size.width * 0.085, y: layout.size.width * 0.085)
        let cream = DeckPaint.Metal(light: paint(0xFFFBF0), body: paint(0xE8DFC8), shade: paint(0xA99D80))
        context.knob(center: knob, radius: r * 0.068, metal: cream, pointer: paint(0x444444), pointing: -120)
    }

    // MARK: Pieces

    static func key(_ context: inout GraphicsContext, _ rect: CGRect, fill: Color, edge: Color, corner: CGFloat) {
        var shadow = context
        shadow.addFilter(.blur(radius: 1.2))
        shadow.fill(
            Path(roundedRect: rect.offsetBy(dx: 0.6, dy: 1.4), cornerRadius: corner), with: .color(.black.opacity(0.4)))
        context.fill(Path(roundedRect: rect, cornerRadius: corner), with: .color(fill))
        context.fill(
            Path(roundedRect: rect, cornerRadius: corner),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.18)]),
                startPoint: CGPoint(x: 0, y: rect.minY),
                endPoint: CGPoint(x: 0, y: rect.maxY)))
        context.stroke(
            Path(roundedRect: rect.insetBy(dx: 0.3, dy: 0.3), cornerRadius: corner), with: .color(edge), lineWidth: 0.5)
    }

    /// A lit LED with a little bloom.
    static func glow(_ context: inout GraphicsContext, _ rect: CGRect, _ colour: Color) {
        var bloom = context
        bloom.addFilter(.blur(radius: 2.5))
        bloom.fill(
            Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: rect.height),
            with: .color(colour.opacity(0.9)))
        context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(colour))
    }

    /// A round lamp in a dark bezel, lit, with its bloom; `dim` for the late-night deck.
    static func lamp(_ context: inout GraphicsContext, at c: CGPoint, radius: CGFloat, colour: Color, dim: Bool) {
        let bezel = Path(
            ellipseIn: CGRect(x: c.x - radius * 1.6, y: c.y - radius * 1.6, width: radius * 3.2, height: radius * 3.2))
        var shadow = context
        shadow.addFilter(.blur(radius: 1.5))
        shadow.fill(bezel.offsetBy(dx: 0.8, dy: 1.4), with: .color(.black.opacity(0.45)))
        context.fill(
            bezel,
            with: .radialGradient(
                Gradient(colors: [Color(white: 0.24), Color(white: 0.1)]), center: c, startRadius: 0,
                endRadius: radius * 1.6))
        context.stroke(bezel, with: .color(.white.opacity(0.2)), lineWidth: 0.5)
        var bloom = context
        bloom.addFilter(.blur(radius: radius * 1.4))
        bloom.fill(
            Path(
                ellipseIn: CGRect(
                    x: c.x - radius * 1.3, y: c.y - radius * 1.3, width: radius * 2.6, height: radius * 2.6)),
            with: .color(colour.opacity(dim ? 0.45 : 0.75)))
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [.white, colour, colour.opacity(0.85)]),
                center: CGPoint(x: c.x - radius * 0.3, y: c.y - radius * 0.3),
                startRadius: 0, endRadius: radius * 1.2))
    }
}

/// The lamps that follow the music: the start/stop key's lamp on the DJ decks, the walnut box's power lamp, the
/// glass deck's speed light and the linear deck's playing key. Redrawn only when play starts or stops.
struct DeckLamps: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout
    let playing: Bool

    var body: some View {
        Canvas { context, _ in
            let f = layout.frontControls
            switch paint.design.controls {
            case .glass:
                let dot = CGRect(x: f.minX + 6 + 15 - 2, y: f.midY + 4, width: 4, height: 1.8)
                if playing { DeckControls.glow(&context, dot, paint.accent) }
            case .minimal:
                let lamp = CGRect(x: f.minX + 56, y: f.midY - 1.5, width: 3, height: 3)
                if playing {
                    DeckControls.glow(&context, lamp, paint.accent)
                } else {
                    context.fill(Path(ellipseIn: lamp), with: .color(.black.opacity(0.4)))
                }
            case .linear:
                let key = DeckControls.linearKey(layout, 1)
                if playing { DeckControls.glow(&context, key.insetBy(dx: 2, dy: 2.5), paint.accent) }
            case .bauhaus, .acrylic, .portable, .dj:
                break
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The DJ layout's start/stop key: the one working control on the plinth. It plays and pauses, and its lamp lights
/// while the record plays. With no record on the deck it does nothing, as the shared play button does.
struct DeckStartStop: View {
    let paint: DeckPaint
    let layout: DeckLayout
    let playing: Bool
    let enabled: Bool
    let toggle: () -> Void
    @State private var presses = 0

    static func frame(_ layout: DeckLayout) -> CGRect {
        let f = layout.frontControls
        return CGRect(x: f.minX + 2, y: f.minY + 2, width: 44, height: 28)
    }

    var body: some View {
        let frame = Self.frame(layout)
        Button {
            presses += 1
            toggle()
        } label: {
            Color.clear
        }
        .buttonStyle(Key(paint: paint, playing: playing))
        .disabled(!enabled)
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle().inset(by: -8))
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel("Start/Stop")
        .accessibilityValue(playing ? "Playing" : "Stopped")
        .accessibilityIdentifier("deckStartStop")
        .sensoryFeedback(.impact(weight: .medium), trigger: presses)
    }

    private struct Key: ButtonStyle {
        let paint: DeckPaint
        let playing: Bool

        func makeBody(configuration: Configuration) -> some View {
            StartStopKey(paint: paint, playing: playing, pressed: configuration.isPressed)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// The start/stop key's face: a dark square key with its lamp, lit while the record plays.
struct StartStopKey: View {
    let paint: DeckPaint
    let playing: Bool
    var pressed = false

    var body: some View {
        let night = paint.design.plinth == .matteBlack
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(paint(night ? 0x26282C : 0x3A3D42))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(
                        LinearGradient(
                            colors: [.white.opacity(pressed ? 0.04 : 0.16), .clear, .black.opacity(0.22)],
                            startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(
                        .white.opacity(0.2), lineWidth: 0.5)
                )
            Capsule()
                .fill(playing ? paint.accent : Color.black.opacity(0.5))
                .frame(width: 10, height: 1.8)
                .shadow(color: playing ? paint.accent : .clear, radius: 2.5)
                .padding(.top, 3)
        }
        .shadow(
            color: .black.opacity(pressed ? 0.25 : 0.45), radius: pressed ? 0.5 : 1.5, x: 0.5, y: pressed ? 0.5 : 1.5
        )
        .offset(y: pressed ? 0.8 : 0)
    }
}

/// The spindle, over the record, and the heavy clamp on the acrylic deck: domed metal whose highlight stays to the
/// lamp while the record turns under it.
struct DeckSpindle: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout

    var body: some View {
        let r = layout.recordRadius
        let clamp = paint.design.controls == .acrylic ? r * 0.16 : 0
        let side = max(clamp, r * 0.05) * 2 + 12
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            if clamp > 0 {
                context.knob(center: c, radius: clamp, metal: paint.hardware, pointer: nil)
                let well = clamp * 0.36
                context.fill(
                    Path(ellipseIn: CGRect(x: c.x - well, y: c.y - well, width: well * 2, height: well * 2)),
                    with: .color(.black.opacity(0.35)))
            }
            let spindle = r * VinylGeometry.spindleHoleToRecord * 0.94
            var shadow = context
            shadow.addFilter(.blur(radius: 1))
            shadow.fill(
                Path(
                    ellipseIn: CGRect(
                        x: c.x - spindle + 0.6, y: c.y - spindle + 1, width: spindle * 2, height: spindle * 2)),
                with: .color(.black.opacity(0.6)))
            let metal =
                paint.design.plinth == .walnut
                ? paint.hardware
                : DeckPaint.Metal(light: paint(0xFFFFFF), body: paint(0xB8BDC4), shade: paint(0x5E636A))
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - spindle, y: c.y - spindle, width: spindle * 2, height: spindle * 2)),
                with: metal.dome(center: c, radius: spindle))
        }
        .frame(width: side, height: side)
        .drawingGroup()
        .position(layout.recordCenter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The radiogram's clear lid, catching the light over everything: two soft diagonal reflections. Purely a sheen, it
/// takes no touches.
struct LidReflection: View, Equatable {
    let paint: DeckPaint
    let layout: DeckLayout

    var body: some View {
        let radius = paint.cornerRadius(width: layout.size.width)
        let lid = RoundedRectangle(cornerRadius: max(2, radius - 4), style: .continuous).inset(by: 4)
        ZStack {
            // The reflections lie across the record, where the dark vinyl shows them; on the white lacquer a clear
            // lid shows mostly as its edge.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.02), location: 0), .init(color: .white.opacity(0.02), location: 0.26),
                    .init(color: .white.opacity(0.2), location: 0.33),
                    .init(color: .white.opacity(0.08), location: 0.39),
                    .init(color: .white.opacity(0.02), location: 0.43),
                    .init(color: .white.opacity(0.02), location: 0.52),
                    .init(color: .white.opacity(0.1), location: 0.56),
                    .init(color: .white.opacity(0.02), location: 0.6),
                    .init(color: .white.opacity(0.02), location: 1),
                ], startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .clipShape(lid)
            // The lid's edge: a polished hairline with a faint shadow just inside it.
            lid.inset(by: 0.8).stroke(Color.black.opacity(0.08), lineWidth: 1)
            lid.stroke(
                LinearGradient(
                    colors: [.white.opacity(0.95), .white.opacity(0.35), .white.opacity(0.8)], startPoint: .topLeading,
                    endPoint: .bottomTrailing), lineWidth: 0.8)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
