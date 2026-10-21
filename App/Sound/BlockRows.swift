import PFAudio
import PFDSP
import SwiftUI

/// A filter type's shape in miniature, for its menu and its band row.
struct FilterShapeIcon: Shape {
    let type: FilterType

    func path(in r: CGRect) -> Path {
        var p = Path()
        let top = r.minY + r.height * 0.1
        let mid = r.midY
        let bottom = r.maxY - r.height * 0.1
        let w = r.width
        func x(_ f: CGFloat) -> CGFloat { r.minX + w * f }
        switch type {
        case .peak:
            p.move(to: CGPoint(x: x(0), y: mid + r.height * 0.15))
            p.addCurve(
                to: CGPoint(x: x(0.5), y: top), control1: CGPoint(x: x(0.3), y: mid + r.height * 0.15),
                control2: CGPoint(x: x(0.38), y: top))
            p.addCurve(
                to: CGPoint(x: x(1), y: mid + r.height * 0.15), control1: CGPoint(x: x(0.62), y: top),
                control2: CGPoint(x: x(0.7), y: mid + r.height * 0.15))
        case .lowShelf:
            p.move(to: CGPoint(x: x(0), y: top))
            p.addLine(to: CGPoint(x: x(0.3), y: top))
            p.addCurve(
                to: CGPoint(x: x(0.7), y: bottom - r.height * 0.15), control1: CGPoint(x: x(0.5), y: top),
                control2: CGPoint(x: x(0.5), y: bottom - r.height * 0.15))
            p.addLine(to: CGPoint(x: x(1), y: bottom - r.height * 0.15))
        case .highShelf:
            p.move(to: CGPoint(x: x(0), y: bottom - r.height * 0.15))
            p.addLine(to: CGPoint(x: x(0.3), y: bottom - r.height * 0.15))
            p.addCurve(
                to: CGPoint(x: x(0.7), y: top), control1: CGPoint(x: x(0.5), y: bottom - r.height * 0.15),
                control2: CGPoint(x: x(0.5), y: top))
            p.addLine(to: CGPoint(x: x(1), y: top))
        case .lowPass:
            p.move(to: CGPoint(x: x(0), y: top + r.height * 0.15))
            p.addLine(to: CGPoint(x: x(0.45), y: top + r.height * 0.15))
            p.addCurve(
                to: CGPoint(x: x(1), y: bottom), control1: CGPoint(x: x(0.65), y: top + r.height * 0.1),
                control2: CGPoint(x: x(0.75), y: mid))
        case .highPass:
            p.move(to: CGPoint(x: x(0), y: bottom))
            p.addCurve(
                to: CGPoint(x: x(0.55), y: top + r.height * 0.15), control1: CGPoint(x: x(0.25), y: mid),
                control2: CGPoint(x: x(0.35), y: top + r.height * 0.1))
            p.addLine(to: CGPoint(x: x(1), y: top + r.height * 0.15))
        case .notch:
            p.move(to: CGPoint(x: x(0), y: top + r.height * 0.15))
            p.addLine(to: CGPoint(x: x(0.36), y: top + r.height * 0.15))
            p.addCurve(
                to: CGPoint(x: x(0.5), y: bottom), control1: CGPoint(x: x(0.46), y: top + r.height * 0.15),
                control2: CGPoint(x: x(0.48), y: bottom))
            p.addCurve(
                to: CGPoint(x: x(0.64), y: top + r.height * 0.15), control1: CGPoint(x: x(0.52), y: bottom),
                control2: CGPoint(x: x(0.54), y: top + r.height * 0.15))
            p.addLine(to: CGPoint(x: x(1), y: top + r.height * 0.15))
        }
        return p
    }
}

// MARK: Sliders

/// A labelled horizontal slider: the name, the system slider (filled from `neutral` for a cut-or-boost control) and
/// the value in monospaced digits. VoiceOver gets one adjustable element with steps of `step` (a ratio when
/// `logarithmic`), and reads the value with its unit in words. At accessibility text sizes the name and the value
/// move above the slider, so nothing is squeezed.
struct SoundSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var logarithmic = false
    var neutral: Double?
    let step: Double
    let format: (Double) -> String
    let spoken: (Double) -> String
    let set: (Double) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .footnote) private var titleWidth = 50.0
    @ScaledMetric(relativeTo: .footnote) private var valueWidth = 78.0

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        titleText
                        Spacer()
                        valueText
                    }
                    slider
                }
            } else {
                HStack(spacing: 10) {
                    titleText.frame(width: titleWidth, alignment: .leading)
                    slider
                    valueText.frame(minWidth: valueWidth, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spoken(value))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: set(stepped(1))
            case .decrement: set(stepped(-1))
            @unknown default: break
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var valueText: some View {
        Text(format(value))
            .font(Typeface.cellValue.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText(value: value))
    }

    @ViewBuilder
    private var slider: some View {
        let position = Binding(get: { toPosition(value) }, set: { set(fromPosition($0)) })
        let bounds = toPosition(range.lowerBound)...toPosition(range.upperBound)
        if let neutral {
            Slider(
                value: position, in: bounds, neutralValue: toPosition(neutral), label: { Text(title) },
                ticks: { SliderTick(toPosition(neutral)) })
        } else {
            Slider(value: position, in: bounds, label: { Text(title) })
        }
    }

    private func toPosition(_ v: Double) -> Double { logarithmic ? log2(v) : v }
    private func fromPosition(_ p: Double) -> Double { logarithmic ? pow(2, p) : p }

    private func stepped(_ direction: Double) -> Double {
        let next = logarithmic ? value * pow(step, direction) : value + step * direction
        return min(max(next, range.lowerBound), range.upperBound)
    }
}

/// A graphic EQ slider: a console fader. Only the cap takes a drag (a band 44 pt tall round it, the column's full
/// width), as on a hardware console, so a scroll that starts anywhere else on the bank scrolls the list. The drag is
/// relative to where the cap was, so a touch alone changes nothing; there is a detent at 0 dB, and a double tap
/// anywhere on the column returns to it. VoiceOver steps it by 0.5 dB.
struct VerticalFader: View {
    let value: Double
    let range: ClosedRange<Double>
    let frequency: Double
    let theme: Theme
    let set: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var dragStart: Double?

    private static let capHeight: CGFloat = 12
    /// The height of the band round the cap that takes a drag.
    static let grabHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 6) {
            Text(SoundFormat.signed(value))
                .font(.caption2.monospaced().weight(.semibold).monospacedDigit())
                .foregroundStyle(value == 0 ? theme.inkSecondary : theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            GeometryReader { geo in
                track(geo.size)
            }
            Text(SoundFormat.frequencyShort(frequency))
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .sensoryFeedback(.selection, trigger: value == 0) { _, atZero in atZero && dragStart != nil }
        .sensoryFeedback(.selection, trigger: dragStart != nil) { _, grabbed in grabbed }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SoundFormat.frequency(frequency)) band")
        .accessibilityValue(SoundFormat.gainSpoken(value))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: set(clamp(value + 0.5))
            case .decrement: set(clamp(value - 0.5))
            @unknown default: break
            }
        }
    }

    private func track(_ size: CGSize) -> some View {
        let travel = max(size.height - Self.capHeight, 1)
        let centre = size.height / 2
        let span = range.upperBound - range.lowerBound
        let y = Self.capHeight / 2 + (range.upperBound - value) / span * travel
        let tint = theme.processingTint
        let grabbed = dragStart != nil
        return ZStack {
            // The scale: a tick at every 6 dB, longer at 0.
            Canvas { context, canvas in
                for db in stride(from: range.lowerBound, through: range.upperBound, by: 6) {
                    let ty = Self.capHeight / 2 + (range.upperBound - db) / span * travel
                    let half: CGFloat = db == 0 ? 9 : 5
                    context.fill(
                        Path(CGRect(x: canvas.width / 2 - half, y: ty - 0.25, width: half * 2, height: 0.5)),
                        with: .color(theme.hairline))
                }
            }
            Capsule().fill(theme.hairline).frame(width: 3)
            Capsule()
                .fill(tint)
                .frame(width: 3, height: abs(y - centre))
                .position(x: size.width / 2, y: (y + centre) / 2)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: theme.isDark
                            ? [Color(white: 0.78), Color(white: 0.46)] : [.white, Color(white: 0.84)],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    Rectangle().fill(theme.isDark ? Color.black.opacity(0.55) : theme.ink.opacity(0.7))
                        .frame(height: 1.2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(grabbed ? tint : theme.plinthEdge, lineWidth: grabbed ? 1.5 : 1)
                )
                .frame(width: min(size.width - 4, 28), height: Self.capHeight)
                .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.18), radius: 2, y: 1)
                .scaleEffect(grabbed ? 1.08 : 1)
                .position(x: size.width / 2, y: y)
        }
        .frame(width: size.width, height: size.height)
        // The whole column takes a double tap: a tap never holds up a scroll.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { set(0) }
        // Only the band round the cap takes a drag. The overlay does not move, so the drag's space stays put.
        .overlay {
            Color.clear
                .contentShape(CapBand(centreY: y, height: Self.grabHeight))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let start = dragStart ?? value
                            dragStart = start
                            var next = SoundFormat.tenth(start - drag.translation.height / travel * span)
                            if abs(next) < 0.3 { next = 0 }
                            set(clamp(next))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { set(0) })
        }
        .animation(.easeOut(duration: 0.12), value: grabbed)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
}

/// The band round a fader's cap that takes a drag: the column's full width, `height` tall, centred on the cap.
private struct CapBand: Shape {
    var centreY: CGFloat
    var height: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: centreY - height / 2, width: rect.width, height: height))
    }
}

/// The ten graphic sliders, with the dB scale on the left. Each fader takes an equal share of the row, so its touch
/// column is as wide as the row allows (about 34 pt on an iPhone 17 Pro).
struct GraphicEQBank: View {
    let gains: [Double]
    let theme: Theme
    let set: (Int, Double) -> Void
    @ScaledMetric(relativeTo: .caption2) private var height = 172.0

    var body: some View {
        let range = SoundRanges.graphicGain
        HStack(alignment: .top, spacing: 0) {
            scale(range)
            ForEach(Array(SoundRanges.graphicCentres.enumerated()), id: \.offset) { index, hz in
                VerticalFader(
                    value: index < gains.count ? gains[index] : 0, range: range, frequency: hz, theme: theme,
                    set: { set(index, $0) }
                )
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("graphicBand-\(index)")
            }
        }
        .frame(height: min(height, 230))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// "+12", "0" and "−12", level with the faders' ticks.
    private func scale(_ range: ClosedRange<Double>) -> some View {
        VStack {
            Text(SoundFormat.signed(range.upperBound, decimals: 0))
            Spacer()
            Text("0")
            Spacer()
            Text(SoundFormat.signed(range.lowerBound, decimals: 0))
        }
        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
        .foregroundStyle(theme.inkSecondary)
        .padding(.vertical, 16)
        .frame(width: 22)
        .accessibilityHidden(true)
    }
}

// MARK: Rows

/// Greys a row while Pure makes it inert (the section is disabled then); the graph and the meters draw their own
/// bypassed look instead.
struct PureDimmed: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    func pureDimmed() -> some View { modifier(PureDimmed()) }
}

/// A block's first row: its name, what it is set to, and its switch. The limiter has no switch: it says when it runs.
struct BlockHeaderRow: View {
    let block: SoundBlock
    let settings: SoundSettings
    let theme: Theme
    let set: (Bool) -> Void

    var body: some View {
        if block.isSwitchable {
            Toggle(isOn: Binding(get: { block.isOn(in: settings) }, set: { set($0) })) { label }
                .tint(theme.processingTint)
                .accessibilityIdentifier("\(block.rawValue)Toggle")
        } else {
            HStack {
                label
                Spacer()
                Text(block.isActive(in: settings) ? "Running" : "Standby")
                    .font(Typeface.cellValue)
                    .foregroundStyle(block.isActive(in: settings) ? theme.processingTint : theme.inkSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(block.rawValue)Status")
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(block.isActive(in: settings) ? theme.processingTint : theme.hairline)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold)).tracking(-0.3)
                Text(summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(2)
            }
        }
    }

    private var title: String {
        switch block {
        case .eq: "Equaliser"
        case .tone: "Tone"
        case .crossfeed: "Crossfeed"
        case .limiter: "Limiter"
        }
    }

    private var summary: String {
        switch block {
        case .eq:
            let eq = settings.eq
            if eq.mode == .graphic { return "Graphic · \(SoundStore.presetName(for: eq.graphicGainsDb))" }
            let on = eq.bands.filter(\.enabled).count
            return "Parametric · \(on) band\(on == 1 ? "" : "s")"
        case .tone:
            let t = settings.tone
            if t.bassDb == 0, t.trebleDb == 0, t.tiltDb == 0 { return "Flat" }
            return "Bass \(SoundFormat.signedTrimmed(t.bassDb)) · Treble \(SoundFormat.signedTrimmed(t.trebleDb)) · "
                + "Tilt \(SoundFormat.signedTrimmed(t.tiltDb))"
        case .crossfeed:
            return settings.crossfeed.preset.title
        case .limiter:
            return "Ceiling \(SoundFormat.gain(settings.limiter.ceilingDbTP, unit: "dBTP"))"
        }
    }
}

/// The parametric band list: one row per band, with its shape, frequency, gain and Q, and a switch. Swipe a row to
/// delete it.
struct BandRow: View {
    let index: Int
    let band: EQBand
    let selected: Bool
    let theme: Theme
    let set: (EQBand) -> Void
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .frame(minWidth: 22, minHeight: 22)
                    .foregroundStyle(selected ? theme.background : theme.ink)
                    .background(Circle().fill(selected ? theme.processingTint : .clear))
                    .overlay(Circle().strokeBorder(selected ? .clear : theme.hairline))
                    .accessibilityHidden(true)
                Menu {
                    Picker("Filter type", selection: Binding(get: { band.type }, set: { t in update { $0.type = t } }))
                    {
                        ForEach(FilterType.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        FilterShapeIcon(type: band.type)
                            .stroke(theme.processingTint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .frame(width: 22, height: 12)
                        Text(band.type.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .fixedSize()
                .accessibilityLabel("Filter type")
                .accessibilityValue(band.type.title)
                .accessibilityIdentifier("bandType-\(index)")
                Spacer(minLength: 0)
                Toggle(
                    "Band \(index + 1) on",
                    isOn: Binding(get: { band.enabled }, set: { on in update { $0.enabled = on } })
                )
                .labelsHidden()
                .tint(theme.processingTint)
                .accessibilityIdentifier("bandToggle-\(index)")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            SoundSlider(
                title: "Freq", value: band.frequency, range: SoundRanges.bandFrequency, logarithmic: true,
                step: pow(2, 1.0 / 6), format: SoundFormat.frequency, spoken: SoundFormat.frequencySpoken,
                set: { v in update { $0.frequency = SoundFormat.rounded(v) } }
            )
            .accessibilityIdentifier("bandFrequency-\(index)")
            SoundSlider(
                title: "Gain", value: band.gainDb, range: SoundRanges.bandGain, neutral: 0, step: 0.5,
                format: { band.type.usesGain ? SoundFormat.gain($0) : "—" }, spoken: SoundFormat.gainSpoken,
                set: { v in update { $0.gainDb = SoundFormat.tenth(v) } }
            )
            .disabled(!band.type.usesGain)
            .accessibilityIdentifier("bandGain-\(index)")
            SoundSlider(
                title: "Q", value: band.q, range: SoundRanges.bandQ, logarithmic: true, step: pow(2, 1.0 / 4),
                format: SoundFormat.q, spoken: SoundFormat.qSpoken,
                set: { v in update { $0.q = SoundFormat.roundedQ(v) } }
            )
            .accessibilityIdentifier("bandQ-\(index)")
        }
        .padding(.vertical, 4)
        .opacity(band.enabled ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Band \(index + 1), \(band.type.title)")
    }

    /// Edits this band, and selects it so the graph shows which one moves.
    private func update(_ change: (inout EQBand) -> Void) {
        var b = band
        change(&b)
        select()
        set(b)
    }
}

extension CrossfeedPreset {
    var title: String {
        switch self {
        case .defaultBS2B: "Default (bs2b)"
        case .chuMoy: "Chu Moy"
        case .janMeier: "Jan Meier"
        }
    }

    /// "Cut 700 Hz · feed 4.5 dB".
    var detail: String {
        let p = parameters
        return "Cut \(SoundFormat.frequency(p.cutHz)) · feed \(SoundFormat.trimmed(p.feedDb)) dB"
    }
}

/// Tone: bass and treble shelves, tilt around 1 kHz, and Runout's warmth curve.
struct ToneRows: View {
    let tone: ToneSettings
    let theme: Theme
    let store: SoundStore

    var body: some View {
        SoundSlider(
            title: "Bass", value: tone.bassDb, range: SoundRanges.bass, neutral: 0, step: 0.5,
            format: { SoundFormat.gain($0) }, spoken: SoundFormat.gainSpoken,
            set: { v in store.update { $0.tone.bassDb = SoundFormat.tenth(v) } }
        )
        .accessibilityIdentifier("bassSlider")
        SoundSlider(
            title: "Treble", value: tone.trebleDb, range: SoundRanges.treble, neutral: 0, step: 0.5,
            format: { SoundFormat.gain($0) }, spoken: SoundFormat.gainSpoken,
            set: { v in store.update { $0.tone.trebleDb = SoundFormat.tenth(v) } }
        )
        .accessibilityIdentifier("trebleSlider")
        SoundSlider(
            title: "Tilt", value: tone.tiltDb, range: SoundRanges.tilt, neutral: 0, step: 0.5,
            format: { SoundFormat.gain($0) }, spoken: SoundFormat.gainSpoken,
            set: { v in store.update { $0.tone.tiltDb = SoundFormat.tenth(v) } }
        )
        .accessibilityIdentifier("tiltSlider")
        .accessibilityHint("Above zero tilts toward the treble, below toward the bass, around 1 kilohertz.")
        HStack(spacing: 10) {
            Button("Warmth", systemImage: "flame") { store.applyWarmth() }
                .buttonStyle(.glass)
                .accessibilityIdentifier("warmthButton")
                .accessibilityHint("Bass plus 2, treble minus 1.5, tilt minus 1")
            Button("Flat") { store.flattenTone() }
                .buttonStyle(.glass)
                .disabled(tone.bassDb == 0 && tone.trebleDb == 0 && tone.tiltDb == 0)
                .accessibilityIdentifier("toneFlatButton")
            Spacer(minLength: 0)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(theme.ink)
    }
}

/// Crossfeed: its preset, with the preset's cut and feed.
struct CrossfeedRows: View {
    let crossfeed: CrossfeedSettings
    let theme: Theme
    let store: SoundStore

    var body: some View {
        Picker(selection: store.binding(\.crossfeed.preset)) {
            ForEach(CrossfeedPreset.allCases, id: \.self) { preset in
                Text(preset.title).tag(preset)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preset")
                Text(crossfeed.preset.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.inkSecondary)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("crossfeedPreset")
    }
}

/// The limiter's ceiling and its gain-reduction meter.
struct LimiterRows: View {
    let limiter: LimiterSettings
    let store: SoundStore
    let meters: MeterBallistics
    let player: Player
    let screen: Theme
    let polling: Bool

    var body: some View {
        SoundSlider(
            title: "Ceiling", value: limiter.ceilingDbTP, range: SoundRanges.ceiling, step: 0.1,
            format: { SoundFormat.gain($0, unit: "dBTP") },
            spoken: { "\(SoundFormat.gainSpoken($0)) true peak" },
            set: { v in store.update { $0.limiter.ceilingDbTP = SoundFormat.tenth(v) } }
        )
        .accessibilityIdentifier("ceilingSlider")
        .pureDimmed()
        GainReductionMeter(meters: meters, source: player, theme: screen, polling: polling)
    }
}
