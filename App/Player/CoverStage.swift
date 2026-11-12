import PFDesign
import SwiftUI

/// The editorial cover (spec §4.4): large artwork with the record peeking out of the sleeve, over a wash taken from
/// the cover's colours (drawn by the player's background). Quiet and fast: no deck gestures, nothing spins.
///
/// A playlist on the deck shows the current song's own album cover, which changes with each song, with the playlist's
/// pressing peeking out beside it, and the playlist's name and song count in a caption under it (spec "Playlists as
/// custom pressings" §3).
struct CoverStage: View {
    let playback: PlaybackController
    let theme: Theme
    let discSpace: Namespace.ID
    @AppStorage(DeckPreferences.recordStyleKey) private var recordStyle = RecordStyle.standard.rawValue
    /// For the song the cover shows: the one playing, or the one the needle would drop on.
    @Environment(PlaylistDesk.self) private var desk: PlaylistDesk?

    var body: some View {
        GeometryReader { proxy in
            let playlist = playback.album?.pressing != nil
            // A playlist's caption takes a line under the cover, so the cover gives up a little height for it.
            let side = min(proxy.size.width * 0.74, proxy.size.height * (playlist ? 0.8 : 0.9))
            ZStack {
                if let album = playback.record {
                    VStack(spacing: 14) {
                        ZStack {
                            // The record peeks out of the sleeve's right edge, further while it plays: the same record
                            // the deck plays, in the style chosen in Customize deck (a playlist's pressing whatever it).
                            RecordView(
                                face: .face(
                                    for: album, side: sideLetter,
                                    bands: RecordFace.bands(for: playback.sideTimeline(playback.currentSide)),
                                    style: RecordStyle(rawValue: recordStyle) ?? .standard),
                                diameter: side * 0.94
                            )
                            .offset(x: side * (playback.isPlaying ? 0.2 : 0.12))
                            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                            .animation(.spring(duration: 0.7, bounce: 0.2), value: playback.isPlaying)
                            if let look = album.pressing {
                                songCover(look, side: side)
                            } else {
                                ArtworkView(albumID: album.id, artwork: album.artwork, pixels: 900)
                                    .frame(width: side, height: side)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .shadow(color: .black.opacity(theme.isDark ? 0.6 : 0.22), radius: 24, y: 16)
                                    .offset(x: -side * 0.06)
                                    .accessibilityElement()
                                    .accessibilityLabel("Cover of \(album.title) by \(album.artist)")
                                    .accessibilityIdentifier("coverArt")
                            }
                        }
                        .frame(width: side, height: side)
                        if let look = album.pressing {
                            // Centred under the cover, which sits a little left of the stage's middle.
                            caption(look)
                                .frame(width: side)
                                .offset(x: -side * 0.06)
                        }
                    }
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

    /// The cover of the song playing (or, needle up, of the one that would play), cross-fading as the songs change; the
    /// pressing's own square of covers before any song is known.
    @ViewBuilder
    private func songCover(_ look: PressingLook, side: CGFloat) -> some View {
        let song = desk?.cuedSong ?? playback.currentTrack
        ZStack {
            if let albumID = song?.albumID {
                ArtworkView(albumID: albumID, artwork: nil, pixels: 900)
                    .id(albumID)
                    .transition(.opacity)
            } else {
                PressingCoverMosaic(look: look, pixels: 600)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(theme.isDark ? 0.6 : 0.22), radius: 24, y: 16)
        .offset(x: -side * 0.06)
        .animation(.easeInOut(duration: 0.45), value: song?.albumID)
        .accessibilityElement()
        .accessibilityLabel(
            song.map { "Cover of \($0.album) by \($0.artist), playing from \(look.title)" } ?? "Cover of \(look.title)"
        )
        .accessibilityIdentifier("coverArt")
    }

    /// `♥ FAVOURITES · 24 SONGS`, in the record's small caps, under the cover.
    private func caption(_ look: PressingLook) -> some View {
        HStack(spacing: 6) {
            Image(systemName: look.isFavourites ? "heart.fill" : "record.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(look.colour.ui(monochrome: theme.isMonochrome))
            Text("\(look.title.uppercased()) · \(look.countText)")
                .font(.caption2.monospaced().weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playlist \(look.title), \(PlaylistCard.songs(look.songCount))")
        .accessibilityIdentifier("coverCaption")
    }

    private var sideLetter: String {
        let sides = playback.layout.sides
        return sides.indices.contains(playback.currentSide) ? sides[playback.currentSide].letter : "A"
    }
}
