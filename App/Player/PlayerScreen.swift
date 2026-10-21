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
    @State private var upNextOpen = false
    @State private var importing = false
    @State private var handoff = HandoffDirector()
    @Namespace private var discSpace

    private var playback: PlaybackController { model.playback }
    private var theme: Theme { .look(stage: stage, dark: scheme == .dark, monochrome: monochrome) }
    /// What tints the glass: the record's colours, in greys under Monochrome (the sleeve and art keep theirs).
    private var palette: ArtPalette { ArtPalette(seed: playback.album?.id ?? "pointflac").tint(for: theme) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
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
                        addFromFiles: { importing = true }, getMusic: { tab = .getMusic })
                    Spacer(minLength: 0)
                    shelfPeek
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(swipeUp)
                if shelfOpen || handoff.isRunning {
                    shelf(proxy.size)
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
        }
        .onAppear {
            #if DEBUG
                // `-PFOpenShelf`: opens on the shelf, for screenshots.
                if ProcessInfo.processInfo.arguments.contains("-PFOpenShelf") { shelfOpen = true }
                // `-PFStage deck|cover`: starts on that stage. Not `-playerView`, which would pin the setting: the
                // argument domain outranks what the switch writes.
                if let value = UserDefaults.standard.string(forKey: "PFStage"), let start = PlayerStage(rawValue: value)
                {
                    stage = start
                }
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
                DeckStage(playback: playback, theme: theme, handoff: handoff, discSpace: discSpace)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                CoverStage(playback: playback, theme: theme, discSpace: discSpace)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .padding(.horizontal, 12)
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

    private func shelf(_ size: CGSize) -> some View {
        VStack {
            Spacer(minLength: 0)
            ShelfPanel(
                library: model.library, finder: model.finder, playback: playback, theme: theme,
                close: { withAnimation(.spring(duration: 0.45)) { shelfOpen = false } },
                getMusic: { tab = .getMusic },
                hidesFront: handoff.isRunning,
                pick: { album, track, frontRect in
                    startHandoff(album, track: track, from: frontRect, sinkDistance: size.height)
                }
            )
            .frame(height: size.height * 0.74)
            .offset(y: handoff.isRunning ? handoff.shelfOffset(size.height) : 0)
        }
        .transition(.move(edge: .bottom))
        .zIndex(2)
    }

    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.height < -60, abs(value.translation.width) < 80, !shelfOpen {
                openShelf()
            }
        }
    }

    private func openShelf() {
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) { shelfOpen = true }
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
}

/// The player's coordinate space, which the hand-off measures the sleeve and the platter in.
enum PlayerSpace {
    static let name = "player"
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
