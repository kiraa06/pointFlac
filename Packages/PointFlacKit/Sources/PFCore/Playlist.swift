import Foundation

/// A playlist: Favourites, which is always there, or one the user named (spec "Playlists as custom pressings" §5).
///
/// `trackIDs` are soft references to library tracks, in the playlist's order. They are every ID the library stores for
/// the playlist, including songs whose file is gone for now: the app filters them to the current catalog, so a song
/// comes back into its playlists when its file does.
public struct Playlist: Sendable, Hashable, Identifiable {
    /// Favourites, or a playlist the user made.
    public enum Kind: String, Sendable, Hashable {
        case favourites
        case custom
    }

    /// Favourites' fixed ID. Every other playlist's ID is a lower-case UUID.
    public static let favouritesID = "favourites"
    /// The longest name, in characters, after trimming.
    public static let maxNameLength = 60

    public var id: String
    public var name: String
    public var kind: Kind
    /// The pressing colour's ID (`ruby`, `amber`, …). The library stores it as given; the app knows the colours.
    public var colourID: String
    public var createdAt: Date
    public var trackIDs: [String]

    public init(id: String, name: String, kind: Kind, colourID: String, createdAt: Date, trackIDs: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.colourID = colourID
        self.createdAt = createdAt
        self.trackIDs = trackIDs
    }

    /// The name a playlist is stored under: `name` with surrounding spaces and newlines trimmed, when that leaves 1 to
    /// `maxNameLength` characters, at least one of them visible (not a zero-width or other ignorable character);
    /// otherwise nil. Duplicate names are allowed.
    public static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = trimmed.unicodeScalars.contains {
            !$0.properties.isDefaultIgnorableCodePoint && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return visible && (1...maxNameLength).contains(trimmed.count) ? trimmed : nil
    }
}

/// Why the library refused a playlist change.
public enum PlaylistError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No playlist has that ID; or, for a reorder, the IDs given are not exactly the playlist's songs.
    case notFound
    /// Favourites can't be renamed or deleted.
    case favouritesIsFixed
    /// The name, trimmed, is empty or longer than `Playlist.maxNameLength` characters.
    case invalidName
    /// The colour ID is empty.
    case invalidColour

    public var description: String {
        switch self {
        case .notFound: "No such playlist, or not its songs"
        case .favouritesIsFixed: "Favourites can't be renamed or deleted"
        case .invalidName: "A playlist name is 1 to \(Playlist.maxNameLength) characters"
        case .invalidColour: "A playlist needs a colour"
        }
    }
}
