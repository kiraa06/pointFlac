import Foundation

/// A track in the library, as the UI, search and the player see it.
///
/// The library keeps these in its database; this is the immutable value that leaves it. `id` is the file's content
/// identity (spec §5.4), not its path, so a rename, a move or a tag edit keeps it, and with it anything keyed on the
/// track.
public struct LibraryTrack: Sendable, Hashable, Identifiable {
    public var id: String
    /// Where the file is for this launch. Resolved from its folder each launch, because iOS moves the app's container
    /// on update, so a stored absolute path would go stale.
    public var url: URL
    /// The TITLE tag, else the file name without its extension.
    public var title: String
    /// The ARTIST tag, or empty.
    public var artist: String
    /// The ALBUMARTIST tag, or empty.
    public var albumArtist: String
    /// The ALBUM tag, or empty.
    public var album: String
    /// The album this track was grouped into (`AlbumGrouping`).
    public var albumID: String
    public var discNumber: Int?
    public var trackNumber: Int?
    public var year: Int?
    public var format: AudioFormat
    /// Total frames from STREAMINFO, or 0 when the encoder did not record them.
    public var totalFrames: Int64
    /// The content hash of the track's front cover in the artwork store, when it has one.
    public var artworkID: String?
    /// The file was evicted to iCloud: still in the library, but its bytes must download before it plays (§4.7).
    public var isCloudPending: Bool
    /// The file is the app's own copy, in its library folder (an import or a download): removing the track deletes it.
    /// False for a file in a folder added in place, which is the user's and is never deleted; removing that track only
    /// takes it out of the library. Carried here so the UI can say which will happen before it asks. It has no default,
    /// so no construction can leave it to chance: the delete dialog's promise rests on it.
    public var isInLibraryFolder: Bool
    /// What the library knows about the track's loudness (ReplayGain tags and the background R128 scan), or nil when it
    /// knows nothing. It has no default, like `isInLibraryFolder`: a construction cannot forget it.
    public var loudness: TrackLoudness?

    public init(
        id: String, url: URL, title: String, artist: String, albumArtist: String, album: String, albumID: String,
        discNumber: Int?, trackNumber: Int?, year: Int?, format: AudioFormat, totalFrames: Int64,
        artworkID: String?, isCloudPending: Bool = false, isInLibraryFolder: Bool, loudness: TrackLoudness?
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.albumID = albumID
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.year = year
        self.format = format
        self.totalFrames = totalFrames
        self.artworkID = artworkID
        self.isCloudPending = isCloudPending
        self.isInLibraryFolder = isInLibraryFolder
        self.loudness = loudness
    }

    /// The track's length in seconds; zero when its frame count is unknown.
    public var durationSeconds: Double {
        guard totalFrames > 0, format.sampleRate > 0 else { return 0 }
        return Double(totalFrames) / Double(format.sampleRate)
    }

    /// Whether v1 plays it (`ChannelPolicy`): a multichannel file is listed but never played.
    public var isSupported: Bool { ChannelPolicy.isPlayable(format) }

    /// The artist to show: the track's own, else the album artist.
    public var displayArtist: String { artist.isEmpty ? albumArtist : artist }

    /// For track rows: "FLAC 24/96", like the album's label.
    public var formatLabel: String { LibraryAlbum.formatLabel(format) }
}

/// A track's loudness, from two sources. Playback (Plan 4, Task 12) prefers the tags, then the measurement.
public struct TrackLoudness: Sendable, Hashable {
    /// `REPLAYGAIN_TRACK_GAIN` in dB.
    public var trackGainDb: Double?
    /// `REPLAYGAIN_TRACK_PEAK`, linear.
    public var trackPeak: Double?
    public var albumGainDb: Double?
    public var albumPeak: Double?
    /// The scan's integrated loudness of the track, in LUFS. Nil with `measuredPeak` set means measured, but there is
    /// no usable loudness (silent, or shorter than one 400 ms gating block): apply no gain from it.
    public var measuredLufs: Double?
    /// The scan's true peak of the track, linear (1.0 = full scale; 0 for silence). Set once the track is measured.
    public var measuredPeak: Double?
    /// The scan's loudness of the whole album, in LUFS (nil when it has no usable loudness), and its peak (the largest
    /// track peak), linear. Both nil when the album was not measured as a whole.
    public var albumMeasuredLufs: Double?
    public var albumMeasuredPeak: Double?

    public init(
        trackGainDb: Double? = nil, trackPeak: Double? = nil, albumGainDb: Double? = nil, albumPeak: Double? = nil,
        measuredLufs: Double? = nil, measuredPeak: Double? = nil, albumMeasuredLufs: Double? = nil,
        albumMeasuredPeak: Double? = nil
    ) {
        self.trackGainDb = trackGainDb
        self.trackPeak = trackPeak
        self.albumGainDb = albumGainDb
        self.albumPeak = albumPeak
        self.measuredLufs = measuredLufs
        self.measuredPeak = measuredPeak
        self.albumMeasuredLufs = albumMeasuredLufs
        self.albumMeasuredPeak = albumMeasuredPeak
    }

    /// True when nothing is known.
    public var isEmpty: Bool { self == TrackLoudness() }
}

/// An album derived from its tracks' tags. Albums are not stored: they are regrouped from the tracks whenever the
/// library changes, so they can never disagree with the tags.
public struct LibraryAlbum: Sendable, Hashable, Identifiable {
    public var id: String
    /// The ALBUM tag, or "Unknown Album".
    public var title: String
    /// The album artist, the tracks' common artist, "Various Artists" or "Unknown Artist".
    public var artist: String
    /// The earliest year among the tracks.
    public var year: Int?
    /// In playing order: disc, then track number, then title.
    public var trackIDs: [String]
    /// The highest-resolution format among the tracks: most bits, then highest rate.
    public var bestFormat: AudioFormat
    /// The first front cover in playing order.
    public var artworkID: String?

    public init(
        id: String, title: String, artist: String, year: Int?, trackIDs: [String], bestFormat: AudioFormat,
        artworkID: String?
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.trackIDs = trackIDs
        self.bestFormat = bestFormat
        self.artworkID = artworkID
    }

    /// For the crate caption and album cards: "FLAC 24/96", "FLAC 16/44.1".
    public var formatLabel: String { LibraryAlbum.formatLabel(bestFormat) }

    public static func formatLabel(_ format: AudioFormat) -> String {
        "FLAC \(format.bitsPerSample)/\(format.formattedRate.replacingOccurrences(of: " kHz", with: ""))"
    }
}

/// An immutable picture of the whole library: what the library publishes after every change, and what search indexes.
///
/// A value, so a reader on the main actor can hold one while the library builds the next off it.
public struct LibraryCatalog: Sendable {
    /// Sorted by artist, then year, then title, ignoring case and accents.
    public let albums: [LibraryAlbum]
    public let tracks: [String: LibraryTrack]
    private let albumIndex: [String: Int]

    public static let empty = LibraryCatalog(tracks: [])

    /// Groups `tracks` into albums by their `albumID` (`AlbumGrouping`).
    public init(tracks: [LibraryTrack]) {
        let grouped = AlbumGrouping.group(tracks)
        self.albums = grouped.albums
        var byID: [String: LibraryTrack] = [:]
        byID.reserveCapacity(grouped.tracks.count)
        for track in grouped.tracks { byID[track.id] = track }
        self.tracks = byID
        var index: [String: Int] = [:]
        for (position, album) in grouped.albums.enumerated() { index[album.id] = position }
        self.albumIndex = index
    }

    public func album(_ id: String) -> LibraryAlbum? {
        albumIndex[id].map { albums[$0] }
    }

    /// The album's tracks in playing order; empty for an unknown album.
    public func tracks(of albumID: String) -> [LibraryTrack] {
        album(albumID)?.trackIDs.compactMap { tracks[$0] } ?? []
    }

    /// The tracks for `ids`, in the order given. Unknown IDs (a track deleted since) are left out.
    public func tracks(ids: [String]) -> [LibraryTrack] {
        ids.compactMap { tracks[$0] }
    }
}

/// How tracks become albums (spec §4.6, §5.4).
///
/// The key is the album title plus whoever the album is by: the ALBUMARTIST tag when there is one, so a tagged
/// compilation stays one album however many artists it has; "Various Artists" for a file flagged COMPILATION=1;
/// otherwise the track's own artist. That is the rule rippers and taggers (EAC, XLD, MusicBrainz Picard) write tags
/// for, and it keeps a multi-disc set split over "CD1" and "CD2" folders together. A file with no ALBUM tag joins the
/// other untitled files by the same artist in its folder, rather than every untitled file in the library.
public enum AlbumGrouping {
    public static let unknownAlbum = "Unknown Album"
    public static let unknownArtist = "Unknown Artist"
    public static let variousArtists = "Various Artists"

    /// The grouping key of a track; stable as long as its tags (and, for an untitled album, its folder) are.
    public static func albumID(
        albumArtist: String, artist: String, album: String, compilation: Bool, folder: String
    ) -> String {
        let by = fold(!albumArtist.isEmpty ? albumArtist : compilation ? variousArtists : artist)
        let title = fold(album)
        let raw = title.isEmpty ? "untitled\u{1F}\(by)\u{1F}\(folder)" : "album\u{1F}\(by)\u{1F}\(title)"
        return StableHash.hex(of: Array(raw.utf8))
    }

    /// Builds the albums from `tracks` (each must already carry its `albumID`) and returns the tracks too.
    public static func group(_ tracks: [LibraryTrack]) -> (albums: [LibraryAlbum], tracks: [LibraryTrack]) {
        var members: [String: [LibraryTrack]] = [:]
        for track in tracks { members[track.albumID, default: []].append(track) }
        var albums: [LibraryAlbum] = []
        albums.reserveCapacity(members.count)
        for (id, group) in members {
            let ordered = group.sorted(by: playingOrder)
            let first = ordered[0]
            let title = ordered.first { !$0.album.isEmpty }?.album ?? unknownAlbum
            let artist = albumArtist(of: ordered)
            let year = ordered.compactMap(\.year).min()
            let best = ordered.map(\.format).max(by: lowerResolution) ?? first.format
            albums.append(
                LibraryAlbum(
                    id: id, title: title, artist: artist, year: year, trackIDs: ordered.map(\.id), bestFormat: best,
                    artworkID: ordered.lazy.compactMap(\.artworkID).first))
        }
        albums.sort(by: shelfOrder)
        return (albums, tracks)
    }

    /// Disc, then track number (untagged last), then title.
    public static func playingOrder(_ a: LibraryTrack, _ b: LibraryTrack) -> Bool {
        let discA = a.discNumber ?? 1
        let discB = b.discNumber ?? 1
        if discA != discB { return discA < discB }
        let numberA = a.trackNumber ?? .max
        let numberB = b.trackNumber ?? .max
        if numberA != numberB { return numberA < numberB }
        let order = a.title.localizedStandardCompare(b.title)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }

    /// Artist, then year, then title, the way a record shelf is filed.
    static func shelfOrder(_ a: LibraryAlbum, _ b: LibraryAlbum) -> Bool {
        let artist = a.artist.localizedStandardCompare(b.artist)
        if artist != .orderedSame { return artist == .orderedAscending }
        if a.year != b.year { return (a.year ?? .max) < (b.year ?? .max) }
        let title = a.title.localizedStandardCompare(b.title)
        return title == .orderedSame ? a.id < b.id : title == .orderedAscending
    }

    /// True when `a` has fewer bits, or as many bits and a lower rate, than `b`.
    public static func lowerResolution(_ a: AudioFormat, _ b: AudioFormat) -> Bool {
        a.bitsPerSample != b.bitsPerSample ? a.bitsPerSample < b.bitsPerSample : a.sampleRate < b.sampleRate
    }

    private static func albumArtist(of tracks: [LibraryTrack]) -> String {
        if let tagged = tracks.first(where: { !$0.albumArtist.isEmpty }) { return tagged.albumArtist }
        let artists = Set(tracks.map { fold($0.artist) }.filter { !$0.isEmpty })
        switch artists.count {
        case 0: return unknownArtist
        case 1: return tracks.first { !$0.artist.isEmpty }?.artist ?? unknownArtist
        default: return variousArtists
        }
    }

    /// Case-, accent- and width-insensitive, with runs of whitespace collapsed, so "Beyoncé " and "beyonce" group.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A short, stable, dependency-free hash for keys (FNV-1a 64, twice with different seeds → 128 bits, hex).
///
/// Not cryptographic, and not used where an adversary gains from a collision: album keys come from the user's own
/// tags. Content identity uses SHA-256 (PFLibrary).
public enum StableHash {
    public static func hex(of bytes: [UInt8]) -> String {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        var b: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in bytes {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            b = (b ^ UInt64(byte ^ 0x5A)) &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx%016llx", a, b)
    }
}
