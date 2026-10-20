import Foundation
import PFCore

extension QueueItem {
    /// A queue entry for a library track (PFCore's `LibraryTrack`), so the app can queue search results and albums
    /// without PFLibrary or PFSearch depending on the player (spec §5.1: features meet only through PFCore).
    ///
    /// The track's ID becomes the queue item's ID, so the player's events name the same track the library does.
    public init(track: LibraryTrack, artwork: Data? = nil) {
        self.init(
            id: track.id, url: track.url, title: track.title, artist: track.displayArtist, album: track.album,
            format: track.format, totalFrames: track.totalFrames, artwork: artwork)
    }
}
