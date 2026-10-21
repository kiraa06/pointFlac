import PFAudio
import PFCore
import PFDSP
import SwiftUI

/// The Sound tab (spec §4.8), laid out like a pro tool: the Pure master switch, the signal flow with a capsule per
/// block, the output meter and its clip LED, then each block in chain order with its own switch.
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isMonochrome) private var mono
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedBand: Int?
    @State private var curve = EQCurveModel()
    @State private var meters = MeterBallistics()
    @State private var visible = false
    /// Playback has been stopped long enough for the meters to fall back to rest (see `meterIdleDelay`).
    @State private var metersIdle = false

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
                list(s)
                    .onAppear { scrollForScreenshots(proxy) }
            }
            .navigationTitle("Sound")
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

    private func list(_ s: SoundSettings) -> some View {
        List {
            Section {
                PureSwitch(settings: s, theme: theme) { store.setPure($0) }
            }
            .listRowBackground(glass)
            Section {
                SignalFlowRow(settings: s, theme: theme) { block in
                    store.setBlock(block, on: !block.isOn(in: s))
                }
                OutputMeter(meters: meters, player: player, theme: screen, polling: polling)
                    .listRowInsets(Self.screenInsets)
            } header: {
                header("Signal flow")
            } footer: {
                footerText(s.pure ? "Pure sends the signal straight through." : "Tap a block to switch it.")
            }
            .listRowBackground(glass)
            ForEach(SoundBlock.allCases) { block in
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

    /// `-PFSoundScrollTo eq|tone|crossfeed|limiter` (DEBUG only) opens scrolled to that block, for screenshots.
    private func scrollForScreenshots(_ proxy: ScrollViewProxy) {
        #if DEBUG
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

    @ViewBuilder
    private func section(_ block: SoundBlock, _ s: SoundSettings) -> some View {
        Section {
            Group {
                BlockHeaderRow(block: block, settings: s, theme: theme) { store.setBlock(block, on: $0) }
                    .pureDimmed()
                    .id(block)
                switch block {
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

    /// Frosted glass over the record's light, as the deck's plinth is.
    private var glass: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(theme.plinthTop.opacity(theme.isDark ? 0.5 : 0.55))
        }
    }

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
            eq: eq, bandIDs: bandIDs, curve: model.curve, headroomDb: autoHeadroom ? model.headroomDb : nil,
            sampleRate: sampleRate,
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

/// The chain as a row of capsules, IN to OUT. Each switchable block's capsule toggles it; the limiter's shows whether
/// it runs. In Pure one green line runs straight from IN to OUT behind the capsules, which are ghosted, all alike, and
/// inert. The row scrolls sideways when Part B's blocks make it wider than the screen.
struct SignalFlowRow: View {
    let settings: SoundSettings
    let theme: Theme
    let toggle: (SoundBlock) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(wireWidth: nil)
            ScrollView(.horizontal) {
                row(wireWidth: 14)
                    .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signal flow")
    }

    private func row(wireWidth: CGFloat?) -> some View {
        HStack(spacing: 0) {
            terminal("IN")
            ForEach(SoundBlock.allCases) { block in
                wire(wireWidth)
                capsule(block)
            }
            wire(wireWidth)
            terminal("OUT")
        }
        .background {
            if settings.pure {
                // The bypass: one unbroken line from IN to OUT, passing behind every block.
                Rectangle()
                    .fill(theme.ok)
                    .frame(height: 2)
                    .padding(.horizontal, 22)
                    .accessibilityHidden(true)
            }
        }
    }

    private func terminal(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .tracking(1)
            .foregroundStyle(theme.inkSecondary)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func wire(_ width: CGFloat?) -> some View {
        Rectangle()
            .fill(settings.pure ? Color.clear : theme.inkSecondary.opacity(0.45))
            .frame(minWidth: width ?? 8, idealWidth: width ?? 8, maxWidth: width ?? .infinity)
            .frame(height: 1.5)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func capsule(_ block: SoundBlock) -> some View {
        if block.isSwitchable {
            Button {
                toggle(block)
            } label: {
                capsuleFace(block)
            }
            // A style of its own, so a disabled capsule is not dimmed a second time: Pure ghosts them all alike.
            .buttonStyle(CapsuleButtonStyle())
            .disabled(settings.pure)
            .accessibilityAddTraits(.isToggle)
            .modifier(CapsuleAccessibility(block: block, settings: settings))
        } else {
            // The limiter's capsule only reports: it has no switch, so it is not a button.
            capsuleFace(block)
                .accessibilityElement(children: .ignore)
                .modifier(CapsuleAccessibility(block: block, settings: settings))
        }
    }

    private func capsuleFace(_ block: SoundBlock) -> some View {
        let on = block.isOn(in: settings)
        let active = block.isActive(in: settings)
        let tint = theme.processingTint
        let pure = settings.pure
        return HStack(spacing: 4) {
            Text(block.name.uppercased())
            if !block.isSwitchable {
                Text("AUTO").font(.caption2.monospaced().weight(.bold)).textScale(.secondary).opacity(0.75)
            }
        }
        .font(.caption2.monospaced().weight(.semibold))
        .tracking(0.3)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .foregroundStyle(pure ? theme.inkSecondary : active ? theme.background : on ? tint : theme.inkSecondary)
        // Under Pure the ghost is opaque, so the bypass line reads as passing behind it.
        .background(Capsule().fill(pure ? theme.plinthTop : active ? tint : Color.clear))
        .overlay(
            Capsule().strokeBorder(
                pure ? theme.inkSecondary.opacity(0.5) : active ? Color.clear : on ? tint : theme.hairline,
                style: StrokeStyle(lineWidth: 1, dash: pure ? [3, 2] : []))
        )
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
        let state =
            block.isSwitchable
            ? (block.isOn(in: settings) ? "On" : "Off") : (block.isActive(in: settings) ? "Running" : "Standby")
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
