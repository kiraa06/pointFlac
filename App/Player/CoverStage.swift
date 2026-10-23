import PFDesign
import SwiftUI

/// The editorial cover (spec §4.4): large artwork with the record peeking out of the sleeve, over a wash taken from
/// the cover's colours (drawn by the player's background). Quiet and fast: no deck gestures, nothing spins.
struct CoverStage: View {
    let playback: PlaybackController
    let theme: Theme
    let discSpace: Namespace.ID
    @AppStorage(DeckPreferences.recordStyleKey) private var recordStyle = RecordStyle.standard.rawValue

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width * 0.74, proxy.size.height * 0.9)
            ZStack {
                if let album = playback.album {
                    // The record peeks out of the sleeve's right edge, further while it plays: the same record the
                    // deck plays, in the style chosen in Customize deck.
                    RecordView(
                        face: RecordFace(
                            album: album, side: sideLetter,
                            bands: RecordFace.bands(for: playback.sideTimeline(playback.currentSide)),
                            style: RecordStyle(rawValue: recordStyle) ?? .standard),
                        diameter: side * 0.94
                    )
                    .offset(x: side * (playback.isPlaying ? 0.2 : 0.12))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                    .animation(.spring(duration: 0.7, bounce: 0.2), value: playback.isPlaying)
                    ArtworkView(albumID: album.id, artwork: album.artwork, pixels: 900)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(theme.isDark ? 0.6 : 0.22), radius: 24, y: 16)
                        .offset(x: -side * 0.06)
                        .accessibilityElement()
                        .accessibilityLabel("Cover of \(album.title) by \(album.artist)")
                        .accessibilityIdentifier("coverArt")
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                        .frame(width: side, height: side)
                        .overlay {
                            Text("No record\nOpen the shelf to pick one")
                                .multilineTextAlignment(.center)
                                .font(.callout)
                                .foregroundStyle(theme.inkSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("coverArt")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var sideLetter: String {
        let sides = playback.layout.sides
        return sides.indices.contains(playback.currentSide) ? sides[playback.currentSide].letter : "A"
    }
}
