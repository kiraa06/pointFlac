import PFCore
import PFDesign
import SwiftUI

/// A song's playlist items, for a long-press menu (spec §4): Add to Favourites (or Remove from Favourites), Add to
/// Playlist…, and, in the tracklist of a playlist on the deck, Remove from This Playlist. They act on the song itself,
/// whatever record it was found on.
struct SongPlaylistItems: View {
    let desk: PlaylistDesk
    let song: TrackRow
    /// The playlist whose tracklist this is, when the record on the deck is a playlist's.
    var playlist: PlaylistCard.ID? = nil
    @Environment(\.playlistRouter) private var router

    var body: some View {
        let favourite = desk.isFavourite(song.id)
        Button(
            favourite ? "Remove from Favourites" : "Add to Favourites",
            systemImage: favourite ? "heart.slash" : "heart"
        ) {
            desk.toggleFavourite(song.id)
        }
        Button("Add to Playlist…", systemImage: "text.badge.plus") {
            router.open(.add(PlaylistAddRequest(song: song)))
        }
        if let playlist, desk.playlist(playlist)?.songIDs.contains(song.id) == true {
            Button("Remove from This Playlist", systemImage: "minus.circle", role: .destructive) {
                desk.remove([song.id], from: playlist)
            }
        }
    }
}

/// An album's "Add to Playlist…": its songs, in its order.
struct AlbumPlaylistItem: View {
    let desk: PlaylistDesk
    let album: AlbumCard
    @Environment(\.playlistRouter) private var router

    var body: some View {
        Button("Add to Playlist…", systemImage: "text.badge.plus") {
            let songs = desk.songs(ofAlbum: album.id)
            guard !songs.isEmpty else { return }
            router.open(.add(PlaylistAddRequest(album: album, songs: songs)))
        }
    }
}

/// The heart (spec §4, "Player: the heart"): Favourites for the song on the deck, the one playing or, with the needle
/// up, the one that would play. Filled and ruby when it is in Favourites (grey in Monochrome), with a bounce and a
/// medium impact as it changes; disabled only with the deck empty (the transport disables it).
struct FavouriteButton: View {
    let desk: PlaylistDesk
    let theme: Theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts the taps: the bounce and the impact answer a tap, not the next song arriving already hearted.
    @State private var taps = 0

    var body: some View {
        let song = desk.cuedSong
        let on = song.map { desk.isFavourite($0.id) } ?? false
        Button {
            guard let song else { return }
            taps += 1
            desk.toggleFavourite(song.id)
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .foregroundStyle(on ? heartColour : theme.inkSecondary)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : taps)
                .frame(width: 44, height: 44)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .accessibilityLabel(on ? "Remove from Favourites" : "Add to Favourites")
        .accessibilityValue(song?.title ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("favouriteButton")
    }

    /// Ruby, or its grey under Monochrome.
    private var heartColour: Color { PressingColour.ruby.ui(monochrome: theme.isMonochrome) }
}
