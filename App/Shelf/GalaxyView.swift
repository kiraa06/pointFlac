import PFCore
import PFDesign
import SwiftUI

/// The Shelf's Galaxy mode (spec §2): every album a solid sleeve, the top of the sort biggest in the middle, the rest
/// smaller outward, all drifting slowly over a glow in the centre album's colours. Drag a sleeve to shove the others
/// (it stays where it is dropped), drag empty space to look around, pinch to zoom, tap to play, hold for the crate's
/// actions (`holdActions`, shown in a dialog over the held sleeve).
///
/// Why one `Canvas` with symbols rather than a view per sleeve: hundreds of positioned views would each be laid out
/// and diffed every frame, which 120 Hz cannot afford. The canvas resolves each sleeve once, as a symbol, and a frame
/// only draws those symbols where `GalaxyModel` says they are.
struct GalaxyView<HoldActions: View>: View {
    /// In rank order.
    let albums: [AlbumCard]
    let sort: AlbumSort
    /// Most played had no listens to go by and ordered the albums by Last added.
    let fellBack: Bool
    let theme: Theme
    /// The album the hand-off is flying: not drawn, so there is never a double.
    var hidden: AlbumCard.ID?
    /// A tap: the album and its sleeve's frame in the player's space, for the hand-off.
    let pick: (AlbumCard, CGRect) -> Void
    let playNext: (AlbumCard) -> Void
    let addToUpNext: (AlbumCard) -> Void
    /// The held sleeve's menu, for its album and its frame in the player's space (Play hands off from there).
    @ViewBuilder let holdActions: (AlbumCard, CGRect) -> HoldActions

    @State private var model = GalaxyModel()
    /// The sleeve held for its menu, with its frame in the area and in the player's space.
    @State private var held: Held?
    /// Bumped by each hold, for its haptic.
    @State private var holds = 0

    /// The fallback note's height, measured: at the largest text sizes it runs to several lines.
    @State private var noteHeight: CGFloat = 0
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The side every sleeve symbol is rendered at: the core's, so the biggest sleeve is drawn at its own size.
    private static var symbolSide: CGFloat { GalaxyModel.metrics.coreSide }
    /// Space the galaxy keeps clear at its top: the note's, when it shows.
    private var clearTop: CGFloat { fellBack ? noteHeight : 0 }

    var body: some View {
        ZStack(alignment: .top) {
            // Opaque, unlike the rest of the panel: the player's own text must not show through the glow.
            theme.shelfSurface
            GalaxyGlow(album: albums.first, theme: theme)
            sky
            if fellBack {
                Text("No listening history yet. Sized by Last added.")
                    .font(.footnote)
                    .foregroundStyle(theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    // Where large text leaves too little room and sleeves pass under it, the note still reads.
                    .background {
                        LinearGradient(
                            stops: [
                                .init(color: theme.shelfSurface, location: 0),
                                .init(color: theme.shelfSurface.opacity(0.9), location: 0.75),
                                .init(color: theme.shelfSurface.opacity(0), location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                    }
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: { height in
                        noteHeight = height
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("galaxyFallbackNote")
            }
            holdAnchor
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(PlayerSpace.name))
        } action: { frame in
            model.place(frame: frame, topInset: clearTop)
        }
        .onChange(of: clearTop) { _, now in model.keepClear(top: now) }
        // A new order (a sort, a filter, albums added or deleted) re-forms the galaxy; the first is its entrance.
        .onChange(of: LayoutKey(ids: albums.map(\.id), sort: sort), initial: true) { old, new in
            model.arrange(albums, fresh: old == new, reduceMotion: reduceMotion)
        }
        .onChange(of: albums) { model.refresh(albums) }
        .onChange(of: touching) { _, now in
            if !now { model.touchFinished(time: .now) }
        }
        .task(id: model.pressToken) {
            let token = model.pressToken
            guard token != 0 else { return }
            try? await Task.sleep(for: .seconds(GalaxyModel.holdDelay))
            guard !Task.isCancelled, let found = model.hold(token: token, time: .now) else { return }
            holds += 1
            held = Held(album: found.album, local: found.local, rect: found.rect)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: holds)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: model.pickUps)
    }

    // MARK: Holding

    /// Where the hold's dialog points from: an empty frame over the held sleeve, there before any hold, so the dialog
    /// has a view to present from the moment it is asked for.
    private var holdAnchor: some View {
        let rect = held?.local ?? .zero
        return Color.clear
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .padding(.leading, max(rect.minX, 0))
            .padding(.top, max(rect.minY, 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .confirmationDialog(
                held?.album.title ?? "", isPresented: holdAsked, titleVisibility: .visible, presenting: held
            ) { held in
                holdActions(held.album, held.rect)
            }
    }

    private var holdAsked: Binding<Bool> {
        Binding(get: { held != nil }, set: { if !$0 { held = nil } })
    }

    // MARK: The sky

    /// Under Reduce Motion nothing drifts, so the timeline pauses whenever nothing else moves. Otherwise the idle drift
    /// runs at 30 Hz, and everything else at the screen's full rate: a drifting sleeve moves under 3 pt a second, less
    /// than a tenth of a point a frame at 30 Hz, so the slower clock can't be seen, only saved.
    private var sky: some View {
        let live = model.isLive
        let drift = !reduceMotion
        let hidden = hidden
        let dark = theme.isDark
        return TimelineView(.animation(minimumInterval: live ? nil : 1.0 / 30, paused: reduceMotion && !live)) {
            context in
            let frame = model.frame(at: context.date, drift: drift, hidden: hidden)
            Canvas { context, _ in
                GalaxyRenderer.draw(frame, in: context, dark: dark)
            } symbols: {
                GalaxySymbols(albums: model.symbols, side: Self.symbolSide)
            }
        }
        .contentShape(Rectangle())
        .gesture(drag)
        .simultaneousGesture(magnify)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Galaxy")
        .accessibilityChildren { elements }
        .accessibilityIdentifier("shelfGalaxy")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                // The pressed record's art is decoded now, at the sleeve's and the platter's sizes, so a tap's
                // hand-off has it (spec §4.5: textures are ready before the tap).
                if let album = model.touchChanged(
                    location: value.location, start: value.startLocation, time: value.time)
                {
                    ArtworkLoader.shared.prefetch(album.id, data: album.artwork, pixels: [300, 900])
                }
            }
            .onEnded { value in
                if let tap = model.touchEnded(location: value.location, velocity: value.velocity, time: value.time) {
                    pick(tap.album, tap.rect)
                }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                model.zoomChanged(magnification: value.magnification, anchor: value.startLocation, time: value.time)
            }
            .onEnded { _ in model.zoomEnded() }
    }

    // MARK: Accessibility

    /// One element per album, in rank order, at its resting place (spec §2: VoiceOver reads the albums in sort order).
    private var elements: some View {
        let revision = model.restRevision
        let rects = model.albums.indices.map { model.restingRect(rank: $0) }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(model.albums.enumerated()), id: \.element.id) { rank, album in
                let rect = rects[rank]
                Color.clear
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityElement()
                    .accessibilityLabel("\(album.title), \(album.artist)")
                    .accessibilityValue(Self.value(of: album, sort: sort))
                    .accessibilityHint("Puts the record on the deck")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("galaxy-\(rank)")
                    .accessibilityAction { pick(album, model.playerRect(model.restingRect(rank: rank))) }
                    .accessibilityAction(named: "Play Next") { playNext(album) }
                    .accessibilityAction(named: "Add to Up Next") { addToUpNext(album) }
            }
        }
        .frame(width: model.size.width, height: model.size.height)
        .id(revision)
    }

    /// What the sort orders by, for VoiceOver: plays for Most played, else that sort's own attribute.
    static func value(of album: AlbumCard, sort: AlbumSort) -> String {
        switch sort {
        case .mostPlayed:
            return album.listens == 1 ? "1 play" : "\(album.listens) plays"
        case .recentlyPlayed:
            guard let last = album.lastListened else { return "Not played yet" }
            return "Played \(last.formatted(.relative(presentation: .named)))"
        case .newestRelease:
            return album.year.map { "Released \($0)" } ?? "No release year"
        case .lastAdded:
            return "Added \(album.addedAt.formatted(date: .abbreviated, time: .omitted))"
        case .hiResFirst:
            return album.bestFormat
        }
    }
}

/// A sleeve held for its menu: its frame in the galaxy's area (where the dialog points from) and in the player's space.
private struct Held {
    let album: AlbumCard
    let local: CGRect
    let rect: CGRect
}

/// What a new layout is keyed by: the albums' order, and the sort (a re-sort re-forms the galaxy even when the order
/// happens to be the same, since it discards dropped positions).
private struct LayoutKey: Equatable {
    let ids: [AlbumCard.ID]
    let sort: AlbumSort
}

/// One symbol per album: its sleeve at the core's side, without a shadow (the canvas draws one for all of them).
/// The top ranks decode their art at the crate's size; the small sleeves further out, at about half that.
private struct GalaxySymbols: View {
    let albums: [AlbumCard]
    let side: CGFloat

    var body: some View {
        ForEach(Array(albums.enumerated()), id: \.element.id) { rank, album in
            Sleeve(album: album, shadow: false, pixels: rank < 16 ? 300 : 160)
                .frame(width: side, height: side)
                .tag(album.id)
        }
    }
}

/// Draws a `GalaxyFrame`.
///
/// Why the shadow goes on one layer: a shadow filter on each of hundreds of sleeves would blur hundreds of times a
/// frame. Sleeves never overlap at rest, so one shadow under the layer holding them all looks the same (each sleeve
/// casts its own) and blurs once.
private enum GalaxyRenderer {
    static func draw(_ frame: GalaxyFrame, in context: GraphicsContext, dark: Bool) {
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6))
        shadowed.drawLayer { layer in
            for item in frame.items { draw(item, in: layer, rect: item.rect) }
        }
        guard let raised = frame.raised else { return }
        // The sleeve under the finger: lifted 6% with a deeper shadow and a bright rim, as in the prototype.
        let lift = frame.lift
        let grow = raised.rect.width * GalaxyFrame.liftGrowth * lift
        let rect = raised.rect.insetBy(dx: -grow, dy: -grow)
        var lifted = context
        lifted.addFilter(
            .shadow(color: .black.opacity(0.35 + 0.15 * lift), radius: 10 + 12 * lift, x: 0, y: 6 + 8 * lift))
        lifted.drawLayer { layer in
            draw(raised, in: layer, rect: rect)
            guard lift > 0.01 else { return }
            let corner = 4 * rect.width / GalaxyModel.metrics.coreSide + 1
            let rim = Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: corner, style: .continuous)
            layer.stroke(rim, with: .color(.white.opacity((dark ? 0.6 : 0.9) * lift * raised.opacity)), lineWidth: 1.5)
        }
    }

    private static func draw(_ item: GalaxyFrame.Item, in context: GraphicsContext, rect: CGRect) {
        guard let symbol = context.resolveSymbol(id: item.id) else { return }
        if item.opacity < 0.999 {
            var faded = context
            faded.opacity = item.opacity
            faded.draw(symbol, in: rect)
        } else {
            context.draw(symbol, in: rect)
        }
    }
}

/// The soft light behind the galaxy, in the centre album's colours (greys under Monochrome), as in the prototype: a
/// broad cloud at the middle and a smaller one low on the left, blurred 60 at 0.55. A new centre album cross-fades in
/// over 1.6 s.
private struct GalaxyGlow: View {
    let album: AlbumCard?
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let album {
                    GlowCloud(palette: ArtPalette(seed: album.id).tint(for: theme), size: proxy.size)
                        .id(album.id)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 1.6), value: album?.id)
        }
        // Faded out at the area's edges, so the light has no hard line where the controls end.
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.92), .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlowCloud: View {
    let palette: ArtPalette
    let size: CGSize

    var body: some View {
        let w = size.width
        let h = size.height
        ZStack {
            Ellipse().fill(palette.base)
                .frame(width: w * 0.78, height: h * 0.63)
                .position(x: w * 0.5, y: h * 0.47)
            Ellipse().fill(palette.sea.opacity(0.65))
                .frame(width: w * 0.59, height: h * 0.49)
                .position(x: w * 0.22, y: h * 0.78)
        }
        .frame(width: w, height: h)
        .blur(radius: 60)
        .opacity(0.55)
    }
}

#if DEBUG
    /// `-PFGalaxyStress <n>` (DEBUG): adds `n` made-up albums with generated sleeves to the galaxy, to profile it at
    /// library sizes the fixtures don't reach. They are not in the library, so a tap on one plays nothing.
    enum GalaxyStress {
        static let albums: [AlbumCard] = (0..<max(UserDefaults.standard.integer(forKey: "PFGalaxyStress"), 0)).map {
            AlbumCard(
                id: "stress-\($0)", title: "Stress \($0)", artist: "Galaxy", year: 2000 + $0 % 26, artwork: nil,
                trackCount: 1, bestFormat: "FLAC 16/44.1", addedAt: Date(timeIntervalSince1970: Double($0)),
                listens: 0, lastListened: nil, bestBits: 16, bestRate: 44_100)
        }
    }
#endif
