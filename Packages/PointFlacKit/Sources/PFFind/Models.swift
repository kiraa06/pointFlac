/// One typeahead row. The App-layer `Suggestion` of contract 3 is this minus ``entity`` and ``relevance``, so the
/// controller's adapter is a field copy.
public struct Suggestion: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case artist, album, track
    }

    /// Where a suggestion came from; the raw values are the strings contract 3 shows in the UI.
    public enum Source {
        public static let library = "library"
        public static let musicBrainz = "musicbrainz"
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    /// ``Source/library`` or ``Source/musicBrainz``.
    public var source: String
    /// The canonical thing this row stands for; the planners work from it, never from the typed text.
    public var entity: ResolvedEntity
    /// The ranker's score for the query that produced this row, in 0…1 (higher first).
    public var relevance: Double

    public init(
        id: String, kind: Kind, title: String, subtitle: String, source: String, entity: ResolvedEntity,
        relevance: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.entity = entity
        self.relevance = relevance
    }
}

/// A canonical artist, album or track, as resolved from the library or MusicBrainz.
public struct ResolvedEntity: Sendable, Hashable, Codable {
    public var kind: Suggestion.Kind
    /// The primary credited artist ("Gorillaz" for "Gorillaz featuring De La Soul"). For an artist, its name.
    public var artist: String
    /// The full credit as displayed ("Gorillaz featuring De La Soul").
    public var artistCredit: String?
    public var artistSortName: String?
    /// Other names the artist is known by (MusicBrainz aliases). Used when matching folder names.
    public var artistAliases: [String]
    public var album: String?
    public var track: String?
    public var year: Int?
    /// Tracks on the album's usual edition, when known. Drives "complete album" detection.
    public var trackCount: Int?
    /// "Album", "EP", "Single"…, from MusicBrainz.
    public var albumType: String?
    /// The MusicBrainz ID of this entity (artist, release group or recording), when known.
    public var musicBrainzID: String?
    public var artistMusicBrainzID: String?
    /// The release group of the album (for an album, or the album a track appears on).
    public var releaseGroupID: String?

    public init(
        kind: Suggestion.Kind, artist: String, artistCredit: String? = nil, artistSortName: String? = nil,
        artistAliases: [String] = [], album: String? = nil, track: String? = nil, year: Int? = nil,
        trackCount: Int? = nil, albumType: String? = nil, musicBrainzID: String? = nil,
        artistMusicBrainzID: String? = nil, releaseGroupID: String? = nil
    ) {
        self.kind = kind
        self.artist = artist
        self.artistCredit = artistCredit
        self.artistSortName = artistSortName
        self.artistAliases = artistAliases
        self.album = album
        self.track = track
        self.year = year
        self.trackCount = trackCount
        self.albumType = albumType
        self.musicBrainzID = musicBrainzID
        self.artistMusicBrainzID = artistMusicBrainzID
        self.releaseGroupID = releaseGroupID
    }

    /// The name this entity is shown and matched by: the artist, album or track title.
    public var title: String {
        switch kind {
        case .artist: artist
        case .album: album ?? artist
        case .track: track ?? artist
        }
    }

    /// Every name the artist goes by, for matching against paths.
    public var artistNames: [String] {
        var names = [artist]
        if let artistSortName, artistSortName != artist { names.append(artistSortName) }
        names.append(contentsOf: artistAliases)
        return names
    }
}

/// One local-library match, supplied by stream A's index through the engine's injected closure.
public struct LibraryHit: Sendable, Hashable {
    public var id: String
    public var kind: Suggestion.Kind
    public var title: String
    public var artist: String
    public var album: String?
    public var year: Int?
    public var trackCount: Int?

    public init(
        id: String, kind: Suggestion.Kind, title: String, artist: String, album: String? = nil, year: Int? = nil,
        trackCount: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.trackCount = trackCount
    }
}

/// One remote file as a search provider reports it. The controller maps stream B's `RemoteTrack` onto this, so
/// `PFFind` never depends on `PFDownloads`.
public struct CandidateFile: Sendable, Hashable {
    /// The full remote path. Soulseek uses backslashes; forward slashes work too.
    public var path: String
    public var sizeBytes: Int64?
    public var bitsPerSample: Int?
    public var sampleRate: Int?
    public var peer: String?
    public var freeSlot: Bool?
    /// The peer's advertised upload speed in bytes per second.
    public var speed: Int?
    public var queueLength: Int?

    public init(
        path: String, sizeBytes: Int64? = nil, bitsPerSample: Int? = nil, sampleRate: Int? = nil,
        peer: String? = nil, freeSlot: Bool? = nil, speed: Int? = nil, queueLength: Int? = nil
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.bitsPerSample = bitsPerSample
        self.sampleRate = sampleRate
        self.peer = peer
        self.freeSlot = freeSlot
        self.speed = speed
        self.queueLength = queueLength
    }
}
