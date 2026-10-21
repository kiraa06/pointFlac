import PFAudio
import PFCore
import PFDSP
import SwiftUI

// MARK: Readouts

/// One value in a readout: a small capitalised label over a monospaced value, as the signal strip's cells are.
struct ReadoutCell: Identifiable {
    let label: String
    let value: String
    /// Drawn in the processing tint: a value at work on the sound now.
    var active = false
    var id: String { label }
}

/// A row of readout cells divided by hairlines, the Sound tab's way of showing numbers that are measured or worked out
/// rather than set. At accessibility text sizes the cells stack, one label and value a line. VoiceOver reads it as one
/// element, `label` with each cell's `spoken` value.
struct Readout: View {
    let cells: [ReadoutCell]
    let theme: Theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cells) { cell in
                        HStack(alignment: .firstTextBaseline) {
                            label(cell)
                            Spacer(minLength: 8)
                            value(cell)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                        if index > 0 {
                            Rectangle().fill(theme.hairline).frame(width: 0.5).padding(.horizontal, 10)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            label(cell)
                            value(cell)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func label(_ cell: ReadoutCell) -> some View {
        Text(cell.label.uppercased())
            // The strip's fixed 9 pt label, except stacked at accessibility sizes, where it scales with its value.
            .font(typeSize.isAccessibilitySize ? .caption.monospaced() : Typeface.cellLabel)
            .tracking(1.2)
            .foregroundStyle(theme.inkSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func value(_ cell: ReadoutCell) -> some View {
        Text(cell.value)
            .font(Typeface.cellValue.monospacedDigit())
            .foregroundStyle(cell.active ? theme.processingTint : theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
    }
}

// MARK: ReplayGain

/// ReplayGain: the mode its switch turns on (Track or Album), its preamp, clipping prevention, the reference it levels
/// to, the gain the current track gets, and what the library knows of its tracks' loudness.
struct ReplayGainRows: View {
    let replayGain: ReplayGainSettings
    /// The mode chosen, which the switch turns on while ReplayGain is off.
    let mode: ReplayGainMode
    let store: SoundStore
    let theme: Theme
    let player: Player
    let library: RealLibrary

    var body: some View {
        Picker(
            "ReplayGain mode",
            selection: Binding(
                get: { replayGain.mode == .off ? mode : replayGain.mode }, set: { store.setReplayGainMode($0) })
        ) {
            Text("Track").tag(ReplayGainMode.track)
            Text("Album").tag(ReplayGainMode.album)
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Track levels every song alike; Album keeps a record's own loudness steps")
        .accessibilityIdentifier("replayGainMode")
        SoundSlider(
            title: "Preamp", value: replayGain.preampDb, range: SoundRanges.replayGainPreamp, neutral: 0, step: 0.5,
            format: { SoundFormat.gain($0) }, spoken: SoundFormat.gainSpoken,
            set: { v in store.update { $0.replayGain.preampDb = SoundFormat.tenth(v) } }
        )
        .accessibilityIdentifier("replayGainPreamp")
        Toggle(isOn: store.binding(\.replayGain.preventClipping)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prevent clipping")
                Text("Holds back a gain that would lift the peak past full scale.")
                    .font(.caption)
                    .foregroundStyle(theme.inkSecondary)
            }
        }
        .tint(theme.processingTint)
        .accessibilityIdentifier("preventClippingToggle")
        ReplayGainReadout(replayGain: replayGain, player: player, theme: theme)
        LibraryLoudnessRow(library: library, theme: theme)
    }
}

/// The reference (fixed at ReplayGain 2.0's −18 LUFS, ruling R4-7) and the gain the current track gets, with where it
/// comes from. The gain is the player's own (`Player.replayGainDb`), so it is exactly what plays.
private struct ReplayGainReadout: View {
    let replayGain: ReplayGainSettings
    let player: Player
    let theme: Theme

    private var item: QueueItem? {
        guard let index = player.currentIndex, player.queue.indices.contains(index) else { return nil }
        return player.queue[index]
    }

    var body: some View {
        let gain = item.map { Player.replayGainDb(for: $0, settings: replayGain) }
        let on = replayGain.mode != .off
        let source = item.map { ReplayGainBasis($0.loudness, mode: replayGain.mode) }
        Readout(
            cells: [
                ReadoutCell(label: "Reference", value: SoundFormat.lufs(replayGain.referenceLufs)),
                ReadoutCell(
                    label: "This track", value: !on ? "Off" : gain.map { SoundFormat.gain($0) } ?? "—",
                    active: on && (gain ?? 0) != 0),
                ReadoutCell(label: "From", value: on ? source?.title ?? "—" : "—"),
            ], theme: theme
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ReplayGain reference \(SoundFormat.lufsSpoken(replayGain.referenceLufs))")
        .accessibilityValue(spoken(gain: gain, on: on, source: source))
        .accessibilityIdentifier("replayGainReadout")
    }

    private func spoken(gain: Double?, on: Bool, source: ReplayGainBasis?) -> String {
        guard on else { return "ReplayGain off" }
        guard let gain, let source else { return "Nothing playing" }
        return "This track \(SoundFormat.gainSpoken(gain)), from \(source.title.lowercased())"
    }
}

/// What a track's ReplayGain is worked out from, in `Player.replayGainDb(for:settings:)`'s order of preference: the
/// tag for the mode, else the scan's measurement (in album mode the album's, else the track's), else nothing.
enum ReplayGainBasis {
    case albumTag, albumMeasured, trackTag, trackMeasured, none

    init(_ loudness: TrackLoudness?, mode: ReplayGainMode) {
        let l = loudness ?? TrackLoudness()
        func usable(_ lufs: Double?) -> Bool { lufs.map { $0.isFinite && $0 > -70 } ?? false }
        if mode == .album, l.albumGainDb?.isFinite == true {
            self = .albumTag
        } else if mode == .album, usable(l.albumMeasuredLufs) {
            self = .albumMeasured
        } else if l.trackGainDb?.isFinite == true {
            self = .trackTag
        } else if usable(l.measuredLufs) {
            self = .trackMeasured
        } else {
            self = .none
        }
    }

    var title: String {
        switch self {
        case .albumTag: "Album tag"
        case .albumMeasured: "Album scan"
        case .trackTag: "Track tag"
        case .trackMeasured: "Track scan"
        case .none: "No data"
        }
    }
}

/// What the library knows of its tracks' loudness: tagged, measured by pointFlac's scan, and pending, as a bar in
/// proportion and as counts, with the scan's progress while one runs. It reads the library itself, so a scan's progress
/// redraws this row alone.
struct LibraryLoudnessRow: View {
    let library: RealLibrary
    let theme: Theme

    var body: some View {
        let summary = library.loudness
        let scan = library.loudnessScan
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("LIBRARY LOUDNESS")
                    .font(Typeface.cellLabel)
                    .tracking(1.2)
                    .foregroundStyle(theme.inkSecondary)
                Spacer(minLength: 8)
                Text(scan.map { "MEASURING \($0.done) OF \($0.total)" } ?? "\(summary.total) TRACKS")
                    .font(Typeface.cellLabel.monospacedDigit())
                    .tracking(0.8)
                    .foregroundStyle(scan == nil ? theme.inkSecondary : theme.processingTint)
                    .contentTransition(.numericText())
            }
            if summary.total == 0 {
                Text("No tracks in the library yet.")
                    .font(.caption)
                    .foregroundStyle(theme.inkSecondary)
            } else {
                proportion(summary)
                    .frame(height: 6)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { legend(summary) }
                    VStack(alignment: .leading, spacing: 4) { legend(summary) }
                }
            }
            if let scan {
                ProgressView(value: Double(scan.done), total: Double(max(scan.total, 1)))
                    .tint(theme.processingTint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.25), value: scan == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Library loudness")
        .accessibilityValue(spoken(summary, scan))
        .accessibilityIdentifier("libraryLoudness")
    }

    private var taggedColour: Color { theme.ink.opacity(0.85) }
    private var measuredColour: Color { theme.processingTint }
    private var pendingColour: Color { theme.hairline }

    private func proportion(_ s: LoudnessSummary) -> some View {
        GeometryReader { geo in
            let total = CGFloat(max(s.total, 1))
            HStack(spacing: 1.5) {
                ForEach(
                    [(s.tagged, taggedColour), (s.measured, measuredColour), (s.pending, pendingColour)].enumerated()
                        .filter { $0.element.0 > 0 }, id: \.offset
                ) { _, part in
                    Capsule().fill(part.1).frame(width: max(geo.size.width * CGFloat(part.0) / total - 1.5, 3))
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func legend(_ s: LoudnessSummary) -> some View {
        legendItem("Tagged", s.tagged, taggedColour)
        legendItem("Measured", s.measured, measuredColour)
        legendItem("Pending", s.pending, pendingColour)
    }

    private func legendItem(_ title: String, _ count: Int, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(title).font(.caption).foregroundStyle(theme.inkSecondary)
            Text("\(count)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(theme.ink)
        }
    }

    private func spoken(_ s: LoudnessSummary, _ scan: LoudnessScanProgress?) -> String {
        guard s.total > 0 else { return "No tracks yet" }
        let counts = "\(s.tagged) tagged, \(s.measured) measured, \(s.pending) pending"
        return scan.map { counts + "; measuring \($0.done) of \($0.total)" } ?? counts
    }
}

// MARK: Preamp

/// The gain ahead of the filters, as `SoundChain` sums it: the correction's own preamp while correction is on, the
/// automatic headroom while it is on, and the trim. (The chain also caps the sum at the limiter's largest drive, which
/// only stacked boosts with headroom off reach.)
struct PreampStage: Equatable {
    /// Nil while correction is off.
    var correctionDb: Double?
    /// Nil while automatic headroom is off.
    var headroomDb: Double?
    var trimDb: Double

    init(_ s: SoundSettings, headroomDb: Double) {
        correctionDb = s.correction.enabled ? s.correction.preampDb : nil
        self.headroomDb = s.preamp.autoHeadroom ? headroomDb : nil
        trimDb = s.preamp.trimDb
    }

    var totalDb: Double { (correctionDb ?? 0) + (headroomDb ?? 0) + trimDb }
}

/// The preamp's header, reading the curve model itself: the automatic headroom follows an EQ drag frame by frame, and
/// only this row redraws for it.
struct LivePreampHeader: View {
    let model: EQCurveModel
    let settings: SoundSettings
    let theme: Theme

    var body: some View {
        BlockHeaderRow(block: .preamp, settings: settings, theme: theme, headroomDb: model.headroomDb) { _ in }
    }
}

/// The preamp: automatic headroom, which lowers the level by as much as the curve boosts, so boosts cannot clip; a
/// trim of the user's own; and the gain staging into the filters.
struct PreampRows: View {
    let preamp: PreampSettings
    let settings: SoundSettings
    let model: EQCurveModel
    let store: SoundStore
    let theme: Theme

    var body: some View {
        let headroom = model.headroomDb
        Toggle(isOn: store.binding(\.preamp.autoHeadroom)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto headroom")
                Text(
                    headroom < -0.05
                        ? "Lowers the level \(String(format: "%.1f", abs(headroom))) dB to absorb the curve's highest boost."
                        : "The curve boosts nothing, so it needs no headroom."
                )
                .font(.caption)
                .foregroundStyle(theme.inkSecondary)
                .contentTransition(.numericText())
            }
        }
        .tint(theme.processingTint)
        .accessibilityIdentifier("autoHeadroomToggle")
        SoundSlider(
            title: "Trim", value: preamp.trimDb, range: SoundRanges.trim, neutral: 0, step: 0.5,
            format: { SoundFormat.gain($0) }, spoken: SoundFormat.gainSpoken,
            set: { v in store.update { $0.preamp.trimDb = SoundFormat.tenth(v) } }
        )
        .accessibilityIdentifier("trimSlider")
        let stage = PreampStage(settings, headroomDb: headroom)
        let running = !settings.activeBlockNames.isEmpty
        Readout(
            cells: [
                ReadoutCell(label: "Correction", value: stage.correctionDb.map { SoundFormat.gain($0) } ?? "Off"),
                ReadoutCell(label: "Headroom", value: stage.headroomDb.map { SoundFormat.gain($0) } ?? "Off"),
                ReadoutCell(label: "Trim", value: SoundFormat.gain(stage.trimDb)),
                ReadoutCell(label: "Total", value: SoundFormat.gain(stage.totalDb), active: running),
            ], theme: theme
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gain into the filters")
        .accessibilityValue(spoken(stage, running: running))
        .accessibilityIdentifier("gainStaging")
    }

    private func spoken(_ stage: PreampStage, running: Bool) -> String {
        var parts = [SoundFormat.gainSpoken(stage.totalDb)]
        parts.append("correction \(stage.correctionDb.map(SoundFormat.gainSpoken) ?? "off")")
        parts.append("headroom \(stage.headroomDb.map(SoundFormat.gainSpoken) ?? "off")")
        parts.append("trim \(SoundFormat.gainSpoken(stage.trimDb))")
        return parts.joined(separator: ", ") + (running ? "" : ", standby")
    }
}

// MARK: Crossfade

/// Crossfade (ruling R4-4): where it overlaps one track's end with the next one's start, and for how long. The
/// segmented choice gives way to a menu at accessibility text sizes, where "Between albums" no longer fits its half.
struct CrossfadeRows: View {
    let crossfade: CrossfadeSettings
    /// The mode chosen, which the switch turns on while crossfade is off.
    let mode: CrossfadeMode
    let store: SoundStore
    let theme: Theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
        }
        .accessibilityIdentifier("crossfadeMode")
        SoundSlider(
            title: "Length", value: crossfade.seconds, range: SoundRanges.crossfadeSeconds, step: 0.5,
            format: SoundFormat.seconds, spoken: SoundFormat.secondsSpoken,
            set: { v in store.update { $0.crossfade.seconds = (v * 2).rounded() / 2 } }
        )
        .accessibilityIdentifier("crossfadeLength")
        CrossfadeDiagram(seconds: crossfade.seconds, range: SoundRanges.crossfadeSeconds, theme: theme)
            .frame(height: 34)
            .accessibilityHidden(true)
    }

    private var picker: some View {
        Picker(
            "Crossfade mode",
            selection: Binding(
                get: { crossfade.mode == .off ? mode : crossfade.mode }, set: { store.setCrossfadeMode($0) })
        ) {
            Text("Between albums").tag(CrossfadeMode.betweenAlbums)
            Text("Always").tag(CrossfadeMode.always)
        }
    }
}

/// The equal-power overlap (cos and sin over the length), drawn to the length's scale: the outgoing track's fade in
/// ink, the incoming one's in the processing tint.
private struct CrossfadeDiagram: View {
    let seconds: Double
    let range: ClosedRange<Double>
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            // The overlap takes from a quarter to all of the width between the two tracks' plateaus.
            let fraction = (seconds - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)
            let overlap = size.width * CGFloat(0.22 + 0.5 * fraction)
            let start = (size.width - overlap) / 2
            let top: CGFloat = 3
            let bottom = size.height - 3
            func curve(_ level: (Double) -> Double, from: CGFloat, to: CGFloat, plateau: ClosedRange<CGFloat>) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: plateau.lowerBound, y: level(0) > 0.5 ? top : bottom))
                let steps = 32
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    p.addLine(to: CGPoint(x: from + (to - from) * CGFloat(t), y: bottom - (bottom - top) * level(t)))
                }
                p.addLine(to: CGPoint(x: plateau.upperBound, y: level(1) > 0.5 ? top : bottom))
                return p
            }
            let out = curve({ cos($0 * .pi / 2) }, from: start, to: start + overlap, plateau: 0...start + overlap)
            let into = curve(
                { sin($0 * .pi / 2) }, from: start, to: start + overlap, plateau: start...size.width)
            context.fill(
                Path(CGRect(x: start, y: top, width: overlap, height: bottom - top)),
                with: .color(theme.processingTint.opacity(0.08)))
            context.stroke(out, with: .color(theme.ink.opacity(0.55)), lineWidth: 1.5)
            context.stroke(into, with: .color(theme.processingTint), lineWidth: 1.5)
            context.fill(Path(CGRect(x: 0, y: bottom, width: size.width, height: 0.5)), with: .color(theme.hairline))
        }
    }
}
