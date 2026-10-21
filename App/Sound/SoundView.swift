import PFAudio
import PFCore
import PFDSP
import SwiftUI

/// The Sound tab (spec §4.8), laid out like a pro tool: the Pure master switch, the signal flow with a capsule per
/// block, the output meter and its clip LED, then each block with its own switch: the EQ first, as the block used
/// most, then the other tonal blocks, then those set once (`SoundBlock.pageOrder`, rulings R4-UI-a and R4-UI-b). The
/// flow row and the Pure card keep the chain's own order, since they describe the signal path; a capsule's menu scrolls
/// to its block.
///
/// Pure is the master. While it is on, every block row and capsule is greyed and inert, and the graph shows what Pure
/// bypasses; the blocks keep their own switches, so turning Pure off brings them back as they were.
///
/// The meters poll `Player.soundMeters` only while this tab is on screen and the app is active, at up to 60 Hz, and
/// stop a few seconds after playback stops, once they have fallen back. Each time polling resumes, one read is thrown
/// away, so an old peak or clip is never shown as new. The colours all come from the deck's `Theme`, and from its
/// greyscale twin under Monochrome.
struct SoundView: View {
    let store: SoundStore
    let playback: PlaybackController
    /// What the ReplayGain block shows of the library's loudness data and scan.
    let library: RealLibrary
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isMonochrome) private var mono
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedBand: Int?
    @State private var curve = EQCurveModel()
    @State private var meters = MeterBallistics()
    @State private var visible = false
    /// Playback has been stopped long enough for the meters to fall back to rest (see `meterIdleDelay`).
    @State private var metersIdle = false
    @State private var choosingCorrection = false

    /// Long enough for the meters to fall from full scale to the floor (60 dB at 24 dB/s, after a 1.5 s hold), and for
    /// a clip LED to go out.
    private static let meterIdleDelay: Duration = .seconds(4)

    private var player: Player { playback.player }
    private var theme: Theme { .look(stage: .deck, dark: scheme == .dark, monochrome: mono) }
    /// The deck screen's look, dark in both appearances, for the graph and the meters.
    private var screen: Theme { .look(stage: .deck, dark: true, monochrome: mono) }
    private var palette: ArtPalette { ArtPalette(seed: playback.album?.id ?? "pointflac").tint(for: theme) }
    private var polling: Bool { visible && scenePhase == .active && !metersIdle }
    private var playing: Bool { player.status == .playing }

    /// The rate the chain runs at, which its filters are designed for: the output's, else the file's, else 48 kHz.
    private var sampleRate: Double {
        Double(player.signal.plan?.clientSampleRate ?? player.signal.source?.sampleRate ?? 48_000)
    }

    var body: some View {
        let s = store.settings
        NavigationStack {
            ScrollViewReader { proxy in
                list(s, proxy)
                    .onAppear { scrollForScreenshots(proxy) }
            }
            .navigationTitle("Sound")
        }
        .sheet(isPresented: $choosingCorrection) {
            CorrectionPicker(store: store, theme: theme)
                .environment(\.isMonochrome, mono)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: CurveInput(s, sampleRate: sampleRate), initial: true) { _, input in
            curve.request(input)
        }
        .onChange(of: polling, initial: true) { _, on in
            if on { meters.resync(player) }
        }
        .task(id: playing) {
            guard !playing else {
                metersIdle = false
                return
            }
            try? await Task.sleep(for: Self.meterIdleDelay)
            if !Task.isCancelled { metersIdle = true }
        }
    }

    private func list(_ s: SoundSettings, _ proxy: ScrollViewProxy) -> some View {
        List {
            Section {
                PureSwitch(settings: s, theme: theme) { store.setPure($0) }
            }
            .listRowBackground(glass)
            Section {
                SignalFlowRow(
                    settings: s, theme: theme, toggle: { block in setBlock(block, on: !block.isOn(in: s)) },
                    show: { block in withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(block, anchor: .top) } })
                OutputMeter(meters: meters, player: player, theme: screen, polling: polling)
                    .listRowInsets(Self.screenInsets)
            } header: {
                header("Signal flow")
            } footer: {
                footerText(
                    s.pure
                        ? "Pure sends the signal straight through."
                        : "Tap a block to switch it; touch and hold it for its settings.")
            }
            .listRowBackground(glass)
            ForEach(SoundBlock.pageOrder) { block in
                section(block, s)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .listRowSeparatorTint(theme.hairline)
        .background(background)
        .foregroundStyle(theme.ink)
        .tint(theme.processingTint)
    }

    /// `-PFSoundScrollTo <block>` (DEBUG only; a `SoundBlock` raw value, such as replayGain or eq) opens scrolled to
    /// that block, `-PFSoundSelectBand <n>` with parametric band n selected, and `-PFSoundOpenPicker YES` with the
    /// headphone-correction picker open, for screenshots.
    private func scrollForScreenshots(_ proxy: ScrollViewProxy) {
        #if DEBUG
            let band = UserDefaults.standard.integer(forKey: "PFSoundSelectBand")
            if band > 0 { selectedBand = band - 1 }
            if UserDefaults.standard.bool(forKey: "PFSoundOpenPicker") { choosingCorrection = true }
            guard let name = UserDefaults.standard.string(forKey: "PFSoundScrollTo"),
                let block = SoundBlock(rawValue: name)
            else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(block, anchor: .top)
            }
        #endif
    }

    // MARK: Sections

    /// Switches a block. Correction with no headphones chosen opens the picker instead: choosing them switches it on.
    private func setBlock(_ block: SoundBlock, on: Bool) {
        if block == .correction, on, !store.hasCorrection {
            choosingCorrection = true
            return
        }
        store.setBlock(block, on: on)
    }

    @ViewBuilder
    private func section(_ block: SoundBlock, _ s: SoundSettings) -> some View {
        Section {
            Group {
                header(block, s)
                    .pureDimmed()
                    .id(block)
                switch block {
                case .replayGain:
                    ReplayGainRows(
                        replayGain: s.replayGain, mode: store.lastReplayGainMode, store: store, theme: theme,
                        player: player, library: library
                    )
                    .pureDimmed()
                case .preamp:
                    PreampRows(preamp: s.preamp, settings: s, model: curve, store: store, theme: theme)
                        .pureDimmed()
                case .correction:
                    CorrectionRows(correction: s.correction, theme: theme) { choosingCorrection = true }
                        .pureDimmed()
                case .crossfade:
                    CrossfadeRows(crossfade: s.crossfade, mode: store.lastCrossfadeMode, store: store, theme: theme)
                        .pureDimmed()
                case .eq:
                    eqRows(s)
                case .tone:
                    ToneRows(tone: s.tone, theme: theme, store: store)
                        .pureDimmed()
                case .crossfeed:
                    CrossfeedRows(crossfeed: s.crossfeed, theme: theme, store: store)
                        .pureDimmed()
                case .limiter:
                    LimiterRows(
                        limiter: s.limiter, store: store, meters: meters, player: player, screen: screen,
                        polling: polling)
                }
            }
            .disabled(s.pure)
        } footer: {
            footerText(footer(block, s))
        }
        .listRowBackground(glass)
    }

    @ViewBuilder
    private func header(_ block: SoundBlock, _ s: SoundSettings) -> some View {
        if block == .preamp {
            // Its total follows the curve's headroom, which it reads itself.
            LivePreampHeader(model: curve, settings: s, theme: theme)
        } else {
            BlockHeaderRow(
                block: block, settings: s, theme: theme, replayGainMode: store.lastReplayGainMode,
                crossfadeMode: store.lastCrossfadeMode
            ) { setBlock(block, on: $0) }
        }
    }

    /// The insets of the rows drawn on the deck's screen (the graph and the meters), so their panels line up.
    static let screenInsets = EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10)

    @ViewBuilder
    private func eqRows(_ s: SoundSettings) -> some View {
        EQControlsRow(eq: s.eq, store: store, theme: theme)
            .pureDimmed()
        // The graph keeps its screen bright under Pure: it draws the bypass itself.
        LiveEQGraph(
            model: curve, eq: s.eq, bandIDs: store.bandIDs, autoHeadroom: s.preamp.autoHeadroom,
            sampleRate: sampleRate,
            look: s.pure ? .bypassed : s.eq.enabled ? .live : .eqOff, selection: $selectedBand, theme: screen,
            setBand: { store.setBand($0, $1) },
            addBand: { band in
                if let index = store.addBand(band) { selectedBand = index }
            }
        )
        .frame(height: 200)
        .listRowInsets(Self.screenInsets)
        if s.eq.mode == .graphic {
            // Narrow insets: every point of width goes to the faders' touch columns.
            GraphicEQBank(gains: s.eq.graphicGainsDb, theme: theme) { store.setGraphicGain($0, $1) }
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 8))
                .pureDimmed()
        } else {
            if s.eq.bands.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No bands yet. Add one, double-tap the graph, or start from the graphic EQ's ten sliders.")
                        .font(.subheadline)
                        .foregroundStyle(theme.inkSecondary)
                    Button("Start from the graphic EQ", systemImage: "slider.vertical.3") {
                        store.copyGraphicToBands()
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("copyGraphicButton")
                }
                .padding(.vertical, 4)
                .pureDimmed()
            }
            ForEach(Array(zip(store.bandIDs, s.eq.bands).enumerated()), id: \.element.0) { index, pair in
                BandRow(
                    index: index, band: pair.1, selected: selectedBand == index, theme: theme,
                    set: { store.setBand(index, $0) },
                    select: { withAnimation(.snappy(duration: 0.25)) { selectedBand = index } }
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    // Nothing to swipe while Pure makes the EQ inert (List swipes ignore `.disabled`).
                    if !s.pure {
                        Button(role: .destructive) {
                            delete(index)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .monoDestructive()
                    }
                }
                .pureDimmed()
                .accessibilityIdentifier("bandRow-\(index)")
            }
            HStack {
                Button("Add band", systemImage: "plus") {
                    if let index = store.addBand() { selectedBand = index }
                }
                .buttonStyle(.glass)
                .disabled(s.eq.bands.count >= SoundRanges.maxBands)
                .accessibilityIdentifier("addBandButton")
                Spacer()
                Text("\(s.eq.bands.count) of \(SoundRanges.maxBands) bands")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.inkSecondary)
            }
            .pureDimmed()
        }
    }

    private func delete(_ index: Int) {
        guard !store.settings.pure else { return }
        store.removeBand(at: index)
        guard let selected = selectedBand else { return }
        if selected == index {
            selectedBand = nil
        } else if selected > index {
            selectedBand = selected - 1
        }
    }

    /// Short, as a pro tool's notes are.
    private func footer(_ block: SoundBlock, _ s: SoundSettings) -> String {
        switch block {
        case .replayGain:
            return "Tags first, then pointFlac's own loudness scan. Album keeps a record's loudness steps."
        case .preamp:
            return "Headroom follows the curve, so boosts can't clip. Trim adds gain of your own."
        case .correction:
            return "Corrects your headphones toward a target curve. The EQ graph draws it into its curve."
        case .crossfade:
            return "Between albums blends only where an Up Next record follows; songs inside a record stay gapless."
        case .eq:
            return s.eq.mode == .parametric
                ? "Drag a handle; pinch for Q. Swipe a band to delete it. Headroom keeps boosts from clipping."
                : "Double-tap a fader for 0 dB. Headroom keeps boosts from clipping."
        case .tone:
            return "Shelves at 100 Hz and 10 kHz; tilt pivots at 1 kHz."
        case .crossfeed:
            return "For headphones: a little of each channel, low-passed, reaches the other ear."
        case .limiter:
            return "Look-ahead, true-peak. Runs whenever a block is on."
        }
    }

    private func footerText(_ text: String) -> some View {
        Text(text).foregroundStyle(theme.inkSecondary)
    }

    // MARK: Look

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.monospaced().weight(.semibold))
            .tracking(1.4)
            .foregroundStyle(theme.inkSecondary)
    }

    private var glass: some View { SoundGlass(theme: theme) }

    /// The deck's background: pastel light from the record behind the glass, in greys under Monochrome.
    private var background: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                theme.background
                Circle().fill(palette.base.opacity(theme.glow)).frame(width: w).blur(radius: 70)
                    .offset(x: -w * 0.4, y: -w * 0.2)
                Circle().fill(palette.sea.opacity(theme.glow)).frame(width: w * 0.9).blur(radius: 70)
                    .offset(x: w * 0.45, y: w * 0.75)
            }
            .frame(width: w, height: geo.size.height)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: playback.album?.id)
    }
}

/// Frosted glass over the record's light, as the deck's plinth is: the Sound tab's card background.
struct SoundGlass: View {
    let theme: Theme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(theme.plinthTop.opacity(theme.isDark ? 0.5 : 0.55))
        }
    }
}

/// The graph, reading the curve model itself: a new curve redraws the graph alone, not the whole list.
private struct LiveEQGraph: View {
    let model: EQCurveModel
    let eq: EQSettings
    let bandIDs: [UUID]
    let autoHeadroom: Bool
    let sampleRate: Double
    let look: EQGraphView.Look
    @Binding var selection: Int?
    let theme: Theme
    let setBand: (Int, EQBand) -> Void
    let addBand: (EQBand) -> Void

    var body: some View {
        EQGraphView(
            eq: eq, bandIDs: bandIDs, curve: model.curve, correctionCurve: model.correctionCurve,
            headroomDb: autoHeadroom ? model.headroomDb : nil, sampleRate: sampleRate,
            look: look, selection: $selection, theme: theme, setBand: setBand, addBand: addBand)
    }
}

// MARK: Pure

/// The master switch: large, the whole card is the switch. Green as the strip's "● Pure" when on; when off, what
/// plays instead.
struct PureSwitch: View {
    let settings: SoundSettings
    let theme: Theme
    let set: (Bool) -> Void

    private var isOn: Bool { settings.pure }
    private var chain: [String] { settings.activeBlockNames }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(led)
                        .frame(width: 8, height: 8)
                        .shadow(color: led.opacity(isOn || !chain.isEmpty ? 0.8 : 0), radius: 4)
                    Text(isOn ? "BYPASS ACTIVE" : chain.isEmpty ? "NOTHING ON" : "PROCESSING")
                        .font(Typeface.cellLabel)
                        .tracking(1.6)
                        .foregroundStyle(theme.inkSecondary)
                }
                Text("Pure")
                    .font(Typeface.display(34))
                    .tracking(-0.7)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            BigSwitch(isOn: isOn, theme: theme)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
        .accessibilityRepresentation {
            Toggle("Pure", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
        }
        .accessibilityHint(isOn ? "Bypasses every block" : "Turn on to bypass every block")
        .accessibilityIdentifier("pureSwitch")
    }

    private func toggle() {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { set(!isOn) }
    }

    private var led: Color {
        if isOn { return theme.ok }
        return chain.isEmpty ? theme.inkSecondary : theme.altered
    }

    private var detail: String {
        if isOn { return "Untouched by pointFlac: every block is bypassed." }
        if chain.isEmpty { return "No block is on, so the sound still leaves pointFlac untouched." }
        return chain.joined(separator: " → ")
    }
}

/// The Pure switch's track and knob, drawn large.
private struct BigSwitch: View {
    let isOn: Bool
    let theme: Theme

    var body: some View {
        let track = isOn ? (theme.isMonochrome ? Theme.monochromeTint : theme.ok) : theme.hairline
        Capsule()
            .fill(track)
            .frame(width: 64, height: 36)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
                    .padding(3)
            }
            .animation(.spring(duration: 0.35, bounce: 0.25), value: isOn)
            .accessibilityHidden(true)
    }
}

// MARK: Flow

/// The chain as capsules, IN to OUT, joined by a wire. It wraps when the chain is wider than the row: rows as even as
/// they can be, each spread across the width, and the wire turning down at a row's end and back to the next row's
/// start, so the whole chain stays in view at every text size. Each switchable block's capsule toggles it; the
/// limiter's and the preamp's report what they do. Every capsule's menu (touch and hold), and its VoiceOver action,
/// "Show <block> settings", scrolls to the block's section. In Pure the wire is one green line from IN to OUT behind
/// the capsules, which are ghosted, all alike, and inert.
struct SignalFlowRow: View {
    let settings: SoundSettings
    let theme: Theme
    let toggle: (SoundBlock) -> Void
    /// Scrolls the page to the block's section.
    let show: (SoundBlock) -> Void

    /// The radius of the wire's turns between rows; a wrapped row keeps twice it clear at its turning ends.
    private static let turn: CGFloat = 5

    var body: some View {
        let blocks = SoundBlock.allCases
        WrappingFlowLayout(gap: 5, rowGap: 16, margin: 2 * Self.turn) {
            terminal("IN").flowItem(0)
            ForEach(Array(blocks.enumerated()), id: \.element) { index, block in
                capsule(block).flowItem(index + 1)
            }
            terminal("OUT").flowItem(blocks.count + 1)
        }
        .backgroundPreferenceValue(FlowItemBounds.self) { anchors in
            GeometryReader { proxy in
                FlowWire(
                    items: anchors.sorted { $0.key < $1.key }.map { proxy[$0.value] }, turn: Self.turn,
                    continuous: settings.pure
                )
                .stroke(
                    settings.pure ? theme.ok : theme.inkSecondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: settings.pure ? 2 : 1.5, lineCap: .round, lineJoin: .round))
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signal flow")
    }

    private func terminal(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .tracking(1)
            .foregroundStyle(theme.inkSecondary)
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// A capsule is a menu with a primary action: a tap switches a switchable block, and a touch and hold opens "Show
    /// <block> settings". A menu rather than a context menu: a List row merges its rows' context menus into one, so
    /// every capsule would offer the first one's item. The limiter's and the preamp's capsules have no switch, so a tap
    /// opens their menu.
    private func capsule(_ block: SoundBlock) -> some View {
        let title = "Show \(block.settingsName) settings"
        let item = Button(title, systemImage: "arrow.down.to.line") { show(block) }
        return Group {
            if block.isSwitchable {
                Menu {
                    item
                } label: {
                    capsuleFace(block)
                } primaryAction: {
                    toggle(block)
                }
                .accessibilityAddTraits(.isToggle)
            } else {
                Menu {
                    item
                } label: {
                    capsuleFace(block)
                }
            }
        }
        .menuStyle(.button)
        // A style of its own, so a disabled capsule is not dimmed a second time: Pure ghosts them all alike.
        .buttonStyle(CapsuleButtonStyle())
        .menuIndicator(.hidden)
        .disabled(settings.pure)
        .modifier(CapsuleAccessibility(block: block, settings: settings))
        .accessibilityAction(named: title) { show(block) }
    }

    private func capsuleFace(_ block: SoundBlock) -> some View {
        let on = block.isOn(in: settings)
        let active = block.isActive(in: settings)
        let tint = theme.processingTint
        let pure = settings.pure
        return HStack(spacing: 4) {
            Text(block.capsuleName.uppercased())
            if block == .limiter {
                Text("AUTO").font(.caption2.monospaced().weight(.bold)).textScale(.secondary).opacity(0.75)
            }
        }
        .font(.caption2.monospaced().weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .foregroundStyle(pure ? theme.inkSecondary : active ? theme.background : on ? tint : theme.inkSecondary)
        // Under Pure the ghost is opaque, so the bypass line reads as passing behind it.
        .background {
            if pure {
                Capsule().fill(theme.background).overlay(Capsule().fill(theme.plinthTop))
            } else {
                Capsule().fill(active ? tint : Color.clear)
            }
        }
        .overlay(
            Capsule().strokeBorder(
                pure ? theme.inkSecondary.opacity(0.5) : active ? Color.clear : on ? tint : theme.hairline,
                style: StrokeStyle(lineWidth: 1, dash: pure ? [3, 2] : []))
        )
    }
}

/// Each flow item's bounds, by its place in the chain, for the wire.
private struct FlowItemBounds: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports the view's bounds as flow item `index`.
    fileprivate func flowItem(_ index: Int) -> some View {
        anchorPreference(key: FlowItemBounds.self, value: .bounds) { [index: $0] }
    }
}

/// Lays the flow's items out in rows: one row when they fit, spread across the width; else the fewest rows that do,
/// broken as evenly as they can be, all with the spacing that fills the fullest row, so the blocks sit evenly and the
/// wire's longer runs fall where it travels: before a turn, and into OUT, which ends the last row at the right edge. A
/// row that wraps keeps `margin` clear at its turning ends: the end of every row but the last, and the start of every
/// row but the first. Items keep their ideal sizes, centred in their row.
struct WrappingFlowLayout: Layout {
    /// The least space between two items: the wire's shortest run.
    var gap: CGFloat
    var rowGap: CGFloat
    var margin: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = span(Array(sizes.indices), sizes)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let rows = rows(sizes, width: width)
        let heights = rows.map { row in row.map { sizes[$0].height }.max() ?? 0 }
        return CGSize(width: width, height: heights.reduce(0, +) + rowGap * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(sizes, width: bounds.width)
        func lead(_ r: Int) -> CGFloat { r == 0 ? 0 : margin }
        func trail(_ r: Int) -> CGFloat { r == rows.count - 1 ? 0 : margin }
        // The spacing that fills the fullest row exactly.
        let fills = rows.enumerated().compactMap { r, row -> CGFloat? in
            guard row.count > 1 else { return nil }
            let used = row.reduce(0) { $0 + sizes[$1].width }
            return (bounds.width - lead(r) - trail(r) - used) / CGFloat(row.count - 1)
        }
        let space = max(gap, fills.min() ?? gap)
        var y = bounds.minY
        for (r, row) in rows.enumerated() {
            let height = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX + lead(r)
            for i in row {
                // The flow's last item, OUT, ends the last row at the right-hand edge.
                if i == sizes.count - 1, row.count > 1 { x = bounds.maxX - sizes[i].width }
                subviews[i].place(
                    at: CGPoint(x: x, y: y + height / 2), anchor: .leading, proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + space
            }
            y += height + rowGap
        }
    }

    /// The width of `items` side by side, `gap` apart.
    private func span(_ items: [Int], _ sizes: [CGSize]) -> CGFloat {
        items.reduce(0) { $0 + sizes[$1].width } + gap * CGFloat(max(items.count - 1, 0))
    }

    /// One row if everything fits; else the rows that the narrowest limit needing no more rows than `width` does
    /// gives, which comes out as even as the items allow.
    private func rows(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        guard !sizes.isEmpty else { return [] }
        if span(Array(sizes.indices), sizes) <= width { return [Array(sizes.indices)] }
        let fewest = breakRows(sizes, limit: width).count
        var low = sizes.map(\.width).max() ?? 0
        var high = width
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if breakRows(sizes, limit: mid).count <= fewest { high = mid } else { low = mid }
        }
        return breakRows(sizes, limit: high)
    }

    /// Fills rows in order within `limit`, less the margins a wrapped row keeps: a row that holds everything left is
    /// the last, and needs none at its end.
    private func breakRows(_ sizes: [CGSize], limit: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var row: [Int] = []
        for i in sizes.indices {
            let lead = rows.isEmpty ? 0 : margin
            let start = row.first ?? i
            let rest = span(Array(start..<sizes.count), sizes)
            let trail = lead + rest <= limit ? 0 : margin
            if row.isEmpty || lead + span(row + [i], sizes) + trail <= limit {
                row.append(i)
            } else {
                rows.append(row)
                row = [i]
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}

/// The wire through the flow's items, in order: straight between items on one row; from a row's end, round its right
/// edge, back along the gap below it, and round the left edge into the next row. It stops at each item's edges, and
/// short of the IN and OUT words, unless `continuous` (Pure's bypass), when it runs on behind the capsules.
private struct FlowWire: Shape {
    var items: [CGRect]
    var turn: CGFloat
    var continuous: Bool
    /// The space kept between the wire and the IN and OUT words.
    private let terminalPad: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard items.count > 1 else { return p }
        let last = items.count - 1
        p.move(to: CGPoint(x: items[0].maxX + terminalPad, y: items[0].midY))
        for i in 1...last {
            let a = items[i - 1]
            let b = items[i]
            if b.midY - a.midY > 1 {
                // The return: right, down, back left along the gap between the rows, down, and on into the row.
                let right = rect.maxX - 0.75
                let left = rect.minX + 0.75
                let mid = (a.maxY + b.minY) / 2
                let r = max(min(turn, (mid - a.midY) / 2, (b.midY - mid) / 2), 0)
                p.addLine(to: CGPoint(x: right - r, y: a.midY))
                p.addQuadCurve(to: CGPoint(x: right, y: a.midY + r), control: CGPoint(x: right, y: a.midY))
                p.addLine(to: CGPoint(x: right, y: mid - r))
                p.addQuadCurve(to: CGPoint(x: right - r, y: mid), control: CGPoint(x: right, y: mid))
                p.addLine(to: CGPoint(x: left + r, y: mid))
                p.addQuadCurve(to: CGPoint(x: left, y: mid + r), control: CGPoint(x: left, y: mid))
                p.addLine(to: CGPoint(x: left, y: b.midY - r))
                p.addQuadCurve(to: CGPoint(x: left + r, y: b.midY), control: CGPoint(x: left, y: b.midY))
            }
            p.addLine(to: CGPoint(x: i == last ? b.minX - terminalPad : b.minX, y: b.midY))
            guard i < last else { break }
            if continuous {
                p.addLine(to: CGPoint(x: b.maxX, y: b.midY))
            } else {
                p.move(to: CGPoint(x: b.maxX, y: b.midY))
            }
        }
        return p
    }
}

/// The flow capsules' press: a slight dim while held, and no dimming of its own when disabled.
private struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A flow capsule's name, state and id, for VoiceOver and the UI tests.
private struct CapsuleAccessibility: ViewModifier {
    let block: SoundBlock
    let settings: SoundSettings

    func body(content: Content) -> some View {
        let state = block.spokenState(in: settings)
        content
            .accessibilityLabel(block.name)
            .accessibilityValue(state + (settings.pure ? ", bypassed by Pure" : ""))
            .accessibilityIdentifier("block-\(block.name)")
    }
}

// MARK: EQ controls

/// The EQ's mode and its presets. Picking a preset loads it into the graphic EQ and switches the EQ on.
struct EQControlsRow: View {
    let eq: EQSettings
    let store: SoundStore
    let theme: Theme

    private var presetName: String { SoundStore.presetName(for: eq.graphicGainsDb) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                modePicker.fixedSize()
                Spacer(minLength: 0)
                presets
            }
            VStack(alignment: .leading, spacing: 10) {
                modePicker
                presets
            }
        }
        // The separator below runs the full width, rather than from the first text the List finds in the row.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    private var modePicker: some View {
        Picker("Mode", selection: store.binding(\.eq.mode)) {
            Text("Graphic").tag(EQMode.graphic)
            Text("Parametric").tag(EQMode.parametric)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("eqModePicker")
    }

    private var presets: some View {
        Menu {
            Section("Graphic presets") {
                ForEach(EQPresets.all, id: \.name) { preset in
                    Button {
                        store.applyPreset(preset.name)
                    } label: {
                        if eq.mode == .graphic, preset.name == presetName {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }
            // Only into an empty band list, so it never overwrites bands already made.
            if eq.mode == .graphic, eq.bands.isEmpty {
                Button("Edit as Parametric Bands", systemImage: "slider.horizontal.3") {
                    store.copyGraphicToBands()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(eq.mode == .graphic ? presetName : "Presets")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.ink)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Preset, \(eq.mode == .graphic ? presetName : "none")")
        .accessibilityIdentifier("eqPresetMenu")
    }
}
