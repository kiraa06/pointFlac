import PFCore
import PFDesign
import SwiftUI

/// The shelf's Playlists strip (spec §4): headed "Playlists", a dashed New disc, then Favourites and the other
/// playlists in the order they were made, each its pressing at 60 pt with its name and song count under it. A tap
/// plays a playlist with songs (its disc flies to the deck) and opens an empty one; a hold offers Play, Play Next,
/// Add to Up Next, Open Playlist and, but for Favourites, Delete Playlist…. About 96 pt tall; at the accessibility
/// text sizes the names wrap to two lines and the strip grows.
struct PlaylistStrip: View {
    let desk: PlaylistDesk
    let theme: Theme
    /// The playlist whose disc the hand-off is flying: not drawn meanwhile, so there is never a double.
    var hidden: PlaylistCard.ID?
    /// Over the galaxy, a hold asks in a dialog, as a galaxy sleeve's does: a context menu in the same window holds
    /// back the galaxy's own touches, so its sleeves could no longer be dragged.
    var holdsInDialog = false
    /// Plays a playlist, from its disc's frame in the player's space.
    let play: (PlaylistCard, CGRect?) -> Void
    @Environment(\.playlistRouter) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var deleting: PlaylistCard?

    private var itemWidth: CGFloat { typeSize.isAccessibilitySize ? 150 : 72 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Playlists")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    newDisc
                    ForEach(desk.playlists) { card in
                        PlaylistStripItem(
                            card: card, desk: desk, theme: theme, hidden: hidden == card.id, width: itemWidth,
                            holdsInDialog: holdsInDialog, play: { play(card, $0) }, delete: { deleting = card })
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
        // The names wrap to two lines, and the strip grows, up to the second accessibility size; past it they would
        // break mid-word in a disc's width.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        // The press-in's soft impact, as a new disc arrives.
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.8), trigger: desk.presses)
        .confirmationDialog(
            deleting?.name ?? "", isPresented: deletingAsked, titleVisibility: .visible, presenting: deleting
        ) { card in
            Button("Delete Playlist", role: .destructive) { desk.delete(card.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Deletes this playlist. The songs stay in your library.")
        }
    }

    private var deletingAsked: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    /// New: a dashed circle with a plus, where a disc would be.
    private var newDisc: some View {
        Button {
            router.open(.create)
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(theme.ink.opacity(0.04))
                    Circle().strokeBorder(theme.ink.opacity(0.42), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.ink.opacity(0.85))
                }
                .frame(width: 60, height: 60)
                .padding(.top, 2)
                .padding(.bottom, 6)
                Text("New").font(.caption)
                    .foregroundStyle(theme.ink)
            }
            .frame(width: itemWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(DiscPress())
        .accessibilityLabel("New Playlist")
        .accessibilityIdentifier("newPlaylistButton")
    }
}

/// One playlist in the strip: its disc, name and count. A playlist just made waits hidden until its sheet has gone,
/// then presses in: from 0.85 to full size on a spring with one small overshoot, its label printed 80 ms later; under
/// Reduce Motion it only fades in.
private struct PlaylistStripItem: View {
    let card: PlaylistCard
    let desk: PlaylistDesk
    let theme: Theme
    let hidden: Bool
    let width: CGFloat
    let holdsInDialog: Bool
    let play: (CGRect?) -> Void
    let delete: () -> Void
    /// The hold's dialog is up (over the galaxy).
    @State private var holding = false
    @Environment(\.playlistRouter) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isMonochrome) private var mono
    /// The disc's frame in the player's space, where the hand-off picks it up.
    @State private var frame: CGRect?
    @State private var scale = 1.0
    @State private var opacity = 1.0
    /// Over the label while the disc presses in: plain vinyl, lifting as the label is printed.
    @State private var veil = 0.0
    @State private var captions = 1.0

    private var empty: Bool { card.songCount == 0 }

    var body: some View {
        Button {
            if empty { router.open(.open(card.id)) } else { play(frame) }
        } label: {
            VStack(spacing: 0) {
                disc
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                VStack(spacing: 0) {
                    Text(card.name)
                        .font(.caption)
                        .foregroundStyle(theme.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(typeSize.isAccessibilitySize ? 0.8 : 1)
                        .multilineTextAlignment(.center)
                    Text(card.countText)
                        .font(.caption2)
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .opacity(captions)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(DiscPress())
        .modifier(HoldMenu(inDialog: holdsInDialog, title: card.name, holding: $holding) { menu(dialog: $0) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityHint(empty ? "Opens the playlist" : "Plays on the deck")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("playlistDisc-\(card.id)")
        // The hold's items, for VoiceOver, whichever way the hold shows them.
        .accessibilityActions {
            if !empty {
                Button("Play Next") { desk.playback.playNext(card.albumCard) }
                Button("Add to Up Next") { desk.playback.addToUpNext(card.albumCard) }
            }
            Button("Open Playlist") { router.open(.open(card.id)) }
            if !card.isFavourites {
                Button("Delete Playlist…", action: delete)
            }
        }
        .onAppear {
            if desk.awaitingPress == card.id { hide() }
        }
        .onChange(of: desk.awaitingPress) { _, waiting in
            if waiting == card.id { hide() }
        }
        .onChange(of: desk.presses) {
            if desk.pressing == card.id { pressIn() }
        }
    }

    private var disc: some View {
        PressingDisc(look: card.look, size: 60)
            .overlay {
                Circle()
                    .fill(Color(PressingRGB(card.colour.hex).mixed(with: .black, 0.45), opacity: 1))
                    .frame(width: 60 * VinylGeometry.labelToRecord + 1, height: 60 * VinylGeometry.labelToRecord + 1)
                    .grayscale(mono ? 1 : 0)
                    .opacity(veil)
                    .accessibilityHidden(true)
            }
            .scaleEffect(scale)
            .opacity(hidden ? 0 : opacity)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(PlayerSpace.name))
            } action: {
                frame = $0
            }
    }

    /// The hold's items. A dialog leaves out what an empty playlist can't do; a menu shows it dimmed.
    @ViewBuilder private func menu(dialog: Bool) -> some View {
        if !(dialog && empty) {
            Button("Play", systemImage: "play.fill") { play(frame) }
                .disabled(empty)
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                desk.playback.playNext(card.albumCard)
            }
            .disabled(empty)
            Button("Add to Up Next", systemImage: "text.append") { desk.playback.addToUpNext(card.albumCard) }
                .disabled(empty)
        }
        Button("Open Playlist", systemImage: "music.note.list") { router.open(.open(card.id)) }
        if !card.isFavourites {
            Divider()
            Button("Delete Playlist…", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    private func hide() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            scale = reduceMotion ? 1 : 0.85
            opacity = 0
            veil = reduceMotion ? 0 : 1
            captions = 0
        }
    }

    private func pressIn() {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) {
                opacity = 1
                captions = 1
            }
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { scale = 1 }
        withAnimation(.easeOut(duration: 0.06)) { opacity = 1 }
        withAnimation(.easeOut(duration: 0.18).delay(0.08)) {
            veil = 0
            captions = 1
        }
    }
}

/// A disc under a finger: it gives a little, like a record lifted from the shelf.
struct DiscPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// A hold's items: a context menu, or (`inDialog`) a dialog opened by a long press, with the hold's impact. A tap
/// still reaches the button: the long press fails first.
private struct HoldMenu<Items: View>: ViewModifier {
    let inDialog: Bool
    let title: String
    @Binding var holding: Bool
    @ViewBuilder let items: (_ dialog: Bool) -> Items

    func body(content: Content) -> some View {
        if inDialog {
            content
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in holding = true })
                .sensoryFeedback(.impact(weight: .medium), trigger: holding) { _, now in now }
                .confirmationDialog(title, isPresented: $holding, titleVisibility: .visible) { items(true) }
        } else {
            content.contextMenu { items(false) }
        }
    }
}
