import Foundation
import Observation
import PFAudio
import PFCore
import PFDesign
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
@MainActor
@Observable
final class RealLibrary: LibraryBrowsing {
    private(set) var albums: [AlbumCard] = []
    /// The latest snapshot, for the debug views and the music finder.
    private(set) var snapshot: LibrarySnapshot = .empty

    @ObservationIgnored let library: Library
    @ObservationIgnored let box = SnapshotBox()
    @ObservationIgnored private var cards: [String: AlbumCard] = [:]
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// Album ID → cover ID, for the lazy cover loader.
    @ObservationIgnored private let covers = CoverIndex()
    /// The track IDs of the latest catalog, to tell when tracks come in (`measureNewTracks`).
    @ObservationIgnored private var knownTrackIDs: Set<String> = []

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
        measureNewTracks(in: snapshot.catalog)
        var built: [AlbumCard] = []
        var byID: [String: AlbumCard] = [:]
        var covers: [String: String] = [:]
        for album in snapshot.albums {
            let playable = snapshot.tracks(of: album.id).filter(\.isSupported)
            guard !playable.isEmpty else { continue }
            let card = AlbumCard(
                id: album.id, title: album.title, artist: album.artist, year: album.year, artwork: nil,
                trackCount: playable.count, bestFormat: album.formatLabel)
            built.append(card)
            byID[album.id] = card
            if let cover = album.artworkID { covers[album.id] = cover }
        }
        self.covers.replace(with: covers)
        cards = byID
        if built != albums { albums = built }
    }

    func tracks(of album: AlbumCard.ID) -> [TrackRow] {
        let playable = snapshot.tracks(of: album).filter(\.isSupported)
        let layout = SideLayout(durations: playable.map(\.durationSeconds))
        return playable.enumerated().map { index, track in
            Self.row(track, side: layout.code(ofTrack: index))
        }
    }

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
    func removalPlan(album: AlbumCard.ID?, tracks: [TrackRow.ID]) -> RemovalPlan {
        var ids = album.map { snapshot.tracks(of: $0).map(\.id) } ?? []
        ids += tracks.filter { !ids.contains($0) }
        var plan = RemovalPlan()
        for track in snapshot.tracks(ids: ids) {
            plan.tracks.append(track.id)
            if track.isInLibraryFolder {
                plan.deletes += 1
                if !track.isSupported { plan.unplayableDeletes += 1 }
            } else {
                plan.removes += 1
                if !track.isSupported { plan.unplayableRemoves += 1 }
            }
        }
        return plan
    }

    func remove(tracks: [TrackRow.ID]) async {
        // A failure is logged by the library; either way the shelf then shows what the library holds.
        _ = try? await library.remove(trackIDs: tracks)
        await sync()
    }

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
        Task.detached(priority: .background) {
            await library.scanLoudness { _, _ in }
        }
    }

    /// A track still in iCloud is listed and playable (the player fetches it first, spec §4.7); its format says so.
    static func row(_ track: LibraryTrack, side: String?) -> TrackRow {
        TrackRow(
            id: track.id, title: track.title,
            artist: track.displayArtist.isEmpty ? "Unknown artist" : track.displayArtist,
            album: track.album.isEmpty ? AlbumGrouping.unknownAlbum : track.album,
            durationSeconds: track.durationSeconds,
            format: track.formatLabel + (track.isCloudPending ? " · iCloud" : ""), side: side)
    }
}
