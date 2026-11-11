import SwiftUI

/// Songs on their way into a playlist, from the Add to Playlist sheet.
struct PlaylistAddRequest: Hashable, Sendable {
    let songs: [TrackRow.ID]
    /// What they are, under the sheet's title: "Golden Hour · Ada Vale", "Paper Moons · 4 songs".
    let subtitle: String
    /// The covers a playlist made from them starts its label with.
    let covers: [String]

    init(songs: [TrackRow.ID], subtitle: String, covers: [String] = []) {
        self.songs = songs
        self.subtitle = subtitle
        self.covers = covers
    }

    /// One song: its title and artist.
    init(song: TrackRow) {
        self.init(songs: [song.id], subtitle: "\(song.title) · \(song.artist)", covers: song.albumID.map { [$0] } ?? [])
    }

    /// An album's songs, in its order.
    init(album: AlbumCard, songs: [TrackRow]) {
        self.init(
            songs: songs.map(\.id), subtitle: "\(album.title) · \(PlaylistCard.songs(songs.count))", covers: [album.id])
    }
}

/// A playlist sheet to open (spec §4): Add to Playlist, New Playlist, or a playlist's own sheet.
enum PlaylistRoute: Identifiable, Hashable, Sendable {
    case add(PlaylistAddRequest)
    case create
    case open(PlaylistCard.ID)

    var id: String {
        switch self {
        case .add(let request): "add|\(request.songs.joined(separator: ","))"
        case .create: "create"
        case .open(let id): "open|\(id)"
        }
    }
}

/// Opens a playlist sheet from wherever a view sits: the nearest `playlistSheets` host above it presents it. A sheet
/// that offers playlist actions of its own (the tracklist) hosts its own, since a view already presenting a sheet
/// can't present another.
struct PlaylistRouter {
    var open: @MainActor (PlaylistRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var playlistRouter = PlaylistRouter()
}

extension View {
    /// Presents the playlist sheets that views under this one ask for. `play` puts a playlist on the deck from its
    /// sheet, from a song or from the top (the player closes the shelf first); without it the sheet offers no Play.
    func playlistSheets(_ desk: PlaylistDesk?, play: ((AlbumCard, TrackRow.ID?) -> Void)? = nil) -> some View {
        modifier(PlaylistSheetHost(desk: desk, play: play))
    }
}

private struct PlaylistSheetHost: ViewModifier {
    let desk: PlaylistDesk?
    let play: ((AlbumCard, TrackRow.ID?) -> Void)?
    @State private var route: PlaylistRoute?

    func body(content: Content) -> some View {
        let binding = $route
        content
            .environment(
                \.playlistRouter,
                PlaylistRouter { next in
                    // A menu (or a dialog) is still closing when its button runs: present once it has gone.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        binding.wrappedValue = next
                    }
                }
            )
            // A playlist made in a sheet presses into the strip once the sheet has gone.
            .sheet(item: $route, onDismiss: released) { route in
                if let desk {
                    sheet(route, desk)
                        .environment(desk)
                }
            }
            #if DEBUG
                .task {
                    // The player's host only (it can play): `-PFPlaylistSheet new|add|<playlist id or name>` opens that
                    // sheet once the launch has settled, for screenshots. `add` adds the song on the deck.
                    guard play != nil, let desk, let which = UserDefaults.standard.string(forKey: "PFPlaylistSheet")
                    else { return }
                    await desk.prepareForLaunch()
                    try? await Task.sleep(for: .seconds(1.5))
                    switch which {
                    case "new": route = .create
                    case "add": route = desk.cuedSong.map { .add(PlaylistAddRequest(song: $0)) }
                    default:
                        route = desk.playlists.first { $0.id == which || $0.name == which }.map { .open($0.id) }
                    }
                }
            #endif
    }

    private func released() { desk?.releasePress() }

    @ViewBuilder
    private func sheet(_ route: PlaylistRoute, _ desk: PlaylistDesk) -> some View {
        switch route {
        case .add(let request):
            AddToPlaylistSheet(desk: desk, request: request)
        case .create:
            NewPlaylistSheet(desk: desk)
        case .open(let id):
            PlaylistSheet(desk: desk, playlistID: id, play: play)
        }
    }
}
