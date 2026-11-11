import Foundation
import OSLog
import Observation
import PFAudio
import PFCore
import PFDesign
import PFDownloads
import PFLibrary
import PFSearch
import Synchronization

/// The latest library snapshot, readable from any thread.
///
/// The smart search's library closure is `@Sendable` and runs inside a keystroke, so it cannot hop to the main actor
/// to read `RealLibrary.snapshot`. This box hands it the same immutable snapshot under a lock held for a pointer copy.
final class SnapshotBox: Sendable {
    private let current = Mutex(LibrarySnapshot.empty)

    var snapshot: LibrarySnapshot { current.withLock { $0 } }

    func replace(with snapshot: LibrarySnapshot) { current.withLock { $0 = snapshot } }
}

/// Which stored cover each album shows, for `ArtworkLoader.source`.
final class CoverIndex: Sendable {
    private let ids = Mutex<[String: String]>([:])

    func artworkID(of albumID: String) -> String? { ids.withLock { $0[albumID] } }

    func replace(with map: [String: String]) { ids.withLock { $0 = map } }
}

/// `LibraryBrowsing` over stream A's `Library` and `LibrarySnapshot` (contract 2).
///
/// The library publishes a catalog after every change; the snapshot (catalog plus search index) is built off the main
/// actor, then swapped in here, so a keystroke's search is a synchronous index query on an immutable value (well
/// under the 8 ms budget). Tracks v1 cannot play (multichannel, `isSupported == false`) are filtered out before the UI
/// sees them: the UI refuses an album whose queue items come back short, so it must never be offered one.
///
/// Covers are not put into `AlbumCard.artwork`: that would read every cover at each library change, and the
/// library's cover cache holds only 32 MB. Instead `ArtworkLoader.source` reads a cover when its sleeve is first drawn.
///
/// It also starts the library's loudness scan (`Library.scanLoudness`, for ReplayGain), in the background, whenever a
/// catalog brings tracks no earlier one had: once a launch, and after every import, download or rescan that adds any.
/// The Sound tab's ReplayGain block shows what is known (`loudness`) and the scan's progress (`loudnessScan`).
@MainActor
@Observable
final class RealLibrary: LibraryBrowsing {
    private(set) var albums: [AlbumCard] = []
    /// The latest snapshot, for the debug views and the music finder.
    private(set) var snapshot: LibrarySnapshot = .empty
    /// The playable tracks' loudness data, recounted with each catalog.
    private(set) var loudness = LoudnessSummary()
    /// The background loudness scan, while one runs and has tracks to measure; nil otherwise.
    private(set) var loudnessScan: LoudnessScanProgress?
    /// Scan calls not yet returned. A call made while another runs is merged into it and returns at once, reporting
    /// nothing; the first call's progress counts the merged work too, so progress shows until every call is back.
    @ObservationIgnored private var scansRunning = 0

    @ObservationIgnored let library: Library
    @ObservationIgnored let box = SnapshotBox()
    @ObservationIgnored private var cards: [String: AlbumCard] = [:]
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// Album ID → cover ID, for the lazy cover loader.
    @ObservationIgnored private let covers = CoverIndex()
    /// The track IDs of the latest catalog, to tell when tracks come in (`measureNewTracks`).
    @ObservationIgnored private var knownTrackIDs: Set<String> = []
    /// Every track's listens, keyed by track ID: loaded once by `start()`, then kept up to date by `recordListen`, so
    /// the albums' counts never wait for a catalog.
    @ObservationIgnored private var listenStats: [String: ListenStat] = [:]
    /// Favourites and the named playlists, as the shelf shows them: each filtered to the catalog's playable songs.
    private(set) var playlists: [PlaylistCard] = []
    /// The playlists as the library stores them, every track ID included (a song whose file is gone for now too): the
    /// truth `playlists` is filtered from, and what a reorder must hand back whole.
    @ObservationIgnored private var storedPlaylists: [Playlist] = []
    /// Favourites' stored track IDs, for the heart's lookup. Observed, so the heart follows.
    private var favouriteIDs: Set<String> = []
    /// Playlist writes still on their way to the library. A read that lands meanwhile may predate one of them, so it
    /// is not shown: the list keeps the edits made here until every write is in.
    @ObservationIgnored private var playlistWrites = 0
    /// The folder picked for downloads, as last resolved, or nil: deleting a song whose file is inside it moves the
    /// file to Recently Deleted. Set by the app model once the folder's store exists; read at each plan and removal,
    /// so a folder chosen, forgotten or found unavailable since applies at once.
    @ObservationIgnored var downloadFolder: () -> DownloadFolderStore.ResolvedFolder? = { nil }
    /// The move to Recently Deleted, run inside the library's coordinated write. DEBUG's `-PFTrashFolder` replaces it,
    /// as the simulator has no trash.
    @ObservationIgnored var trash: @Sendable (URL) throws -> URL? = TrashFolder.systemTrash

    init(library: Library) {
        self.library = library
        ArtworkLoader.shared.source = { [library, covers] albumID in
            library.artwork(covers.artworkID(of: albumID))
        }
    }

    /// Follows the library's catalogs from now on. Call once.
    func start() {
        guard watcher == nil else { return }
        let library = library
        watcher = Task { [weak self] in
            let stored = await library.listenStats()
            self?.adopt(stored)
            await self?.refreshPlaylists()
            for await catalog in library.changes() {
                let snapshot = await Task.detached(priority: .userInitiated) { LibrarySnapshot(catalog) }.value
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    /// Picks up what changed in the library folders: at launch and whenever the app returns to the foreground.
    func rescan() async {
        await library.rescan()
        await sync()
    }

    /// Applies the library's latest catalog now, rather than when `changes()` delivers it, so a caller that just
    /// imported (the fixture preload, `-PFDemoPlay`) sees the result when this returns.
    func sync() async {
        let catalog = library.current
        apply(await Task.detached(priority: .userInitiated) { LibrarySnapshot(catalog) }.value)
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
        box.replace(with: snapshot)
        let summary = LoudnessSummary(snapshot.catalog.tracks.values.filter(\.isSupported))
        if summary != loudness { loudness = summary }
        measureNewTracks(in: snapshot.catalog)
        var covers: [String: String] = [:]
        for album in snapshot.albums {
            if let cover = album.artworkID { covers[album.id] = cover }
        }
        self.covers.replace(with: covers)
        rebuildCards()
        // A song whose file went (or came back) leaves (or rejoins) its playlists' lists.
        rebuildPlaylists()
    }

    /// Builds every card from the snapshot and the listens.
    private func rebuildCards() {
        var built: [AlbumCard] = []
        var byID: [String: AlbumCard] = [:]
        for album in snapshot.albums {
            guard let card = card(for: album) else { continue }
            built.append(card)
            byID[album.id] = card
        }
        cards = byID
        if built != albums { albums = built }
    }

    /// The card for `album`, or nil when none of its tracks is playable.
    private func card(for album: LibraryAlbum) -> AlbumCard? {
        let playable = snapshot.tracks(of: album.id).filter(\.isSupported)
        guard !playable.isEmpty else { return nil }
        let stats = playable.compactMap { listenStats[$0.id] }
        return AlbumCard(
            id: album.id, title: album.title, artist: album.artist, year: album.year, artwork: nil,
            trackCount: playable.count, bestFormat: album.formatLabel, addedAt: album.addedAt,
            listens: stats.reduce(0) { $0 + $1.count }, lastListened: stats.compactMap(\.lastAt).max(),
            bestBits: album.bestFormat.bitsPerSample, bestRate: album.bestFormat.sampleRate)
    }

    /// Takes the stored listens in, keeping any higher count a listen recorded meanwhile already set, and shows them.
    private func adopt(_ stored: [String: ListenStat]) {
        listenStats.merge(stored) { current, stored in current.count >= stored.count ? current : stored }
        rebuildCards()
    }

    func recordListen(trackID: TrackRow.ID, at date: Date) async {
        let stat = await library.recordListen(trackID: trackID, at: date)
        // A failed write comes back as a zero count: nothing to show.
        guard stat.count > 0 else { return }
        listenStats[trackID] = stat
        // Only this track's album changes: its card is replaced in place, and no catalog or search index is rebuilt.
        guard let albumID = snapshot.track(trackID)?.albumID, let album = snapshot.catalog.album(albumID),
            let updated = card(for: album), let position = albums.firstIndex(where: { $0.id == albumID })
        else { return }
        cards[albumID] = updated
        albums[position] = updated
    }

    func albums(sortedBy sort: AlbumSort) -> (albums: [AlbumCard], fellBack: Bool) {
        let keys = albums.map {
            AlbumOrderKey(
                id: $0.id, title: $0.title, year: $0.year, addedAt: $0.addedAt, listens: $0.listens,
                lastListened: $0.lastListened, bits: $0.bestBits, rate: $0.bestRate)
        }
        let order = AlbumSort.ordered(keys, by: sort)
        return (order.ids.compactMap { cards[$0] }, order.fellBack)
    }

    /// An album's playable tracks; or a playlist's (`playlist:<id>`), in its order, laid out in sides of their own.
    func tracks(of album: AlbumCard.ID) -> [TrackRow] {
        if let id = PlaylistCard.playlistID(fromCard: album) {
            guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
            let songs = snapshot.tracks(ids: playlist.songIDs)
            let layout = SideLayout(durations: songs.map(\.durationSeconds))
            return songs.enumerated().map { index, track in Self.row(track, side: layout.code(ofTrack: index)) }
        }
        let playable = snapshot.tracks(of: album).filter(\.isSupported)
        let layout = SideLayout(durations: playable.map(\.durationSeconds))
        return playable.enumerated().map { index, track in
            Self.row(track, side: layout.code(ofTrack: index))
        }
    }

    func hasTrack(_ track: TrackRow.ID) -> Bool { snapshot.track(track) != nil }

    func search(_ query: String, filter: SearchFilter) -> SearchResults {
        let chip = PFSearch.SearchFilter(rawValue: "\(filter)") ?? .all
        let found = snapshot.search(query, filter: chip, limit: 50)
        // Contract 2 has no artists group, so artist hits are dropped here; the Shelf finds an artist's albums anyway.
        let albumHits = found.albums.compactMap { cards[$0.id] }
        let trackHits = found.tracks.compactMap { hit -> TrackRow? in
            guard let track = snapshot.track(hit.id), track.isSupported else { return nil }
            return Self.row(track, side: side(of: track))
        }
        let elapsed = found.elapsed.components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        return SearchResults(albums: albumHits, tracks: trackHits, elapsedMilliseconds: milliseconds)
    }

    func queueItems(for tracks: [TrackRow.ID]) -> [QueueItem] {
        snapshot.tracks(ids: tracks).filter(\.isSupported).map {
            QueueItem(track: $0, artwork: library.artwork($0.artworkID))
        }
    }

    func importFiles(_ urls: [URL]) async -> (added: Int, rejected: [String]) {
        let result = await library.importFiles(urls)
        await sync()
        var lines = result.rejected.map { "\($0.fileName): \($0.message)" }
        if let error = result.error { lines.append("Library: \(error)") }
        return (result.added.count, lines)
    }

    /// Counted from the catalog, which knows each track's folder, so the dialog says exactly what `remove` will do. An
    /// album is its whole catalog track list, not only the playable songs the shelf shows (controller ruling RD-1):
    /// "delete the album" is asked to free the space, and a multichannel file left behind could never be reached.
    ///
    /// Three kinds, decided as the library decides them: the app's own copies are deleted; files inside the folder
    /// picked for downloads move to Recently Deleted; files in any other folder added in place stay, and only leave
    /// pointFlac. The download folder is judged by the file's folder, as the library judges it; its own path was
    /// resolved once, when it was found, so each track costs one resolution here.
    func removalPlan(album: AlbumCard.ID?, tracks: [TrackRow.ID]) -> RemovalPlan {
        var ids = album.map { snapshot.tracks(of: $0).map(\.id) } ?? []
        ids += tracks.filter { !ids.contains($0) }
        let downloads = downloadFolder()
        var plan = RemovalPlan()
        for track in snapshot.tracks(ids: ids) {
            plan.tracks.append(track.id)
            if track.isInLibraryFolder {
                plan.deletes += 1
                if !track.isSupported { plan.unplayableDeletes += 1 }
            } else if let downloads,
                FolderLocation.isInside(
                    track.url.deletingLastPathComponent(), comparableContainer: downloads.comparablePath)
            {
                plan.trashes += 1
                if !track.isSupported { plan.unplayableTrashes += 1 }
            } else {
                plan.removes += 1
                if !track.isSupported { plan.unplayableRemoves += 1 }
            }
        }
        return plan
    }

    /// The library is handed the download folder as it is now: the one the plan was counted with, unless the user
    /// chose another between the dialog and the tap. A file that would not move to Recently Deleted is kept, its song
    /// leaving pointFlac only; the outcome counts those, for the UI to say so.
    @discardableResult
    func remove(tracks: [TrackRow.ID]) async -> RemovalOutcome {
        let trashing = downloadFolder().map { TrashFolder($0.url, move: trash) }
        // A failure is logged by the library; either way the shelf then shows what the library holds.
        let removal = try? await library.remove(trackIDs: tracks, trashing: trashing)
        await sync()
        // The library took the deleted songs out of every playlist in the same write.
        await refreshPlaylists()
        return RemovalOutcome(trashFailures: removal?.trashFailures ?? 0)
    }

    // MARK: Playlists

    /// Reads the playlists again. A database failure reads as none (Favourites always exists): the list then stays
    /// as it was, so the shelf never shows Favourites gone.
    func refreshPlaylists() async {
        let fresh = await library.playlists()
        guard playlistWrites == 0 else { return }
        if !fresh.isEmpty { storedPlaylists = fresh }
        rebuildPlaylists()
    }

    /// Builds every playlist's card from the stored playlists and the catalog.
    private func rebuildPlaylists() {
        var stored = storedPlaylists
        // Before the first read (or after a failed one): Favourites, empty, so the strip always has it.
        if !stored.contains(where: { $0.kind == .favourites }) {
            stored.insert(
                Playlist(
                    id: Playlist.favouritesID, name: "Favourites", kind: .favourites,
                    colourID: PressingColour.favouritesDefault.rawValue, createdAt: .distantPast), at: 0)
        }
        let favourites = Set(stored.first { $0.kind == .favourites }?.trackIDs ?? [])
        if favourites != favouriteIDs { favouriteIDs = favourites }
        let built = stored.map(card(for:))
        if built != playlists { playlists = built }
    }

    /// A playlist as the app shows it: its playable songs in the catalog now, and the pressing they make.
    private func card(for playlist: Playlist) -> PlaylistCard {
        let songs = snapshot.tracks(ids: playlist.trackIDs).filter(\.isSupported)
        var covers: [String] = []
        for song in songs where !covers.contains(song.albumID) {
            covers.append(song.albumID)
            if covers.count == PressingLook.maxCovers { break }
        }
        let favourites = playlist.kind == .favourites
        let colour =
            PressingColour(rawValue: playlist.colourID) ?? (favourites ? .favouritesDefault : .smoke)
        let look = PressingLook(
            title: playlist.name, colour: colour, coverAlbumIDs: covers, songCount: songs.count,
            isFavourites: favourites, id: playlist.id)
        let best = songs.map(\.format).max {
            ($0.bitsPerSample, $0.sampleRate) < ($1.bitsPerSample, $1.sampleRate)
        }
        let album = AlbumCard(
            id: PlaylistCard.cardID(playlist.id), title: playlist.name, artist: "Playlist", year: nil, artwork: nil,
            trackCount: songs.count, bestFormat: best.map(LibraryAlbum.formatLabel) ?? "", addedAt: playlist.createdAt,
            listens: 0, lastListened: nil, bestBits: best?.bitsPerSample ?? 0, bestRate: best?.sampleRate ?? 0,
            pressing: look)
        return PlaylistCard(
            id: playlist.id, name: playlist.name, isFavourites: favourites, colour: colour,
            songIDs: songs.map(\.id), look: look, albumCard: album)
    }

    /// Applies `change` to the stored playlist `id` here and now, so the UI follows at once; `write` then makes the
    /// change in the library.
    private func changeLocally(_ id: String, _ change: (inout Playlist) -> Void) {
        guard let index = storedPlaylists.firstIndex(where: { $0.id == id }) else { return }
        change(&storedPlaylists[index])
        rebuildPlaylists()
    }

    /// Makes a playlist change in the library, then reads the playlists back: the library's word is final, a refusal
    /// included.
    private func write(_ change: @escaping @Sendable (Library) async throws -> Void) async {
        playlistWrites += 1
        do {
            try await change(library)
        } catch {
            Self.playlistLog.error("Playlist change refused: \(String(describing: error), privacy: .public)")
        }
        playlistWrites -= 1
        await refreshPlaylists()
    }

    func createPlaylist(name: String, colour: PressingColour) async -> PlaylistCard? {
        playlistWrites += 1
        let made = try? await library.createPlaylist(name: name, colourID: colour.rawValue)
        playlistWrites -= 1
        if let made, !storedPlaylists.contains(where: { $0.id == made.id }) { storedPlaylists.append(made) }
        rebuildPlaylists()
        await refreshPlaylists()
        return made.flatMap { made in playlists.first { $0.id == made.id } }
    }

    func renamePlaylist(_ id: PlaylistCard.ID, to name: String) async {
        guard let valid = Playlist.validName(name) else { return }
        changeLocally(id) { if $0.kind == .custom { $0.name = valid } }
        await write { try await $0.renamePlaylist(id: id, name: valid) }
    }

    func setPlaylistColour(_ id: PlaylistCard.ID, to colour: PressingColour) async {
        changeLocally(id) { $0.colourID = colour.rawValue }
        await write { try await $0.setPlaylistColour(id: id, colourID: colour.rawValue) }
    }

    func deletePlaylist(_ id: PlaylistCard.ID) async {
        guard id != Playlist.favouritesID else { return }
        storedPlaylists.removeAll { $0.id == id }
        rebuildPlaylists()
        await write { try await $0.deletePlaylist(id: id) }
    }

    @discardableResult
    func add(_ trackIDs: [TrackRow.ID], to playlist: PlaylistCard.ID) async -> Int {
        var added = 0
        changeLocally(playlist) { stored in
            for id in trackIDs where !stored.trackIDs.contains(id) {
                stored.trackIDs.append(id)
                added += 1
            }
        }
        await write { try await $0.addTracks(trackIDs, to: playlist) }
        return added
    }

    func remove(_ trackIDs: [TrackRow.ID], from playlist: PlaylistCard.ID) async {
        let gone = Set(trackIDs)
        changeLocally(playlist) { $0.trackIDs.removeAll { gone.contains($0) } }
        await write { try await $0.removeTracks(trackIDs, from: playlist) }
    }

    /// `songIDs` orders the songs the list shows; songs it leaves out (gone for now) keep their places among them.
    func reorder(_ playlist: PlaylistCard.ID, songIDs: [TrackRow.ID]) async {
        guard let stored = storedPlaylists.first(where: { $0.id == playlist }) else { return }
        let shown = Set(songIDs)
        guard shown.isSubset(of: Set(stored.trackIDs)), shown.count == songIDs.count else { return }
        var next = songIDs.makeIterator()
        let order = stored.trackIDs.map { shown.contains($0) ? (next.next() ?? $0) : $0 }
        changeLocally(playlist) { $0.trackIDs = order }
        await write { try await $0.reorderPlaylist(id: playlist, trackIDs: order) }
    }

    func isFavourite(_ trackID: TrackRow.ID) -> Bool { favouriteIDs.contains(trackID) }

    func toggleFavourite(_ trackID: TrackRow.ID) async {
        if isFavourite(trackID) {
            await remove([trackID], from: Playlist.favouritesID)
        } else {
            await add([trackID], to: Playlist.favouritesID)
        }
    }

    private static let playlistLog = Logger(subsystem: "io.github.kiraa06.pointflac", category: "playlists")

    /// The track's record code, from its album's side layout.
    private func side(of track: LibraryTrack) -> String? {
        let playable = snapshot.tracks(of: track.albumID).filter(\.isSupported)
        guard let index = playable.firstIndex(where: { $0.id == track.id }) else { return nil }
        return SideLayout(durations: playable.map(\.durationSeconds)).code(ofTrack: index)
    }

    /// Starts a background loudness scan when `catalog` holds a track the previous catalog did not: the first catalog
    /// with tracks in it (so once a launch), and any that an import, a download or a rescan grew. The scan's own
    /// results publish catalogs with the same tracks, which start nothing.
    ///
    /// The scan measures only what has no ReplayGain tag and was not measured yet, on `.background` tasks that yield
    /// to playback's decode thread, and never downloads from iCloud; with nothing to measure it is a database read. One
    /// asked for while another runs is merged into it (`Library.scanLoudness`), so imports in quick succession make
    /// one scan. Queues made after a track is measured carry its loudness; one already playing keeps what it had.
    private func measureNewTracks(in catalog: LibraryCatalog) {
        let ids = Set(catalog.tracks.keys)
        let grew = !ids.isSubset(of: knownTrackIDs)
        knownTrackIDs = ids
        guard grew else { return }
        let library = library
        scansRunning += 1
        Task.detached(priority: .background) { [weak self] in
            await library.scanLoudness { [weak self] done, total in
                Task { @MainActor [weak self] in self?.scanProgressed(done: done, total: total) }
            }
            await self?.scanReturned()
        }
    }

    /// The scan's `progress(done, total)`, hopped to the main actor. A report that arrives after every call returned
    /// is late, and dropped.
    private func scanProgressed(done: Int, total: Int) {
        guard scansRunning > 0 else { return }
        let next = total > 0 ? LoudnessScanProgress(done: min(done, total), total: total) : nil
        if next != loudnessScan { loudnessScan = next }
    }

    private func scanReturned() {
        scansRunning = max(scansRunning - 1, 0)
        if scansRunning == 0 { loudnessScan = nil }
    }

    /// A track still in iCloud is listed and playable (the player fetches it first, spec §4.7); its format says so.
    static func row(_ track: LibraryTrack, side: String?) -> TrackRow {
        TrackRow(
            id: track.id, title: track.title,
            artist: track.displayArtist.isEmpty ? "Unknown artist" : track.displayArtist,
            album: track.album.isEmpty ? AlbumGrouping.unknownAlbum : track.album,
            durationSeconds: track.durationSeconds,
            format: track.formatLabel + (track.isCloudPending ? " · iCloud" : ""), side: side, albumID: track.albumID)
    }
}

/// What the library knows of its playable tracks' loudness (spec §4.8, ReplayGain): tag values, the scan's own
/// measurements, and neither yet.
struct LoudnessSummary: Equatable, Sendable {
    /// With a ReplayGain tag, track or album: played from the tag.
    var tagged = 0
    /// Without a tag, but measured by the scan (including a track measured as silent, which gets no gain).
    var measured = 0
    /// Neither: not reached by a scan yet, in iCloud, or unreadable (the catalog can't tell which), shown as "Not
    /// measured". These play at 0 dB.
    var pending = 0

    init() {}

    init(_ tracks: some Sequence<LibraryTrack>) {
        for track in tracks {
            let l = track.loudness
            if l?.trackGainDb != nil || l?.albumGainDb != nil {
                tagged += 1
            } else if l?.measuredPeak != nil {
                measured += 1
            } else {
                pending += 1
            }
        }
    }

    var total: Int { tagged + measured + pending }
}

/// A loudness scan's tracks measured so far and planned in all (`Library.scanLoudness`'s cumulative count).
struct LoudnessScanProgress: Equatable, Sendable {
    var done: Int
    var total: Int
}
