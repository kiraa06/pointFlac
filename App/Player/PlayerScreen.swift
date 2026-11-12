import PFAudio
import PFCore
import PFDesign
import SwiftUI
import UniformTypeIdentifiers

/// Which stage the player shows (spec §4.2): the glass turntable or the editorial cover.
enum PlayerStage: String, CaseIterable {
    case deck, cover
}

/// The player, home of the app (spec §4.1): the Deck/Cover switch, the stage, the shared elements under it, and the
/// Shelf, which rises over it. The Shelf lives here rather than in a system sheet so that the crate → deck hand-off
/// can carry a record across both in one coordinate space.
struct PlayerScreen: View {
    let model: AppModel
    @Binding var tab: AppTab
    @AppStorage("playerView") private var stage: PlayerStage = .deck
    @AppStorage("monochrome") private var monochrome = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shelfOpen = false
    /// A finger moving the shelf (`ShelfDrag`): the panel follows it, and settles only when it lifts.
    @State private var shelfDrag: ShelfDrag?
    /// The shelf is settling closed after a drag: it stays on screen until it is out of sight.
    @State private var shelfSettling = false
    @State private var upNextOpen = false
    @State private var importing = false
    /// The deck's display unfolded into the tracklist (plan 9 §3).
    @State private var deckTracklistOpen = false
    /// The stage's frame in the player's space: the hole in the tap-catcher that folds the deck's tracklist back.
    @State private var stageFrame: CGRect = .zero
    @State private var handoff = HandoffDirector()
    /// The playlists, for the strip, the heart, the menus and their sheets.
    @State private var desk: PlaylistDesk
    @Namespace private var discSpace

    init(model: AppModel, tab: Binding<AppTab>) {
        self.model = model
        _tab = tab
        _desk = State(initialValue: PlaylistDesk(library: model.library, playback: model.playback))
    }

    private var playback: PlaybackController { model.playback }
    private var theme: Theme { .look(stage: stage, dark: scheme == .dark, monochrome: monochrome) }
    /// What tints the glass: the record's colours, in greys under Monochrome (the sleeve and art keep theirs). A
    /// playlist lights the deck in its pressing colour; on the cover, the wash follows the album of the song the cover
    /// shows (`cuedSong`: the one playing or, needle up, the one that would play).
    private var palette: ArtPalette {
        if stage == .cover, playback.album?.pressing != nil, let album = playback.cuedSong?.albumID {
            return ArtPalette(seed: album).tint(for: theme)
        }
        return ArtPalette.record(playback.record).tint(for: theme)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let metrics = ShelfMetrics(proxy)
            ZStack(alignment: .top) {
                background(width: width)
                VStack(spacing: 0) {
                    StageSwitch(stage: $stage, theme: theme)
                        .padding(.top, 6)
                        // Clear of the plinth: the switch floats above the stage, it does not sit on it.
                        .padding(.bottom, Self.switchGap)
                    stageView(width: width)
                        .frame(height: stageHeight(proxy.size))
                    SharedControls(
                        playback: playback, theme: theme, upNextOpen: $upNextOpen,
                        hidden: handoff.hidesTitle, libraryEmpty: model.library.albums.isEmpty,
                        addFromFiles: { importing = true }, getMusic: { tab = .getMusic }, openSound: { tab = .sound })
                    Spacer(minLength: 0)
                    shelfPeek
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                // Not while the deck's tracklist is unfolded: the stage is all its scrolling list then, and a drag
                // up on it is the list's (off the stage, the fold catcher takes every touch).
                .modifier(
                    ShelfDragArea(minimumDistance: 30, enabled: !deckTracklistOpen, actions: openingDrag(metrics)))
                if deckTracklistOpen {
                    foldCatcher
                }
                if shelfOpen || shelfDrag != nil || shelfSettling || handoff.isRunning {
                    shelf(proxy.size, metrics)
                }
                if handoff.isRunning {
                    // Above the shelf (zIndex 2): the sleeve lifts and the record leaves it in plain sight.
                    HandoffOverlay(director: handoff, palette: handoff.palette)
                        .allowsHitTesting(true)
                        .onTapGesture { finishHandoff() }
                        .zIndex(3)
                }
            }
            .coordinateSpace(.named(PlayerSpace.name))
            .playlistSheets(desk) { album, track in playFromSheet(album, track: track) }
        }
        .environment(desk)
        .onAppear {
            #if DEBUG
                // `-PFOpenShelf`: opens on the shelf, for screenshots.
                if ProcessInfo.processInfo.arguments.contains("-PFOpenShelf") { shelfOpen = true }
                // `-PFShelfHold <points>`: holds the open shelf that far down, as a finger would mid-drag, for
                // screenshots.
                if UserDefaults.standard.object(forKey: "PFShelfHold") != nil {
                    shelfOpen = true
                    shelfDrag = ShelfDrag(
                        startsOpen: true, translation: CGFloat(UserDefaults.standard.double(forKey: "PFShelfHold")))
                }
                // `-PFStage deck|cover`: starts on that stage. Not `-playerView`, which would pin the setting: the
                // argument domain outranks what the switch writes.
                if let value = UserDefaults.standard.string(forKey: "PFStage"), let start = PlayerStage(rawValue: value)
                {
                    stage = start
                }
                // `-PFDemoPlaylists`, `-PFPlayPlaylist`: the demo playlists, and one on the deck.
                Task { await desk.prepareForLaunch() }
            #endif
        }
        .fileImporter(
            isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "flac") ?? .audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { _ = await model.library.importFiles(urls) }
            }
        }
        .sheet(isPresented: $upNextOpen) {
            UpNextSheet(playback: playback)
                .presentationDetents([.medium, .large])
        }
        #if DEBUG
            .task {
                // `-PFTracklist deck`: unfolds the deck's display once a record plays, for screenshots.
                guard UserDefaults.standard.string(forKey: "PFTracklist") == "deck" else { return }
                for _ in 0..<100 where playback.trackIndex == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(DeckTracklist.animation(reduceMotion: reduceMotion)) { deckTracklistOpen = true }
            }
        #endif
    }

    // MARK: Pieces

    @ViewBuilder
    private func background(width: CGFloat) -> some View {
        ZStack {
            theme.background
            if stage == .deck {
                // Pastel light behind the glass, taken from the record.
                Circle().fill(palette.base.opacity(theme.glow)).frame(width: width * 1.0).blur(radius: 60)
                    .offset(x: -width * 0.35, y: -width * 0.2)
                Circle().fill(palette.sea.opacity(theme.glow)).frame(width: width * 0.9).blur(radius: 60)
                    .offset(x: width * 0.4, y: width * 0.25)
            } else {
                // The cover's wash, from the art's colours.
                RadialGradient(
                    colors: [palette.base.opacity(theme.glow), .clear], center: UnitPoint(x: 0.3, y: 0.18),
                    startRadius: 0, endRadius: width * 0.9)
                RadialGradient(
                    colors: [palette.sea.opacity(theme.glow * 0.85), .clear], center: UnitPoint(x: 0.85, y: 0.55),
                    startRadius: 0, endRadius: width * 0.85)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: playback.album?.id)
    }

    @ViewBuilder
    private func stageView(width: CGFloat) -> some View {
        ZStack {
            if stage == .deck {
                DeckStage(
                    playback: playback, theme: theme, handoff: handoff, discSpace: discSpace,
                    tracklistOpen: $deckTracklistOpen
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                CoverStage(playback: playback, theme: theme, discSpace: discSpace)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(PlayerSpace.name))
        } action: { frame in
            stageFrame = frame
        }
        .padding(.horizontal, 12)
    }

    /// While the deck's tracklist is unfolded, a tap anywhere off the stage folds it back and reaches nothing under
    /// it (the stage itself folds it on a tap beside the panel).
    private var foldCatcher: some View {
        Color.clear
            .contentShape(StageHole(hole: stageFrame), eoFill: true)
            .onTapGesture {
                withAnimation(DeckTracklist.animation(reduceMotion: reduceMotion)) { deckTracklistOpen = false }
            }
            .accessibilityHidden(true)
    }

    /// The deck's plinth sets the stage's height; the cover shares it, so switching never moves the controls. The
    /// switch's gap comes out of the same budget, so short screens shrink the stage rather than the controls.
    private func stageHeight(_ size: CGSize) -> CGFloat {
        min(DeckLayout.height(forWidth: size.width - 24), max(260, size.height - 380 - Self.switchGap))
    }

    /// Space between the Deck / Cover switch and the stage below it.
    static let switchGap: CGFloat = 14

    private var shelfPeek: some View {
        Button {
            openShelf()
        } label: {
            Label("Shelf", systemImage: "chevron.up")
                .font(Typeface.monoSmall)
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(theme.inkSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.bottom, 10)
        .accessibilityIdentifier("shelfButton")
        .accessibilityHint("Opens the shelf to browse and search your records")
    }

    private func shelf(_ size: CGSize, _ metrics: ShelfMetrics) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // Just above the panel's edge: with the grabber under it, a 44 pt touch zone.
            ShelfGrabberReach(actions: closingDrag(metrics))
                .offset(y: shelfOffset(size, metrics))
            ShelfPanel(
                library: model.library, finder: model.finder, playback: playback, theme: theme,
                close: { withAnimation(.spring(duration: 0.45)) { shelfOpen = false } },
                getMusic: { tab = .getMusic },
                hidesFront: handoff.isRunning,
                pick: { album, track, frontRect in
                    startHandoff(album, track: track, from: frontRect, sinkDistance: size.height)
                }
            )
            .environment(\.shelfGrabberDrag, closingDrag(metrics))
            .frame(height: metrics.height)
            .offset(y: shelfOffset(size, metrics))
        }
        .transition(.move(edge: .bottom))
        .zIndex(2)
    }

    /// Where the shelf sits, down from open: sunk away by the hand-off, under a finger, settling closed after a drag,
    /// or open (the button and the close action move it by its transition).
    private func shelfOffset(_ size: CGSize, _ metrics: ShelfMetrics) -> CGFloat {
        if handoff.isRunning { return handoff.shelfOffset(size.height) }
        if let shelfDrag { return metrics.offset(shelfDrag) }
        return shelfSettling && !shelfOpen ? metrics.travel : 0
    }

    private func openShelf() {
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            shelfOpen = true
            shelfSettling = false
        }
    }

    // MARK: Dragging the shelf

    /// Up anywhere on the player while the shelf is closed: it rises from the bottom edge under the finger. The deck's
    /// own drags (the record, the tonearm) and the controls' are the children's, and win; the deck's unfolded
    /// tracklist turns the area off.
    private func openingDrag(_ metrics: ShelfMetrics) -> ShelfDragActions {
        ShelfDragActions(
            accepts: { move in move.height < 0 && !shelfOpen && shelfDrag == nil && !handoff.isRunning },
            changed: { moveShelf($0) },
            ended: { settleShelf(velocity: $0, metrics) })
    }

    /// The grabber, either way: down it lowers the shelf under the finger, up it stretches.
    private func closingDrag(_ metrics: ShelfMetrics) -> ShelfDragActions {
        ShelfDragActions(
            accepts: { _ in shelfOpen && shelfDrag == nil && !handoff.isRunning },
            changed: { moveShelf($0) },
            ended: { settleShelf(velocity: $0, metrics) })
    }

    /// The finger moved: the panel goes with it, at once.
    private func moveShelf(_ translation: CGFloat) {
        if shelfDrag == nil {
            shelfDrag = ShelfDrag(startsOpen: shelfOpen, translation: translation)
        } else {
            shelfDrag?.translation = translation
        }
    }

    /// The finger lifted: the shelf settles open or closed (`ShelfTravel`), from where the finger left it and at the
    /// finger's speed. Under Reduce Motion, a short ease instead of a spring. Settling closed, it stays on screen until
    /// it is out of sight.
    private func settleShelf(velocity: CGFloat, _ metrics: ShelfMetrics) {
        guard let shelfDrag else { return }
        let offset = metrics.offset(shelfDrag)
        let open = ShelfTravel.settlesOpen(offset: offset, velocity: velocity, travel: metrics.travel)
        let target = open ? 0 : metrics.travel
        if !open, abs(offset - target) < 0.5 {
            // Already out of sight: there is nothing to animate, so no completion would come to clear the settle.
            self.shelfDrag = nil
            shelfOpen = false
            shelfSettling = false
            return
        }
        let animation: Animation =
            reduceMotion
            ? .easeOut(duration: 0.22)
            : .interpolatingSpring(
                Spring(duration: 0.45, bounce: open ? 0.12 : 0),
                initialVelocity: ShelfTravel.springVelocity(offset: offset, target: target, velocity: velocity))
        withAnimation(animation, completionCriteria: .removed) {
            self.shelfDrag = nil
            shelfOpen = open
            shelfSettling = !open
        } completion: {
            if !shelfOpen, self.shelfDrag == nil { shelfSettling = false }
        }
    }

    // MARK: The hand-off

    private func startHandoff(_ album: AlbumCard, track: TrackRow.ID?, from rect: CGRect?, sinkDistance: CGFloat) {
        if reduceMotion || rect == nil || handoff.platterRect == .zero {
            // Reduce Motion (spec §4.5): a short cross-fade instead.
            withAnimation(.easeInOut(duration: 0.25)) { shelfOpen = false }
            Task { await playback.load(album, startingAt: track) }
            return
        }
        handoff.start(
            album: album, track: track, from: rect ?? .zero, sinkDistance: sinkDistance, playback: playback
        ) {
            shelfOpen = false
        }
    }

    private func finishHandoff() {
        handoff.finishNow()
        shelfOpen = false
    }

    /// Play in a playlist's sheet: the sheet and the shelf close, and the record settles onto the platter (the deck's
    /// short arrival), as a record pulled from Up Next does.
    private func playFromSheet(_ album: AlbumCard, track: TrackRow.ID?) {
        withAnimation(.spring(duration: 0.45)) { shelfOpen = false }
        Task { await playback.load(album, startingAt: track) }
    }
}

/// The player's coordinate space, which the hand-off measures the sleeve and the platter in.
enum PlayerSpace {
    static let name = "player"
}

/// The whole player but the stage, filled even-odd: the fold catcher's touch area.
private struct StageHole: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(hole)
        return path
    }
}

/// The Deck / Cover switch at the top: a Liquid Glass capsule with two segments.
struct StageSwitch: View {
    @Binding var stage: PlayerStage
    let theme: Theme

    var body: some View {
        HStack(spacing: 2) {
            segment(.deck, "Deck")
            segment(.cover, "Cover")
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private func segment(_ value: PlayerStage, _ title: String) -> some View {
        Button {
            withAnimation(.spring(duration: 0.5, bounce: 0.15)) { stage = value }
        } label: {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.8)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .foregroundStyle(stage == value ? (theme.isDark ? Color.black : Color.black) : theme.inkSecondary)
                .background {
                    if stage == value {
                        Capsule().fill(.white).shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(value == .deck ? "stageDeck" : "stageCover")
        .accessibilityAddTraits(stage == value ? .isSelected : [])
    }
}
