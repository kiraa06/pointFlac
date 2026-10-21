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
/// EQ and tone. In Parametric mode each band has a handle: one finger on it drags it, sideways for frequency and up or
/// down for gain. Two fingers anywhere on the graph, on a handle or off it, pinch the Q of the band being dragged, else
/// of the selected band, else of the band nearest the pinch (spread the fingers to widen it); a second finger landing
/// during a drag turns the drag into a pinch and puts the band back where the drag found it. A double tap on the graph
/// adds a band there. Drawn on the deck's screen.
///
/// Drags are measured in the graph's own coordinate space (`space`), which never moves, and the finger's position is
/// mapped straight to frequency and gain, so a handle stays under the finger.
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
    /// One stable id per band, parallel to `eq.bands` (`SoundStore.bandIDs`).
    let bandIDs: [UUID]
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
    @State private var drag: DragState?
    @State private var pinch: PinchState?
    /// A pinch happened during the current drag: the drag stays inert until its finger lifts.
    @State private var pinched = false

    /// The band a finger is dragging: where it was, and where the finger took hold of it relative to its centre.
    private struct DragState {
        var index: Int
        var origin: EQBand
        var grab: CGSize
    }

    /// The band a pinch is shaping, and its Q when the pinch began.
    private struct PinchState {
        var index: Int
        var q: Double
    }

    /// The graph's coordinate space: the handles' drags are measured in it.
    static let space = "eqGraph"

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
                    ForEach(Array(zip(bandIDs, eq.bands).enumerated()), id: \.element.0) { index, pair in
                        handle(index, pair.1, size)
                    }
                }
            }
            .coordinateSpace(.named(Self.space))
            .contentShape(Rectangle())
            .simultaneousGesture(pinchGesture(on: nil, size))
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
        .gesture(dragGesture(index, band, size))
        // A pinch whose fingers both land on the handle reaches it here too; both pinches share one state.
        .simultaneousGesture(pinchGesture(on: index, size))
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

    private func centre(_ band: EQBand, _ size: CGSize) -> CGPoint {
        CGPoint(x: x(band.frequency, size.width), y: y(band.type.usesGain ? band.gainDb : 0, size.height))
    }

    /// One finger on a handle: the band follows it. The finger's position in the graph's space maps straight to
    /// frequency and gain (less where it took hold), so the handle stays under the finger.
    private func dragGesture(_ index: Int, _ band: EQBand, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard !pinched else { return }
                if drag == nil {
                    let c = centre(band, size)
                    drag = DragState(
                        index: index, origin: band,
                        grab: CGSize(width: value.startLocation.x - c.x, height: value.startLocation.y - c.y))
                    selection = index
                }
                guard let drag, eq.bands.indices.contains(drag.index) else { return }
                // The band as it is now, so a Q set meanwhile is kept.
                var b = eq.bands[drag.index]
                b.frequency = clampHz(SoundFormat.rounded(hz(atX: value.location.x - drag.grab.width, size.width)))
                if b.type.usesGain {
                    var gain = SoundFormat.tenth(db(atY: value.location.y - drag.grab.height, size.height))
                    if abs(gain) < 0.3 { gain = 0 }
                    b.gainDb = clampGain(gain)
                }
                setBand(drag.index, b)
            }
            .onEnded { _ in
                drag = nil
                pinched = false
            }
    }

    /// Two fingers: the Q of the band being dragged (put back where the drag found it), else the selected band, else
    /// the band nearest where the pinch began. Spreading the fingers widens the band (a lower Q). `handleIndex` is the
    /// handle this copy is attached to, or nil for the graph's own.
    private func pinchGesture(on handleIndex: Int?, _ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard eq.mode == .parametric, isEnabled else { return }
                if pinch == nil {
                    guard let index = pinchTarget(handleIndex, start: value.startLocation, size) else { return }
                    selection = index
                    pinch = PinchState(index: index, q: eq.bands[index].q)
                    if drag != nil { pinched = true }
                }
                guard let pinch, eq.bands.indices.contains(pinch.index) else { return }
                var b = eq.bands[pinch.index]
                if let drag, drag.index == pinch.index {
                    // The first finger's stray drag is undone: a pinch shapes the band, it does not move it.
                    b.frequency = drag.origin.frequency
                    b.gainDb = drag.origin.gainDb
                }
                b.q = clampQ(SoundFormat.roundedQ(pinch.q / Double(value.magnification)))
                setBand(pinch.index, b)
            }
            .onEnded { _ in pinch = nil }
    }

    private func pinchTarget(_ handleIndex: Int?, start: CGPoint, _ size: CGSize) -> Int? {
        if let drag, eq.bands.indices.contains(drag.index) { return drag.index }
        if let handleIndex, eq.bands.indices.contains(handleIndex) { return handleIndex }
        if let selection, eq.bands.indices.contains(selection) { return selection }
        let distances = eq.bands.indices.map { i -> (Int, CGFloat) in
            let c = centre(eq.bands[i], size)
            return (i, hypot(c.x - start.x, c.y - start.y))
        }
        return distances.min { $0.1 < $1.1 }?.0
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
