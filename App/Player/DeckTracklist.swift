import PFDesign
import SwiftUI

/// The deck's display unfolded over the platter (plan 9 §3): the record's songs in the dot-matrix face, side by side,
/// as `A1  IGNITION  3:10`, with the playing song inverted. A song tapped plays and the display folds back; the header
/// folds it back without playing anything.
struct DeckTracklist: View {
    let playback: PlaybackController
    let theme: Theme
    let pick: (Int) -> Void
    let fold: () -> Void
    /// The rows' face, growing with Dynamic Type up to what the panel can hold.
    @ScaledMetric(relativeTo: .subheadline) private var face: CGFloat = 14
    /// The song just tapped: inverted at once, before the player has moved to it.
    @State private var picked: Int?
    /// Rows run on below the panel's edge: the last visible one fades out, so a cut-off row reads as "more".
    @State private var moreBelow = false

    /// How far the panel sits inside the plinth's edge.
    static let inset: CGFloat = 8

    /// Unfolding and folding: a light spring, or a short cross-fade under Reduce Motion. Everything that opens or
    /// closes the panel uses it, so the two directions always match.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.15)
    }

    /// The panel grows out of the display (`display`, on a plinth of `size`): scaled about the point that maps the
    /// panel's frame onto the display's, so at the start it is exactly the display, and fading in on the way. Under
    /// Reduce Motion, a cross-fade.
    static func unfold(from display: CGRect, in size: CGSize, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let panel = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        guard panel.width > display.width, panel.height > display.height else { return .opacity }
        let scale = CGSize(width: display.width / panel.width, height: display.height / panel.height)
        // The fixed point A of a scale s that takes the panel's edge (at `inset`) to the display's: A + s(inset - A)
        // is the display's edge.
        let anchor = UnitPoint(
            x: (display.minX - inset * scale.width) / (1 - scale.width) / size.width,
            y: (display.minY - inset * scale.height) / (1 - scale.height) / size.height)
        return .modifier(
            active: Unfold(scale: scale, anchor: anchor, opacity: 0),
            identity: Unfold(scale: CGSize(width: 1, height: 1), anchor: anchor, opacity: 1))
    }

    private var playing: Int? { picked ?? playback.trackIndex }
    private var size: CGFloat { min(face, 22) }
    /// 34 pt at the 14 pt face, and in step with it: the rows keep their rhythm as the face grows.
    private var rowHeight: CGFloat { size * 34 / 14 }
    private var ink: Color { theme.lcdInk }
    private var back: Color { theme.lcdBack }

    var body: some View {
        let list = Tracklist(tracks: playback.tracks, layout: playback.layout)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(back)
            VStack(alignment: .leading, spacing: 0) {
                header(list)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(list.sides) { side in
                                Text("— SIDE \(side.letter) —")
                                    .font(.system(size: size * 0.8, weight: .bold, design: .monospaced))
                                    .tracking(1)
                                    .foregroundStyle(ink.opacity(0.6))
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .accessibilityLabel("Side \(side.letter)")
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(side.songs) { song in
                                    row(song, codeWidth: codeWidth(list)).id(song.index)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.visibleRect.maxY < geometry.contentSize.height - 2
                    } action: { _, more in
                        withAnimation(.easeOut(duration: 0.2)) { moreBelow = more }
                    }
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: moreBelow ? rowHeight : 0)
                        }
                    }
                    .onAppear {
                        if let playing { proxy.scrollTo(playing, anchor: .center) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            DotGrid(back: back)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ink.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.3), radius: 20, y: 12)
        .sensoryFeedback(.selection, trigger: picked)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { fold() }
        .accessibilityIdentifier("deckTracklist")
    }

    /// `NIGHT DRIVE   5 TRK 19:05`, a shade dimmer than the rows. Tapping it folds the display back.
    private func header(_ list: Tracklist) -> some View {
        let album = playback.album
        return Button(action: fold) {
            HStack(spacing: 12) {
                Text((album?.title ?? "").uppercased())
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(list.songCount) TRK \(Tracklist.clock(list.seconds))")
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: size * 0.82, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(ink.opacity(0.72))
            .shadow(color: ink.opacity(0.35), radius: 3)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(album?.title ?? ""), \(list.spokenSummary)")
        .accessibilityHint("Folds the display back")
        .accessibilityIdentifier("deckTracklistHeader")
    }

    /// The code column: as wide as the longest code in the face (SF Mono's glyphs are 0.6 em, plus the tracking), so
    /// the titles line up and an "A10" never pushes its title out of line.
    private func codeWidth(_ list: Tracklist) -> CGFloat {
        let longest = list.sides.flatMap(\.songs).map(\.code.count).max() ?? 2
        return CGFloat(longest) * (size * 0.6 + 1)
    }

    private func row(_ song: Tracklist.Song, codeWidth: CGFloat) -> some View {
        let current = song.index == playing
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { picked = song.index }
            pick(song.index)
        } label: {
            HStack(spacing: 14) {
                Text(song.code)
                    .fixedSize()
                    .frame(minWidth: codeWidth, alignment: .leading)
                Text(song.title.uppercased())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Tracklist.clock(song.seconds))
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(current ? back : ink)
            .shadow(color: current ? .clear : ink.opacity(0.5), radius: 3)
            .padding(.horizontal, 8)
            .frame(minHeight: rowHeight)
            .background {
                if current {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ink)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Tracklist.label(song))
        .accessibilityValue(current ? "Playing" : "")
        .accessibilityIdentifier("deckTrack-\(song.index)")
    }
}

/// The unfolding display's in-between: scaled about `anchor` and faded.
private struct Unfold: ViewModifier {
    let scale: CGSize
    let anchor: UnitPoint
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scale.width, y: scale.height, anchor: anchor)
            .opacity(opacity)
    }
}
