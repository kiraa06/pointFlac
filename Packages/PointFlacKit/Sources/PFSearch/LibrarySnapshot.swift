import PFCore

/// One library catalog with its search index: everything the shelf, the crate and search need, in one immutable,
/// thread-safe value the UI adapter can hold on the main actor (contract 2's `LibraryBrowsing`).
///
/// Build it off the main actor whenever the library publishes a new catalog; building indexes every album, artist and
/// track (tens of milliseconds at 10k tracks), while every query after that fits in a frame.
///
/// ```swift
/// for await catalog in library.changes() {
///     let snapshot = await Task.detached { LibrarySnapshot(catalog) }.value
///     self.snapshot = snapshot  // on the main actor
/// }
/// ```
public final class LibrarySnapshot: Sendable {
    public let catalog: LibraryCatalog
    public let index: SearchIndex

    public static let empty = LibrarySnapshot(.empty)

    public init(_ catalog: LibraryCatalog) {
        self.catalog = catalog
        self.index = SearchIndex(catalog)
    }

    /// On the shelf's order: artist, year, title.
    public var albums: [LibraryAlbum] { catalog.albums }

    public func album(_ id: String) -> LibraryAlbum? { catalog.album(id) }

    /// The album's tracks in playing order.
    public func tracks(of albumID: String) -> [LibraryTrack] { catalog.tracks(of: albumID) }

    /// The tracks for `ids` in that order, leaving out any deleted since: what a queue is made from, with
    /// `QueueItem(track:artwork:)` in PFAudio.
    public func tracks(ids: [String]) -> [LibraryTrack] { catalog.tracks(ids: ids) }

    public func track(_ id: String) -> LibraryTrack? { catalog.tracks[id] }

    /// Search results for the shelf's search field (spec §4.6). Map album hits through `album(_:)` and track hits
    /// through `track(_:)`.
    public func search(_ query: String, filter: SearchFilter = .all, limit: Int = 50) -> LibrarySearchResults {
        index.search(query, filter: filter, limit: limit)
    }

    /// Typeahead hits of any kind, best first; synchronous (stream E's library source).
    public func suggest(_ prefix: String, limit: Int) -> [LibraryHit] {
        index.suggest(prefix, limit: limit)
    }
}
