import Observation
import PFCore
import PFDesign
import SwiftUI

/// What the playlist views share (spec "Playlists as custom pressings" §4): the library's playlists and their edits,
/// the deck for Play and Up Next, and the press-in of a playlist just made. The player puts it in the environment;
/// the shelf's strip, the heart, the tracklists' menus and the three sheets read it there.
@MainActor
@Observable
final class PlaylistDesk {
    @ObservationIgnored let library: any LibraryBrowsing
    @ObservationIgnored let playback: PlaybackController

    /// A playlist just made, whose disc waits, hidden, to press in once the sheet it was made in has gone.
    private(set) var awaitingPress: PlaylistCard.ID?
    /// The playlist whose disc is pressing in now, and a count that changes with each press (for its haptic).
    private(set) var pressing: PlaylistCard.ID?
    private(set) var presses = 0

    init(library: any LibraryBrowsing, playback: PlaybackController) {
        self.library = library
        self.playback = playback
    }

    var playlists: [PlaylistCard] { library.playlists }

    func playlist(_ id: PlaylistCard.ID) -> PlaylistCard? { library.playlists.first { $0.id == id } }

    /// The playlist on the deck, if the record there is one.
    var playlistOnDeck: PlaylistCard.ID? { playback.album?.playlistID }

    // MARK: Favourites

    func isFavourite(_ trackID: TrackRow.ID) -> Bool { library.isFavourite(trackID) }

    func toggleFavourite(_ trackID: TrackRow.ID) {
        Task { await library.toggleFavourite(trackID) }
    }

    /// The song the heart acts on (spec §8.7): the one playing, or the one that would play with the needle up (the
    /// first of the cued side). Nil only with the deck empty.
    var cuedSong: TrackRow? {
        if let track = playback.currentTrack { return track }
        let sides = playback.layout.sides
        let first = sides.indices.contains(playback.cuedSide) ? sides[playback.cuedSide].tracks.lowerBound : 0
        return playback.tracks.indices.contains(first) ? playback.tracks[first] : playback.tracks.first
    }

    // MARK: Making and editing

    /// "New Playlist", then "New Playlist 2", 3… past every name in use.
    var nextName: String {
        let used = Set(playlists.map(\.name))
        guard used.contains("New Playlist") else { return "New Playlist" }
        var n = 2
        while used.contains("New Playlist \(n)") { n += 1 }
        return "New Playlist \(n)"
    }

    /// The colour a new playlist gets: the next free one in the spec's rotation, else the least used.
    var nextColour: PressingColour { .next(after: playlists.map(\.colour)) }

    /// Makes a playlist, with `songs` in it, and holds its disc back to press in once the sheet closes. A name that
    /// trims to nothing takes the default.
    @discardableResult
    func create(name: String, colour: PressingColour, adding songs: [TrackRow.ID] = []) async -> PlaylistCard? {
        let name = Playlist.validName(name) ?? nextName
        guard let made = await library.createPlaylist(name: name, colour: colour) else { return nil }
        awaitingPress = made.id
        if !songs.isEmpty { await library.add(songs, to: made.id) }
        return playlist(made.id) ?? made
    }

    /// The sheet a playlist was made in has gone: its disc presses in now.
    func releasePress() {
        guard let id = awaitingPress else { return }
        awaitingPress = nil
        pressing = id
        presses += 1
    }

    /// Adds `songs` to the playlist; with one song that it holds already, takes it out instead (the add sheet's
    /// toggle). Returns true when the songs went in.
    @discardableResult
    func toggle(_ songs: [TrackRow.ID], in id: PlaylistCard.ID) async -> Bool {
        guard let playlist = playlist(id) else { return false }
        if songs.count == 1, let song = songs.first, playlist.songIDs.contains(song) {
            await library.remove([song], from: id)
            return false
        }
        await library.add(songs, to: id)
        return true
    }

    func remove(_ songs: [TrackRow.ID], from id: PlaylistCard.ID) {
        Task { await library.remove(songs, from: id) }
    }

    func rename(_ id: PlaylistCard.ID, to name: String) {
        Task { await library.renamePlaylist(id, to: name) }
    }

    func recolour(_ id: PlaylistCard.ID, to colour: PressingColour) {
        Task { await library.setPlaylistColour(id, to: colour) }
    }

    func reorder(_ id: PlaylistCard.ID, songs: [TrackRow.ID]) {
        Task { await library.reorder(id, songIDs: songs) }
    }

    /// Deletes the playlist, never its songs; it leaves Up Next too, where it could no longer play. One on the deck
    /// plays on: its songs are the library's.
    func delete(_ id: PlaylistCard.ID) {
        guard id != Playlist.favouritesID else { return }
        let card = PlaylistCard.cardID(id)
        for entry in playback.upNext where entry.album.id == card { playback.removeUpNext(entry) }
        Task { await library.deletePlaylist(id) }
    }

    /// Every playable song of `album`, in album order: what "Add to Playlist…" on an album adds.
    func songs(ofAlbum album: AlbumCard.ID) -> [TrackRow] { library.tracks(of: album) }

    /// A playlist's playable songs, in its order, as rows (each with its own album).
    func songs(of id: PlaylistCard.ID) -> [TrackRow] { library.tracks(of: PlaylistCard.cardID(id)) }

    #if DEBUG
        /// DEBUG launch arguments, for screenshots and for trying the feature on the demo albums:
        /// - `-PFDemoPlaylists` fills a library that has only an empty Favourites with the mockup's playlists, made from
        ///   the demo albums (best with `-PFFreshLibrary -PFPreloadFixtures`);
        /// - `-PFPlayPlaylist <id>` then puts that playlist (`favourites`, or a name) on the deck and plays it.
        ///
        /// Once a launch: a second caller waits for the first's work.
        func prepareForLaunch() async {
            if let launchPreparation { return await launchPreparation.value }
            let work = Task { await prepare() }
            launchPreparation = work
            await work.value
        }

        @ObservationIgnored private var launchPreparation: Task<Void, Never>?

        private func prepare() async {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-PFDemoPlaylists") || arguments.contains("-PFPlayPlaylist") else { return }
            // The fixtures are imported at launch: wait for the shelf to list them.
            for _ in 0..<100 where library.albums.count < 5 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if arguments.contains("-PFDemoPlaylists"), playlists.count == 1, playlists.first?.songCount == 0 {
                await seedDemoPlaylists()
            }
            if let wanted = UserDefaults.standard.string(forKey: "PFPlayPlaylist"),
                let card = playlists.first(where: { $0.id == wanted || $0.name == wanted })
            {
                await playback.load(card.albumCard)
            }
        }

        private func seedDemoPlaylists() async {
            let albums = Dictionary(library.albums.map { ($0.title, $0.id) }, uniquingKeysWith: { first, _ in first })
            func songs(_ picks: [(String, Int)]) -> [TrackRow.ID] {
                picks.compactMap { title, index in
                    guard let album = albums[title] else { return nil }
                    let tracks = library.tracks(of: album)
                    return tracks.indices.contains(index) ? tracks[index].id : nil
                }
            }
            await library.add(
                songs([
                    ("Copper Garden", 2), ("Night Drive", 0), ("Paper Moons", 1), ("Hydrophone", 0), ("Low Orbit", 0),
                    ("Night Drive", 2),
                ]), to: Playlist.favouritesID)
            let made: [(String, PressingColour, [(String, Int)])] = [
                ("Late Night Drives", .amber, [("Night Drive", 1), ("Low Orbit", 1), ("Paper Moons", 0)]),
                ("Gym", .jade, [("Copper Garden", 0), ("Copper Garden", 1), ("Copper Garden", 3)]),
                ("Rainy Sunday", .ocean, [("Paper Moons", 2), ("Hydrophone", 1), ("Paper Moons", 3)]),
                (
                    "Focus", .violet,
                    [("Hydrophone", 2), ("Copper Garden", 2), ("Night Drive", 3), ("Paper Moons", 3), ("Low Orbit", 0)]
                ),
                ("Demos", .smoke, []),
            ]
            for (name, colour, picks) in made {
                guard let card = await library.createPlaylist(name: name, colour: colour) else { continue }
                if !picks.isEmpty { await library.add(songs(picks), to: card.id) }
            }
        }
    #endif
}
