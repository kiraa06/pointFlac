import Foundation
import PFAudio
import PFCore
import PFDesign

// Contracts 2 and 3 of the overnight build (owned by stream D). The UI codes only against these protocols, never
// against the library's or the downloaders' concrete types, so each side can change without the other noticing. The
// controller writes the adapters; `RealLibrary` and `RealMusicFinder` (App/Integration) are those adapters; `MockMusicFinder` remains for UI tests.

/// An album as the shelf shows it.
struct AlbumCard: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: Int?
    /// Cover art as image file data. Nil draws the album's generated sleeve.
    let artwork: Data?
    let trackCount: Int
    /// The best format among its tracks, e.g. "FLAC 24/96".
    let bestFormat: String
    /// When the newest of its tracks was added to the library.
    let addedAt: Date
    /// Listens summed over its tracks (`ListenRule` decides what counts).
    let listens: Int
    /// The latest listen of any of its tracks; nil if none was ever listened to.
    let lastListened: Date?
    /// Bit depth and sample rate (Hz) of the best format, for the Hi-res first sort.
    let bestBits: Int
    let bestRate: Int
    /// A playlist's custom pressing, when the card is a playlist's (`playlist:<id>`, spec "Playlists as custom
    /// pressings" §5); nil for an album. The deck, the hand-off and the cover draw it in place of the album's record.
    var pressing: PressingLook? = nil
}

/// A song as search and the shelf list it.
struct TrackRow: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Double
    /// e.g. "FLAC 24/96".
    let format: String
    /// The record code, e.g. "A2", when the library has laid the album out.
    let side: String?
    /// The song's own album: a playlist's songs come from many, and each shows its own cover.
    var albumID: String? = nil
}

/// A playlist as the app shows it: Favourites, or one the user named (spec "Playlists as custom pressings").
struct PlaylistCard: Identifiable, Hashable {
    /// The playlist's own ID: `favourites`, or a lower-case UUID. Its card's is `playlist:<id>`.
    let id: String
    let name: String
    let isFavourites: Bool
    let colour: PressingColour
    /// Its songs in the catalog now that pointFlac can play, in the playlist's order. A song whose file is gone for
    /// now is left out until it returns; the library keeps it.
    let songIDs: [TrackRow.ID]
    /// How its pressing is drawn.
    let look: PressingLook
    /// The playlist as the player takes it: a card with the ID `playlist:<id>` and `pressing` set, so the hand-off, the
    /// deck, the sides and Up Next play it as they play an album.
    let albumCard: AlbumCard

    var songCount: Int { songIDs.count }
}

struct SearchResults {
    var albums: [AlbumCard]
    var tracks: [TrackRow]
    /// How long the search took, shown next to the field: the "instant" claim, measured.
    var elapsedMilliseconds: Double
}

/// The Shelf's filter chips (spec §4.6): All · Albums · Songs · 24-bit+ · 32-bit · ≥96 kHz.
enum SearchFilter: CaseIterable {
    case all, albums, songs, hiRes24, bit32, rate96
}

/// The local library, as the UI needs it.
@MainActor protocol LibraryBrowsing: AnyObject {
    /// Every album, in shelf order.
    var albums: [AlbumCard] { get }
    /// The albums in `sort`'s order. `fellBack` is true when Most played had no listens to go by and the order is Last
    /// added instead.
    func albums(sortedBy sort: AlbumSort) -> (albums: [AlbumCard], fellBack: Bool)
    /// Counts one listen of `trackID` at `date`: the library stores it and the albums' counts follow at once, with no
    /// new catalog.
    func recordListen(trackID: TrackRow.ID, at date: Date) async
    /// An album's tracks, in album order.
    func tracks(of album: AlbumCard.ID) -> [TrackRow]
    /// Whether the library still has `track`: a lookup, cheap enough for a view's body.
    func hasTrack(_ track: TrackRow.ID) -> Bool
    /// Synchronous, because local results must be on screen within the frame of the keystroke (spec §8).
    func search(_ query: String, filter: SearchFilter) -> SearchResults
    /// What the player needs to play these tracks, in the order given.
    func queueItems(for tracks: [TrackRow.ID]) -> [QueueItem]
    /// Imports files picked in Files; `rejected` holds one line per refused file ("name: reason").
    func importFiles(_ urls: [URL]) async -> (added: Int, rejected: [String])
    /// What removing `album` (every track it has, the songs pointFlac can't play included) plus `tracks` would do,
    /// before the user confirms.
    func removalPlan(album: AlbumCard.ID?, tracks: [TrackRow.ID]) -> RemovalPlan
    /// Removes `tracks` (a plan's) as `removalPlan` described, and returns once the shelf shows the library without
    /// them, saying what the plan could not promise: files that would not move to Recently Deleted.
    @discardableResult
    func remove(tracks: [TrackRow.ID]) async -> RemovalOutcome

    // Playlists (spec "Playlists as custom pressings" §5). The list follows every change at once, and the catalog: a
    // song whose file is gone leaves its playlists' lists until it returns. A change the library refuses (a name it
    // won't take, Favourites renamed or deleted) leaves the list as the library has it.

    /// Favourites first, then the others in the order they were made. Never without Favourites.
    var playlists: [PlaylistCard] { get }
    /// Makes an empty playlist; nil if the library refused it.
    func createPlaylist(name: String, colour: PressingColour) async -> PlaylistCard?
    func renamePlaylist(_ id: PlaylistCard.ID, to name: String) async
    func setPlaylistColour(_ id: PlaylistCard.ID, to colour: PressingColour) async
    /// Deletes a playlist, never its songs. Favourites can't be deleted.
    func deletePlaylist(_ id: PlaylistCard.ID) async
    /// Appends songs, each once: those it holds already are skipped. Returns how many were added.
    @discardableResult
    func add(_ trackIDs: [TrackRow.ID], to playlist: PlaylistCard.ID) async -> Int
    /// Takes songs out of a playlist. The songs stay in the library.
    func remove(_ trackIDs: [TrackRow.ID], from playlist: PlaylistCard.ID) async
    /// Puts a playlist's songs (as `songIDs` lists them) in this order.
    func reorder(_ playlist: PlaylistCard.ID, songIDs: [TrackRow.ID]) async
    /// Whether the song is in Favourites: a lookup, cheap enough for a view's body.
    func isFavourite(_ trackID: TrackRow.ID) -> Bool
    /// Adds the song to Favourites, or takes it out.
    func toggleFavourite(_ trackID: TrackRow.ID) async
}

/// What deleting an album or a song would do, worked out before the user confirms. The plan names the tracks it
/// counted, and the deletion is given exactly those, so the dialog can never promise one thing and do another.
struct RemovalPlan: Equatable {
    /// Every track the deletion takes. An album's include the songs pointFlac can't play (multichannel), which the
    /// shelf never lists: left behind, they would stay on the iPhone where nothing in the app can reach them.
    var tracks: [TrackRow.ID] = []
    /// Songs deleted from this iPhone: the app's own copies.
    var deletes = 0
    /// Songs only removed from pointFlac: files in folders added in place, which stay where they are.
    var removes = 0
    /// Songs whose file moves to Recently Deleted in Files, where it can be restored for 30 days: those in the folder
    /// picked for downloads (Settings → Downloads).
    var trashes = 0
    /// How many of `deletes` pointFlac can't play.
    var unplayableDeletes = 0
    /// How many of `removes` pointFlac can't play.
    var unplayableRemoves = 0
    /// How many of `trashes` pointFlac can't play.
    var unplayableTrashes = 0
}

/// What a removal did that its plan could not promise.
struct RemovalOutcome: Equatable {
    /// Songs whose file should have moved to Recently Deleted but would not (a provider without a trash, an error).
    /// They left pointFlac all the same, and their file stays in its folder.
    var trashFailures = 0

    /// The line the UI shows when files could not move to Recently Deleted; nil when every one did.
    var note: String? {
        switch trashFailures {
        case 0: nil
        case 1: "Couldn't move the file to Recently Deleted. It stays in its folder."
        default: "Couldn't move \(trashFailures) files to Recently Deleted. They stay in their folder."
        }
    }
}

/// Finding and downloading music from the online providers.
@MainActor protocol MusicFinding: AnyObject {
    var providers: [(id: String, name: String)] { get }
    /// Batches of results as they arrive; the stream finishes when the provider is done.
    func search(_ query: String, provider: String) -> AsyncStream<[RemoteResultRow]>
    func download(_ row: RemoteResultRow)
    var downloads: [DownloadRow] { get }
    /// Stops a queued or running download; its partial file is discarded.
    func cancelDownload(_ id: DownloadRow.ID)
    /// Stops a queued, waiting or running download and keeps its partial file, for `resumeDownload`.
    func pauseDownload(_ id: DownloadRow.ID)
    /// Queues a paused download again; it continues from its partial file.
    func resumeDownload(_ id: DownloadRow.ID)
    /// Pauses every download that can be paused.
    func pauseAllDownloads()
    /// Resumes every paused download.
    func resumeAllDownloads()
    /// Cancels every download still under way or paused. Songs already downloaded stay in the library.
    func cancelAllDownloads()
    /// Starts a failed or cancelled download again.
    func retryDownload(_ id: DownloadRow.ID)
    /// Takes a finished, failed or cancelled row off the list. A finished download's song stays in the library.
    func removeDownload(_ id: DownloadRow.ID)
    /// Takes every finished download (`finished`), and every failed or cancelled one (`failed`), off the list.
    func clearDownloads(finished: Bool, failed: Bool)

    // Contract 3: typeahead.
    /// Emits library hits at once, then the registry's (MusicBrainz) as they arrive. Each emission is the full list.
    func suggestions(_ partial: String) -> AsyncStream<[Suggestion]>
    /// Searches with a resolved entity rather than the typed words.
    func search(_ suggestion: Suggestion, provider: String) -> AsyncStream<[RemoteResultRow]>
}

/// Cancel, retry, remove and clear for the Downloads list: the integration's additions to contract 2. Defaulted to
/// no-ops, so the mock and any other finder written to the original shape still conform.
extension MusicFinding {
    func cancelDownload(_ id: DownloadRow.ID) {}
    func pauseDownload(_ id: DownloadRow.ID) {}
    func resumeDownload(_ id: DownloadRow.ID) {}
    func pauseAllDownloads() {}
    func resumeAllDownloads() {}
    func cancelAllDownloads() {}
    func retryDownload(_ id: DownloadRow.ID) {}
    func removeDownload(_ id: DownloadRow.ID) {}
    func clearDownloads(finished: Bool, failed: Bool) {}
}

struct RemoteResultRow: Identifiable, Hashable, Sendable {
    let id: String
    let provider: String
    let title: String
    let subtitle: String
    /// e.g. "FLAC 24/96".
    let format: String
    /// e.g. "412 MB".
    let sizeText: String
    /// Internet Archive's licence for the item (the provider's `detail["licence"]`), shown on the row. Stream D's
    /// addition to contract 2: optional and defaulted, so adapters written to the original shape still compile.
    let licence: String?
    /// The songs inside a folder or album row, each a row of its own with its own Download (a single file has none).
    /// The integration's addition to contract 2, defaulted like `licence`.
    let children: [RemoteResultRow]

    init(
        id: String, provider: String, title: String, subtitle: String, format: String, sizeText: String,
        licence: String? = nil, children: [RemoteResultRow] = []
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.subtitle = subtitle
        self.format = format
        self.sizeText = sizeText
        self.licence = licence
        self.children = children
    }
}

struct DownloadRow: Identifiable, Hashable {
    let id: String
    let title: String
    /// One of spec §4.7's states, as words: "Queued", "Downloading", "Validating", "Saving", "Done", "Failed: …",
    /// "Paused" or "Paused · 42%".
    let state: String
    /// 0...1 while transferring; nil when indeterminate, paused or finished.
    let progress: Double?
    /// Shown in place of a finished download's "Done" when it was saved somewhere other than asked: "Saved in
    /// pointFlac (folder unavailable)".
    var note: String? = nil
    /// The library track a finished download became, so its row can delete the song; nil until then, or when the
    /// library could not say.
    var trackID: TrackRow.ID? = nil

    /// Where the download is, for the controls its row offers. Read from the state's words, which both finders share.
    enum Phase: Equatable {
        /// Queued, waiting at its source or downloading: it can be paused or cancelled.
        case transferring
        case paused
        /// Validating or saving: moments from the library, too late to pause.
        case finishing
        /// Published: the song is in the library.
        case done
        /// Failed or cancelled: it can be retried or removed.
        case stopped
    }

    var phase: Phase {
        if state.hasPrefix("Done") { return .done }
        if state.hasPrefix("Failed") || state.hasPrefix("Cancelled") { return .stopped }
        if state.hasPrefix("Paused") { return .paused }
        if state.hasPrefix("Queued") || state.hasPrefix("Waiting") || state.hasPrefix("Downloading") {
            return .transferring
        }
        return .finishing
    }
}

/// A typeahead suggestion (contract 3).
struct Suggestion: Identifiable, Hashable {
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    /// "library" or "musicbrainz".
    let source: String

    enum Kind {
        case artist, album, track
    }
}
