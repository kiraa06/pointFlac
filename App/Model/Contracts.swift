import Foundation
import PFAudio
import PFCore

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
    /// them.
    func remove(tracks: [TrackRow.ID]) async
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
    /// How many of `deletes` pointFlac can't play.
    var unplayableDeletes = 0
    /// How many of `removes` pointFlac can't play.
    var unplayableRemoves = 0
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
    /// One of spec §4.7's states, as words: "Queued", "Downloading", "Validating", "Saving", "Done", "Failed: …".
    let state: String
    /// 0...1 while transferring; nil when indeterminate or finished.
    let progress: Double?
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
