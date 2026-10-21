import Observation
import PFDSP
import SwiftUI

/// What the EQ graph's curve and headroom are computed from: the bypassable stages with Pure off (so the graph can
/// show what Pure is bypassing), and the output's rate, which the filters are designed for.
struct CurveInput: Equatable, Sendable {
    var settings: SoundSettings
    var sampleRate: Double

    init(_ s: SoundSettings, sampleRate: Double) {
        var unbypassed = SoundSettings()
        unbypassed.pure = false
        unbypassed.preamp = s.preamp
        unbypassed.correction = s.correction
        unbypassed.eq = s.eq
        unbypassed.tone = s.tone
        settings = unbypassed
        self.sampleRate = sampleRate
    }
}

/// The graph's curve (`SoundResponse.curveDb`, 256 points) and the automatic headroom (`autoHeadroomDb`), computed
/// off the main actor: together they cost about 4 ms in Debug with twenty bands, a quarter of a frame. One computation
/// runs at a time; a request made meanwhile replaces any waiting one, so a drag never builds a backlog and the last
/// position always gets drawn.
@MainActor
@Observable
final class EQCurveModel {
    private(set) var curve: [(hz: Double, db: Double)] = []
    private(set) var headroomDb = 0.0
    @ObservationIgnored private var running = false
    @ObservationIgnored private var waiting: CurveInput?
    @ObservationIgnored private var last: CurveInput?

    func request(_ input: CurveInput) {
        guard input != last else { return }
        last = input
        if running {
            waiting = input
            return
        }
        start(input)
    }

    private func start(_ input: CurveInput) {
        running = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let curve = SoundResponse.curveDb(input.settings, sampleRate: input.sampleRate, points: 256)
            let headroom = SoundResponse.autoHeadroomDb(input.settings, sampleRate: input.sampleRate)
            await self?.finish(curve: curve, headroom: headroom)
        }
    }

    private func finish(curve: [(hz: Double, db: Double)], headroom: Double) {
        self.curve = curve
        headroomDb = headroom
        running = false
        if let next = waiting {
            waiting = nil
            start(next)
        }
    }
}

/// The frequency-response graph (spec §4.8): a log axis from 20 Hz to 20 kHz, ±24 dB, with the combined curve of the
/// EQ and tone. In Parametric mode each band has a handle: drag it sideways for frequency and up or down for gain, and
/// pinch anywhere on the graph for the selected band's Q (spread the fingers to widen it). A double tap on the graph
/// adds a band there. Drawn on the deck's screen.
struct EQGraphView: View {
    enum Look: Equatable {
        /// The EQ is on: the curve is what plays.
        case live
        /// The EQ is off: the curve is the other stages' alone.
        case eqOff
        /// Pure bypasses all of it.
        case bypassed
    }

    let eq: EQSettings
    let curve: [(hz: Double, db: Double)]
    /// The automatic headroom, or nil when it is switched off.
    let headroomDb: Double?
    let sampleRate: Double
    let look: Look
    @Binding var selection: Int?
    /// The screen's look (always dark).
    let theme: Theme
    let setBand: (Int, EQBand) -> Void
    let addBand: (EQBand) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var dragOrigin: EQBand?
    @State private var pinchOrigin: Double?

    static let dbRange = 24.0
    static let lowHz = 20.0
    static let highHz = 20_000.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                ScreenPanel(theme: theme, cornerRadius: 12)
                Canvas { context, canvasSize in
                    drawGrid(&context, canvasSize)
                    drawCurve(&context, canvasSize)
                    if eq.mode == .graphic { drawGraphicPoints(&context, canvasSize) }
                }
                .accessibilityElement()
                .accessibilityLabel("Frequency response")
                .accessibilityValue(curveSummary)
                captions
                if eq.mode == .parametric {
                    ForEach(Array(eq.bands.enumerated()), id: \.offset) { index, band in
                        handle(index, band, size)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(pinch)
            .onTapGesture(count: 2) { location in
                guard eq.mode == .parametric, isEnabled, eq.bands.count < SoundRanges.maxBands else { return }
                addBand(
                    EQBand(
                        type: .peak, frequency: SoundFormat.rounded(hz(atX: location.x, size.width)),
                        gainDb: SoundFormat.tenth(db(atY: location.y, size.height)), q: 1))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eqGraph")
    }

    // MARK: Mapping

    private func x(_ hz: Double, _ width: CGFloat) -> CGFloat {
        let f = log10(min(max(hz, Self.lowHz), Self.highHz) / Self.lowHz) / log10(Self.highHz / Self.lowHz)
        return CGFloat(f) * width
    }

    private func y(_ db: Double, _ height: CGFloat) -> CGFloat {
        CGFloat((Self.dbRange - min(max(db, -Self.dbRange), Self.dbRange)) / (2 * Self.dbRange)) * height
    }

    private func hz(atX x: CGFloat, _ width: CGFloat) -> Double {
        let f = min(max(Double(x / max(width, 1)), 0), 1)
        return Self.lowHz * pow(Self.highHz / Self.lowHz, f)
    }

    private func db(atY y: CGFloat, _ height: CGFloat) -> Double {
        let f = min(max(Double(y / max(height, 1)), 0), 1)
        return Self.dbRange - f * 2 * Self.dbRange
    }

    // MARK: Drawing

    private var ink: Color { theme.lcdInk }

    private var curveColour: Color {
        switch look {
        case .live: theme.altered
        case .eqOff: theme.altered.opacity(0.7)
        case .bypassed: theme.inkSecondary
        }
    }

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        // Log paper: faint lines at every 1–9 × decade, stronger ones at 100 Hz, 1 kHz and 10 kHz.
        for decade in [10.0, 100, 1000, 10_000] {
            for step in 1...9 {
                let hz = decade * Double(step)
                guard hz >= Self.lowHz, hz <= Self.highHz else { continue }
                let major = step == 1 && decade >= 100
                let px = x(hz, size.width)
                context.fill(
                    Path(CGRect(x: px - 0.25, y: 0, width: 0.5, height: size.height)),
                    with: .color(ink.opacity(major ? 0.24 : 0.07)))
            }
        }
        for db in stride(from: -18.0, through: 18, by: 6) {
            let strength = db == 0 ? 0.4 : abs(db) == 12 ? 0.2 : 0.07
            let py = y(db, size.height)
            context.fill(
                Path(CGRect(x: 0, y: py - 0.25, width: size.width, height: db == 0 ? 0.8 : 0.5)),
                with: .color(ink.opacity(strength)))
        }
        let label = { (text: String) in
            Text(text).font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundStyle(ink.opacity(0.5))
        }
        for (hz, text) in [(100.0, "100"), (1000, "1k"), (10_000, "10k")] {
            context.draw(label(text), at: CGPoint(x: x(hz, size.width) + 3, y: size.height - 4), anchor: .bottomLeading)
        }
        for db in [12.0, 0, -12] {
            let text = db == 0 ? "0" : SoundFormat.signed(db, decimals: 0)
            context.draw(label(text), at: CGPoint(x: 5, y: y(db, size.height) - 2), anchor: .bottomLeading)
        }
    }

    private func drawCurve(_ context: inout GraphicsContext, _ size: CGSize) {
        let points = curve.map { CGPoint(x: x($0.hz, size.width), y: y($0.db, size.height)) }
        guard let first = points.first, let lastPoint = points.last else {
            // No curve yet: the flat line.
            var flat = Path()
            flat.move(to: CGPoint(x: 0, y: size.height / 2))
            flat.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(flat, with: .color(curveColour), lineWidth: 1.5)
            return
        }
        var line = Path()
        line.move(to: first)
        for p in points.dropFirst() { line.addLine(to: p) }
        let zero = y(0, size.height)
        var fill = line
        fill.addLine(to: CGPoint(x: lastPoint.x, y: zero))
        fill.addLine(to: CGPoint(x: first.x, y: zero))
        fill.closeSubpath()
        context.fill(fill, with: .color(curveColour.opacity(look == .bypassed ? 0.06 : 0.16)))
        if look == .bypassed {
            context.stroke(line, with: .color(curveColour), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        } else {
            // A soft glow under the line, as the deck's screen glows.
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 4))
                glow.stroke(line, with: .color(curveColour.opacity(0.8)), lineWidth: 3)
            }
            context.stroke(line, with: .color(curveColour), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }

    /// The ten graphic sliders' settings, as small rings at their centres.
    private func drawGraphicPoints(_ context: inout GraphicsContext, _ size: CGSize) {
        for (index, hz) in SoundRanges.graphicCentres.enumerated() {
            let gain = index < eq.graphicGainsDb.count ? eq.graphicGainsDb[index] : 0
            let c = CGPoint(x: x(hz, size.width), y: y(gain, size.height))
            let ring = Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7))
            context.fill(ring, with: .color(theme.lcdBack))
            context.stroke(ring, with: .color(gain == 0 ? ink.opacity(0.45) : curveColour), lineWidth: 1.4)
        }
    }

    private var captions: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(modeCaption) · \(SoundFormat.trimmed(sampleRate / 1000)) kHz")
                Spacer(minLength: 8)
                Text(headroomCaption)
                    .accessibilityIdentifier("headroomCaption")
            }
            Spacer()
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .tracking(0.8)
        .foregroundStyle(ink.opacity(0.62))
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .allowsHitTesting(false)
    }

    private var modeCaption: String {
        switch look {
        case .bypassed: "BYPASSED · PURE"
        case .eqOff: "EQ OFF"
        case .live: eq.mode == .graphic ? "GRAPHIC" : "PARAMETRIC"
        }
    }

    private var headroomCaption: String {
        guard let headroomDb else { return "AUTO HEADROOM OFF" }
        return "HEADROOM \(SoundFormat.gain(headroomDb))"
    }

    private var curveSummary: String {
        guard let high = curve.max(by: { $0.db < $1.db }), let low = curve.min(by: { $0.db < $1.db }) else {
            return "Flat"
        }
        if high.db < 0.05, low.db > -0.05 { return "Flat" }
        return "Highest \(SoundFormat.gainSpoken(high.db)) at \(SoundFormat.frequencySpoken(high.hz)), "
            + "lowest \(SoundFormat.gainSpoken(low.db)) at \(SoundFormat.frequencySpoken(low.hz))"
    }

    // MARK: Handles

    private func handle(_ index: Int, _ band: EQBand, _ size: CGSize) -> some View {
        let selected = selection == index
        let centre = CGPoint(
            x: x(band.frequency, size.width), y: y(band.type.usesGain ? band.gainDb : 0, size.height))
        let fill: Color = selected ? curveColour : theme.lcdBack
        return ZStack {
            Circle()
                .fill(fill)
                .frame(width: selected ? 24 : 20, height: selected ? 24 : 20)
                .overlay(
                    Circle().strokeBorder(
                        band.enabled ? (selected ? theme.ink : curveColour) : ink.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.6, dash: band.enabled ? [] : [2.5, 2]))
                )
                .shadow(color: curveColour.opacity(selected ? 0.7 : 0), radius: 6)
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(selected ? theme.lcdBack : theme.ink)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .gesture(drag(index, band, size))
        .opacity(look == .bypassed ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Band \(index + 1), \(band.type.title)\(band.enabled ? "" : ", off")")
        .accessibilityValue(spoken(band))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let up = direction == .increment
            var b = band
            if band.type.usesGain {
                b.gainDb = clampGain(band.gainDb + (up ? 0.5 : -0.5))
            } else {
                b.frequency = clampHz(band.frequency * pow(2, up ? 1.0 / 6 : -1.0 / 6))
            }
            selection = index
            setBand(index, b)
        }
        .accessibilityAction(named: "Raise frequency") {
            nudge(index, band) { $0.frequency = clampHz($0.frequency * pow(2, 1.0 / 6)) }
        }
        .accessibilityAction(named: "Lower frequency") {
            nudge(index, band) { $0.frequency = clampHz($0.frequency / pow(2, 1.0 / 6)) }
        }
        .accessibilityAction(named: "Narrower") { nudge(index, band) { $0.q = clampQ($0.q * pow(2, 0.25)) } }
        .accessibilityAction(named: "Wider") { nudge(index, band) { $0.q = clampQ($0.q / pow(2, 0.25)) } }
        .accessibilityIdentifier("eqHandle-\(index)")
        .position(centre)
        .zIndex(selected ? 1 : 0)
    }

    private func spoken(_ band: EQBand) -> String {
        var parts = [SoundFormat.frequencySpoken(band.frequency)]
        if band.type.usesGain { parts.append(SoundFormat.gainSpoken(band.gainDb)) }
        parts.append(SoundFormat.qSpoken(band.q))
        return parts.joined(separator: ", ")
    }

    private func nudge(_ index: Int, _ band: EQBand, _ change: (inout EQBand) -> Void) {
        guard isEnabled else { return }
        var b = band
        change(&b)
        selection = index
        setBand(index, b)
    }

    private func drag(_ index: Int, _ band: EQBand, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? band
                if dragOrigin == nil {
                    dragOrigin = band
                    selection = index
                }
                var b = origin
                let startX = x(origin.frequency, size.width)
                b.frequency = clampHz(SoundFormat.rounded(hz(atX: startX + value.translation.width, size.width)))
                if origin.type.usesGain {
                    let startY = y(origin.gainDb, size.height)
                    var gain = SoundFormat.tenth(db(atY: startY + value.translation.height, size.height))
                    if abs(gain) < 0.3 { gain = 0 }
                    b.gainDb = clampGain(gain)
                }
                setBand(index, b)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// Pinch for the selected band's Q: spreading the fingers widens the band (a lower Q).
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard eq.mode == .parametric, let index = selection, eq.bands.indices.contains(index) else { return }
                let band = eq.bands[index]
                let origin = pinchOrigin ?? band.q
                pinchOrigin = origin
                var b = band
                b.q = clampQ(SoundFormat.roundedQ(origin / Double(value.magnification)))
                setBand(index, b)
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    private func clampHz(_ v: Double) -> Double {
        min(max(v, SoundRanges.bandFrequency.lowerBound), SoundRanges.bandFrequency.upperBound)
    }

    private func clampGain(_ v: Double) -> Double {
        min(max(v, SoundRanges.bandGain.lowerBound), SoundRanges.bandGain.upperBound)
    }

    private func clampQ(_ v: Double) -> Double {
        min(max(v, SoundRanges.bandQ.lowerBound), SoundRanges.bandQ.upperBound)
    }
}
