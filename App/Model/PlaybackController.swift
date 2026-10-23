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
///
/// With crossfade on (Between albums or Always, and not Pure: ruling R4-4), the next Up Next record instead joins the
/// player's queue once the last queued track starts (`Player.append`), so the pipeline can overlap the two records.
/// The queue then holds several records, and `albumSegments` maps each player index to its record and track: the
/// platter, `trackIndex` and `currentSide` follow the record playing, and the platter takes the appended record (with
/// `autoLoads`) when its first track starts. With crossfade Off, or in Pure, nothing is appended: the queue plays out
/// and the next record starts afresh, as before.
///
/// Between albums changes only how records join (ruling R4-T16b). An appended record stays in Up Next until its first
/// track starts. When the queue no longer leads to it first, the player takes it back and it waits in Up Next as
/// before: a repeat mode turned on, or the record removed, moved, or another put ahead of it in Up Next. A queue
/// replaced meanwhile (another track tapped, the tonearm dropped, another record loaded) drops it with the old queue,
/// and it is still in Up Next. Under repeat-one every boundary is a loop of the same track, so the player keeps them
/// gapless whatever the crossfade setting (ruling R4-T16a). A record appended from a chosen song holds only the songs
/// from there on, so Previous on that song goes back to the record before, which is what the queue holds.
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

    /// A record in the player's queue: its tracks from `firstTrack` on, the first of them at player index `start`.
    struct AlbumSegment {
        let album: AlbumCard
        let tracks: [TrackRow]
        let start: Int
        let firstTrack: Int
        /// For a record appended from Up Next, its entry there, until its first track starts.
        var entry: UpNextEntry.ID?

        /// The album track at player index `index`, which must be at or after `start`.
        func track(at index: Int) -> Int { index - start + firstTrack }

        /// The player index just past this record's tracks.
        var end: Int { start + tracks.count - firstTrack }
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
    var repeatMode: RepeatMode = .off {
        didSet {
            guard repeatMode != oldValue else { return }
            // Repeat-one loops a track: an overlap at its end would cut the last fade's worth on every loop.
            player.crossfadeSuppressed = repeatMode == .one
            // A repeat replays this record: the one joined behind it is not next any more.
            reconcileJoinedRecord()
        }
    }
    /// The side the needle will drop on when it is up: the deck's "turn the record over" moves it.
    private(set) var cuedSide = 0
    /// Bumped when the controller itself pulls the next record from Up Next, so the deck can play the short hand-off:
    /// when it starts the record afresh, or when the first track of a record it appended starts.
    private(set) var autoLoads = 0
    /// The records in the player's queue, in queue order: one for a record the controller played, then one for each
    /// it appended. Empty until the controller plays a queue.
    private(set) var albumSegments: [AlbumSegment] = []
    /// The segment whose record the platter shows while the queue plays it, so it can follow the queue on.
    @ObservationIgnored private var platterSegment: Int?
    /// Counts listens as the player plays (`ListenRule`); the library keeps them for the shelf's sorts.
    @ObservationIgnored private let listenTracker: ListenTracker

    init(player: Player, library: any LibraryBrowsing) {
        self.player = player
        self.library = library
        listenTracker = ListenTracker(player: player) { [library] id, date in
            await library.recordListen(trackID: id, at: date)
        }
        listenTracker.start()
    }

    // MARK: What is playing

    /// The playing track's index in the album, when the player is playing this album.
    var trackIndex: Int? {
        guard let index = player.currentIndex, player.queue.indices.contains(index),
            let segment = segment(at: index), segment.album.id == album?.id
        else { return nil }
        let track = segment.track(at: index)
        guard tracks.indices.contains(track), player.queue[index].id == tracks[track].id else { return nil }
        return track
    }

    /// The record player index `index` belongs to. Without a table (a queue the controller did not start), the queue
    /// is taken to be the record on the platter, from its first track.
    private func segment(at index: Int) -> AlbumSegment? {
        if albumSegments.isEmpty {
            return album.map { AlbumSegment(album: $0, tracks: tracks, start: 0, firstTrack: 0) }
        }
        return albumSegments.last { $0.start <= index }
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
        cueSide(of: album, startingAt: trackID).timeline
    }

    /// The side `album` would be cued on, without cueing it: its letter, for the label of the record in flight, and its
    /// timeline.
    func cueSide(of album: AlbumCard, startingAt trackID: TrackRow.ID?) -> (letter: String, timeline: SideTimeline) {
        let tracks = library.tracks(of: album.id)
        let layout = SideLayout(durations: tracks.map(\.durationSeconds))
        let start = trackID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        let side = layout.side(ofTrack: start) ?? 0
        let letter = layout.sides.indices.contains(side) ? layout.sides[side].letter : "A"
        return (letter, SideTimeline(durations: layout.durations(onSide: side)))
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
        if trackIndex == track, queueHoldsPlatter(items) {
            await player.seek(to: .seconds(seconds))
            if !isPlaying { player.resume() }
            return
        }
        if player.currentIndex != track { intendedIndex = track }
        // A record joined behind the old queue goes with it; its entry is still in Up Next.
        if let album {
            albumSegments = [AlbumSegment(album: album, tracks: tracks, start: 0, firstTrack: 0)]
            platterSegment = 0
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

    // MARK: The tracklist

    /// A song chosen in the tracklist, with where the needle was when it was chosen: the deck swings its tonearm from
    /// there to the song's groove (turning the record over first when the song is on the other side) instead of
    /// snapping. Captured here, before the player moves, so the swing's start never depends on when the deck sees it.
    struct TrackJump: Equatable {
        /// Counts the jumps, so choosing the same song twice is still a change.
        let serial: Int
        /// The album track it plays from.
        let track: Int
        /// The side the needle was on (or cued on, needle up).
        let fromSide: Int
        /// Seconds into that side, or nil with the needle up: nothing playing, or the record played out.
        let fromPosition: Double?
    }

    /// The latest `jump(toTrack:)`.
    private(set) var lastJump: TrackJump?

    /// Plays the record from album track `index` (the tracklist), and on through the album. Through `play(fromTrack:)`,
    /// so it is serialised with the tonearm, the jog and Next: whichever was asked for last wins. A song on the other
    /// side moves the side with it, and the deck turns the record over.
    func jump(toTrack index: Int) {
        guard tracks.indices.contains(index) else { return }
        let down = trackIndex != nil && player.status != .ended
        lastJump = TrackJump(
            serial: (lastJump?.serial ?? 0) + 1, track: index, fromSide: currentSide,
            fromPosition: down ? sidePosition : nil)
        Task { await play(fromTrack: index) }
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

    /// Whether the player's queue holds the platter's record as `items` (its whole album) gives it: the queue itself,
    /// or the record's stretch of a queue that holds several.
    private func queueHoldsPlatter(_ items: [QueueItem]) -> Bool {
        guard let index = player.currentIndex, let segment = segment(at: index), segment.album.id == album?.id,
            segment.end <= player.queue.count, segment.firstTrack <= items.count
        else { return false }
        let queued = player.queue[segment.start..<segment.end].map(\.id)
        return queued == items[segment.firstTrack...].map(\.id)
    }

    func next() async {
        await perform { [weak self] in
            guard let self else { return }
            // At the end of the queue, which may hold an appended record behind this one.
            let atEnd =
                self.trackIndex == nil || (self.player.currentIndex.map { $0 + 1 >= self.player.queue.count } ?? true)
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
        // Ahead of a record already joined behind the last track: that one is taken back, this one joins.
        reconcileJoinedRecord()
    }

    func addToUpNext(_ album: AlbumCard, startingAt track: TrackRow.ID? = nil) {
        upNext.append(UpNextEntry(album: album, startTrack: track))
        // Added while the last track plays: with crossfade on, it joins the queue now.
        reconcileJoinedRecord()
    }

    func removeUpNext(_ entry: UpNextEntry) {
        upNext.removeAll { $0.id == entry.id }
        reconcileJoinedRecord()
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        upNext.move(fromOffsets: source, toOffset: destination)
        reconcileJoinedRecord()
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
        // A record joined behind the queue goes back first if its entry went or any of its songs go: queued, they
        // would stop the record playing. Nothing joins in its place here: the next record's songs may be going too.
        if let joined = albumSegments.last, let entry = joined.entry,
            !upNext.contains(where: { $0.id == entry })
                || joined.tracks[joined.firstTrack...].contains(where: { removed.contains($0.id) }),
            player.removeAppended(from: joined.start)
        {
            albumSegments.removeLast()
        }
        let onDeck =
            tracks.contains { removed.contains($0.id) } || player.queue.contains { removed.contains($0.id) }
        guard onDeck else { return }
        album = nil
        tracks = []
        layout = SideLayout(durations: [])
        albumSegments = []
        platterSegment = nil
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
            let index = trackIndex ?? last
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

    /// Called when the player moves to another track. The platter follows the queue into another record of it (an
    /// appended one, or back), and the last queued track starting appends the next Up Next record when crossfade is on
    /// (`appendNextRecordIfDue`). Under one-track repeat, only a natural advance (the track played out) goes back; a
    /// move the controller asked for (Next, Previous, a seek) is left alone.
    func playerTrackChanged(from old: Int?, to new: Int?) {
        if let new {
            joinedRecordsStarted(upTo: new)
            followQueue(to: new)
        }
        if let track = trackIndex, let side = layout.side(ofTrack: track) { cuedSide = side }
        appendNextRecordIfDue()
        if let intended = intendedIndex, new == intended {
            intendedIndex = nil
            return
        }
        guard repeatMode == .one, let old, let new, new == old + 1, isPlaying, let segment = segment(at: old) else {
            return
        }
        // Back to the track that played out, on its own record (the advance may have crossed into the next one).
        if segment.album.id != album?.id { cue(segment.album) }
        let track = segment.track(at: old)
        Task { await play(fromTrack: track) }
    }

    /// A record appended from Up Next leaves Up Next once its first track starts (player index `index` reached it).
    private func joinedRecordsStarted(upTo index: Int) {
        for i in albumSegments.indices where albumSegments[i].start <= index {
            guard let entry = albumSegments[i].entry else { continue }
            albumSegments[i].entry = nil
            upNext.removeAll { $0.id == entry }
        }
    }

    /// Keeps the record joined behind the queue only while the queue still leads to it: no repeat, and still first in
    /// Up Next. Otherwise the player takes it back (`Player.removeAppended`), it waits in Up Next as it always did, and
    /// the record now due joins instead, if any. One whose first track has started already stays.
    private func reconcileJoinedRecord() {
        if let joined = albumSegments.last, let entry = joined.entry,
            repeatMode != .off || upNext.first?.id != entry,
            player.removeAppended(from: joined.start)
        {
            albumSegments.removeLast()
        }
        appendNextRecordIfDue()
    }

    /// Puts the record of player index `index` on the platter when the queue has moved into another of its records,
    /// unless the platter shows a record the queue does not hold here (one cued by the hand-off). Moving on into an
    /// appended record is the controller's own pull from Up Next: `autoLoads`.
    private func followQueue(to index: Int) {
        guard player.queue.indices.contains(index), let from = platterSegment, albumSegments.indices.contains(from),
            albumSegments[from].album.id == album?.id,
            let to = albumSegments.lastIndex(where: { $0.start <= index }), to != from
        else { return }
        let segment = albumSegments[to]
        album = segment.album
        tracks = segment.tracks
        layout = SideLayout(durations: segment.tracks.map(\.durationSeconds))
        platterSegment = to
        if to > from { autoLoads += 1 }
    }

    /// Crossfade on (Between albums or Always, and not Pure), no repeat, a record waiting in Up Next, and the last
    /// track of the player's queue playing: the waiting record joins the queue behind it, from its chosen song, so the
    /// pipeline can overlap the boundary. It stays in Up Next until its first track starts.
    private func appendNextRecordIfDue() {
        let sound = player.sound
        guard !sound.pure, sound.crossfade.mode != .off, repeatMode == .off, isPlaying, let entry = upNext.first,
            let index = player.currentIndex, index == player.queue.count - 1, let last = albumSegments.last,
            index >= last.start, index < last.end, trackIndex != nil
        else { return }
        let tracks = library.tracks(of: entry.album.id)
        let first = entry.startTrack.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        guard tracks.indices.contains(first) else { return }
        let ids = tracks[first...].map(\.id)
        let items = library.queueItems(for: Array(ids))
        guard items.count == ids.count else { return }
        albumSegments.append(
            AlbumSegment(
                album: entry.album, tracks: tracks, start: player.queue.count, firstTrack: first, entry: entry.id))
        player.append(items)
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
