import Foundation
import Observation
import PFAudio
import PFDesign

/// The record on the deck, laid out in sides, with Up Next and repeat, over the real `Player`.
///
/// Why sides carry on by themselves: the player gets the whole album as one queue, so the audio runs gaplessly from
/// side A into side B (Kiran's decision); the deck only animates the flip. Records after this one wait in Up Next,
/// and the controller starts the next when the player reports the queue played out. Repeat lives here too, because
/// the player has none: album repeat replays the queue, and one-track repeat steps back when the player moves on.
@MainActor
@Observable
final class PlaybackController {
    enum RepeatMode: CaseIterable {
        case off, album, one

        var next: RepeatMode {
            switch self {
            case .off: .album
            case .album: .one
            case .one: .off
            }
        }
    }

    /// A record waiting in Up Next: an album, from its first track or from a chosen song.
    struct UpNextEntry: Identifiable, Hashable {
        let id = UUID()
        let album: AlbumCard
        let startTrack: TrackRow.ID?
    }

    let player: Player
    @ObservationIgnored private let library: any LibraryBrowsing
    private(set) var album: AlbumCard?
    private(set) var tracks: [TrackRow] = []
    private(set) var layout = SideLayout(durations: [])
    private(set) var upNext: [UpNextEntry] = []
    var repeatMode: RepeatMode = .off
    /// The side the needle will drop on when it is up: the deck's "turn the record over" moves it.
    private(set) var cuedSide = 0
    /// Bumped when the controller itself pulls the next record from Up Next, so the deck can play the short hand-off.
    private(set) var autoLoads = 0

    init(player: Player, library: any LibraryBrowsing) {
        self.player = player
        self.library = library
    }

    // MARK: What is playing

    /// The playing track's index in the album, when the player is playing this album.
    var trackIndex: Int? {
        guard let index = player.currentIndex, player.queue.indices.contains(index), tracks.indices.contains(index),
            player.queue[index].id == tracks[index].id
        else { return nil }
        return index
    }

    var currentTrack: TrackRow? { trackIndex.map { tracks[$0] } }

    /// The side under the needle: the playing track's, or the cued one.
    var currentSide: Int { trackIndex.flatMap { layout.side(ofTrack: $0) } ?? cuedSide }

    var isPlaying: Bool { player.status == .playing || player.status == .preparing }

    /// Seconds from the start of the current side to the needle.
    var sidePosition: Double {
        guard let index = trackIndex else { return 0 }
        return layout.offset(ofTrack: index) + player.position.seconds
    }

    func sideTimeline(_ side: Int) -> SideTimeline {
        SideTimeline(durations: layout.durations(onSide: side))
    }

    // MARK: Loading and playing

    /// Puts `album` on the platter without dropping the needle: the hand-off's landing.
    func cue(_ album: AlbumCard, startingAt trackID: TrackRow.ID? = nil) {
        self.album = album
        tracks = library.tracks(of: album.id)
        layout = SideLayout(durations: tracks.map(\.durationSeconds))
        let start = trackID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        cuedSide = layout.side(ofTrack: start) ?? 0
    }

    /// Plays the cued album from `track` (an album index), `seconds` into it.
    func play(fromTrack track: Int, at seconds: Double = 0) async {
        guard tracks.indices.contains(track) else { return }
        let items = library.queueItems(for: tracks.map(\.id))
        guard items.count == tracks.count else { return }
        if trackIndex != nil, player.queue.map(\.id) == items.map(\.id), player.currentIndex == track {
            await player.seek(to: .seconds(seconds))
            if !isPlaying { player.resume() }
            return
        }
        await player.play(items, startingAt: track)
        if seconds > 0.01 {
            // Start at the needle, not at the track's start: stop the new pipeline before it renders, move the cue,
            // and resume there. A seek racing the pipeline's start could be overtaken by its first track-started
            // event, and would let the track's opening play for a moment.
            player.pause()
            await player.seek(to: .seconds(seconds))
            player.resume()
        }
    }

    /// Loads `album` and plays it, from `trackID` when given (spec §4.3: a tapped song plays from that song and then
    /// carries on through the album).
    func load(_ album: AlbumCard, startingAt trackID: TrackRow.ID? = nil) async {
        cue(album, startingAt: trackID)
        let start = trackID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        await play(fromTrack: start)
    }

    /// Drops the needle at the start of the cued side.
    func dropNeedleOnCuedSide() async {
        guard layout.sides.indices.contains(cuedSide) else { return }
        await play(fromTrack: layout.sides[cuedSide].tracks.lowerBound)
    }

    /// Turns the record over while the needle is up.
    func flipCuedSide() {
        guard !layout.sides.isEmpty else { return }
        cuedSide = (cuedSide + 1) % layout.sides.count
    }

    /// Seeks to `seconds` on side `side`, moving to another track when the needle lands on one.
    func seek(side: Int, to seconds: Double) async {
        guard layout.sides.indices.contains(side) else { return }
        let (local, offset) = sideTimeline(side).locate(seconds)
        await play(fromTrack: layout.sides[side].tracks.lowerBound + local, at: offset)
    }

    func next() async {
        if trackIndex == nil, tracks.isEmpty == false, !upNext.isEmpty {
            await pullNext()
            return
        }
        if let index = trackIndex, index + 1 >= tracks.count, !upNext.isEmpty {
            await pullNext()
            return
        }
        await player.next()
    }

    func previous() async {
        await player.previous()
    }

    func togglePlayPause() {
        if player.status == .idle || trackIndex == nil, album != nil {
            Task { await dropNeedleOnCuedSide() }
            return
        }
        player.togglePlayPause()
    }

    // MARK: Up Next

    func playNext(_ album: AlbumCard, startingAt track: TrackRow.ID? = nil) {
        upNext.insert(UpNextEntry(album: album, startTrack: track), at: 0)
    }

    func addToUpNext(_ album: AlbumCard, startingAt track: TrackRow.ID? = nil) {
        upNext.append(UpNextEntry(album: album, startTrack: track))
    }

    func removeUpNext(_ entry: UpNextEntry) {
        upNext.removeAll { $0.id == entry.id }
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        upNext.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: Following the player

    /// Called when the player's status changes. At the end of the queue: repeat, else the next Up Next record, else
    /// the needle lifts and play stops.
    func playerStatusChanged(to status: Player.Status) {
        guard status == .ended, album != nil else { return }
        switch repeatMode {
        case .album:
            Task { await play(fromTrack: 0) }
        case .one:
            let last = max(0, tracks.count - 1)
            Task { await play(fromTrack: player.currentIndex ?? last) }
        case .off:
            guard !upNext.isEmpty else { return }
            Task { await pullNext() }
        }
    }

    /// Called when the player moves to another track. Under one-track repeat, a move forward goes back.
    func playerTrackChanged(from old: Int?, to new: Int?) {
        guard repeatMode == .one, let old, let new, new == old + 1, isPlaying else { return }
        Task { await play(fromTrack: old) }
    }

    private func pullNext() async {
        guard !upNext.isEmpty else { return }
        let entry = upNext.removeFirst()
        autoLoads += 1
        await load(entry.album, startingAt: entry.startTrack)
    }
}

extension Duration {
    /// Seconds as a `Double`, for display and geometry.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
