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
    /// The transport command in flight, and the number of the latest one asked for.
    @ObservationIgnored private var transport: Task<Void, Never>?
    @ObservationIgnored private var transportToken = 0
    /// The track the controller itself moved to, so a one-track repeat can tell that move from a natural advance.
    @ObservationIgnored private var intendedIndex: Int?
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

    /// The side `album` would be cued on, without cueing it: the hand-off draws the incoming record's track gaps from
    /// it before the record lands.
    func sideTimeline(of album: AlbumCard, startingAt trackID: TrackRow.ID?) -> SideTimeline {
        let tracks = library.tracks(of: album.id)
        let layout = SideLayout(durations: tracks.map(\.durationSeconds))
        let start = trackID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        return SideTimeline(durations: layout.durations(onSide: layout.side(ofTrack: start) ?? 0))
    }

    /// Puts `album` on the platter without dropping the needle: the hand-off's landing.
    func cue(_ album: AlbumCard, startingAt trackID: TrackRow.ID? = nil) {
        self.album = album
        tracks = library.tracks(of: album.id)
        layout = SideLayout(durations: tracks.map(\.durationSeconds))
        let start = trackID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        cuedSide = layout.side(ofTrack: start) ?? 0
    }

    // MARK: Transport, serialized

    /// Runs transport commands one at a time, latest wins: a command waits for the one in flight, and a command that
    /// was overtaken before it started is dropped. Why: a tonearm drop, a jog and a Next can land within a frame of
    /// each other, and interleaving their awaits on the player would leave the queue wherever the last await
    /// resumed.
    private func perform(_ work: @escaping @MainActor () async -> Void) async {
        transportToken += 1
        let token = transportToken
        let previous = transport
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.transportToken == token else { return }
            await work()
        }
        transport = task
        await task.value
    }

    /// Plays the cued album from `track` (an album index), `seconds` into it.
    func play(fromTrack track: Int, at seconds: Double = 0) async {
        await perform { [weak self] in await self?.playNow(fromTrack: track, at: seconds) }
    }

    private func playNow(fromTrack track: Int, at seconds: Double) async {
        guard tracks.indices.contains(track) else { return }
        let items = library.queueItems(for: tracks.map(\.id))
        guard items.count == tracks.count else { return }
        if player.currentIndex != track { intendedIndex = track }
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

    // MARK: A finger on the record

    /// The hand holds the record (spec §4.3): from now until `endScrub`, the music follows it. False when the player
    /// cannot take hold now (nothing cued, or a start or seek still on its way).
    @discardableResult
    func beginScrub() -> Bool {
        player.beginScrub()
    }

    /// The hand has turned the record `degrees` since it took hold (clockwise forward), turning it at
    /// `degreesPerSecond` now.
    func scrub(degrees: Double, degreesPerSecond: Double) {
        player.scrub(
            offsetSeconds: JogMath.seconds(forDegrees: degrees), speed: degreesPerSecond / SpinModel.fullSpeed)
    }

    /// The hand let go: a playing record spins back up over `spinUpSeconds`, a paused one stays where it was left.
    func endScrub(spinUpSeconds: Double) {
        player.endScrub(spinUpSeconds: spinUpSeconds)
    }

    /// Seeks within the playing track (the progress bar).
    func seek(to seconds: Double) async {
        await perform { [weak self] in
            await self?.player.seek(to: .seconds(seconds))
        }
    }

    func next() async {
        await perform { [weak self] in
            guard let self else { return }
            let atEnd = self.trackIndex.map { $0 + 1 >= self.tracks.count } ?? true
            if atEnd, !self.upNext.isEmpty {
                await self.pullNextNow()
                return
            }
            self.intendedIndex = self.player.currentIndex.map { $0 + 1 }
            await self.player.next()
        }
    }

    func previous() async {
        await perform { [weak self] in
            guard let self, let index = self.player.currentIndex else { return }
            // The player restarts the track past its restart window, or at the first track; else it goes back one.
            let restarts = self.player.position > .seconds(3) || index == 0
            self.intendedIndex = restarts ? index : index - 1
            await self.player.previous()
        }
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

    // MARK: Deleting

    /// Called before `removed` leave the library (Delete Album, Delete Song), so nothing ever tries to play a file
    /// that is gone. When the record on the platter, or the queue the player holds, has any of them, playback stops
    /// and the platter is left empty: the deck shows no record. An Up Next entry goes when its album goes entirely;
    /// one that keeps some songs stays, and starts from its first song if its chosen one went.
    ///
    /// Idempotent, so the shelf calls it again once the removal is done, in case the record went back on meanwhile.
    func willRemove(tracks removed: Set<TrackRow.ID>) async {
        upNext.removeAll { entry in
            library.tracks(of: entry.album.id).allSatisfy { removed.contains($0.id) }
        }
        let onDeck =
            tracks.contains { removed.contains($0.id) } || player.queue.contains { removed.contains($0.id) }
        guard onDeck else { return }
        album = nil
        tracks = []
        layout = SideLayout(durations: [])
        cuedSide = 0
        intendedIndex = nil
        // Unlike `perform`, never overtaken: the stop waits for the command in flight, and drops any still waiting,
        // so nothing queued before it can start the old record again.
        transportToken += 1
        let previous = transport
        let stop = Task { @MainActor [weak self] in
            await previous?.value
            await self?.player.play([], startingAt: 0)
        }
        transport = stop
        await stop.value
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
            let index = player.currentIndex ?? last
            Task { await play(fromTrack: index) }
        case .off:
            guard !upNext.isEmpty else { return }
            let ended = album?.id
            Task {
                await perform { [weak self] in
                    // Next may have pulled the record already; pull only if this album is still the one that ended.
                    guard let self, self.album?.id == ended else { return }
                    await self.pullNextNow()
                }
            }
        }
    }

    /// Called when the player moves to another track. Under one-track repeat, only a natural advance (the track played
    /// out) goes back; a move the controller asked for (Next, Previous, a seek) is left alone.
    func playerTrackChanged(from old: Int?, to new: Int?) {
        if let new, let side = layout.side(ofTrack: new) { cuedSide = side }
        if let intended = intendedIndex, new == intended {
            intendedIndex = nil
            return
        }
        guard repeatMode == .one, let old, let new, new == old + 1, isPlaying else { return }
        Task { await play(fromTrack: old) }
    }

    private func pullNextNow() async {
        guard !upNext.isEmpty else { return }
        let entry = upNext.removeFirst()
        autoLoads += 1
        cue(entry.album, startingAt: entry.startTrack)
        let start = entry.startTrack.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        await playNow(fromTrack: start, at: 0)
    }
}

extension Duration {
    /// Seconds as a `Double`, for display and geometry.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
