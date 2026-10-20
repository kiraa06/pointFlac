import Foundation

/// A source of canonical names for typeahead: a global registry such as MusicBrainz.
public protocol SuggestionRegistry: Sendable {
    /// Suggestions already known for `partial` (or for the longest cached prefix of it), without any I/O. Called on
    /// every keystroke, so it must be fast and synchronous.
    func cachedSuggestions(for partial: String) -> [Suggestion]?
    /// Live suggestions, emitted cumulatively as each registry request lands. Cancelling the consuming task cancels
    /// the requests.
    func suggestions(for partial: String) -> AsyncThrowingStream<[Suggestion], Error>
    /// Fills in what a picked suggestion still needs for searching, such as an album's track count.
    func resolve(_ suggestion: Suggestion) async throws -> ResolvedEntity
}

/// MusicBrainz as a ``SuggestionRegistry``.
///
/// One keystroke pause costs up to three requests, one per second: albums first (what Soulseek and the Archive are
/// searched for), then artists, then tracks. Each lands as its own emission, so the first registry rows appear
/// about a quarter second after typing stops.
public final class MusicBrainzRegistry: SuggestionRegistry {
    public let client: MusicBrainzClient
    /// The entity requests to run per query, in order.
    public let order: [MB.Entity]
    public let limit: Int
    private let cache = LRUCache<String, [Suggestion]>(capacity: 128)
    private let resolved = LRUCache<String, ResolvedEntity>(capacity: 128)

    public init(
        client: MusicBrainzClient = MusicBrainzClient(), order: [MB.Entity] = [.releaseGroup, .artist, .recording],
        limit: Int = 8
    ) {
        self.client = client
        self.order = order
        self.limit = limit
    }

    public func cachedSuggestions(for partial: String) -> [Suggestion]? {
        var key = FindText.fold(partial)
        // The exact phrase, else the longest cached prefix: "gorill" reuses "goril" while its own request is pending.
        while key.count >= 2 {
            if let hit = cache.value(for: key) { return hit }
            key.removeLast()
            key = key.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public func suggestions(for partial: String) -> AsyncThrowingStream<[Suggestion], Error> {
        let key = FindText.fold(partial)
        let typing = !partial.hasSuffix(" ")
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Suggestion].self)
        let task = Task { [client, order, limit, cache] in
            var collected: [Suggestion] = []
            var lastError: (any Error)?
            for entity in order {
                if Task.isCancelled { break }
                guard let query = Self.query(entity, partial, typing: typing) else { continue }
                do {
                    let response = try await client.search(entity, query: query, limit: limit)
                    collected.append(contentsOf: Self.suggestions(from: response, entity: entity))
                    continuation.yield(collected)
                } catch is CancellationError {
                    break
                } catch {
                    lastError = error
                }
            }
            if Task.isCancelled {
                continuation.finish(throwing: CancellationError())
                return
            }
            if !collected.isEmpty {
                cache.insert(collected, for: key)
                continuation.finish()
            } else {
                continuation.finish(throwing: lastError)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func resolve(_ suggestion: Suggestion) async throws -> ResolvedEntity {
        var entity = suggestion.entity
        guard entity.kind == .album, entity.trackCount == nil, let group = entity.releaseGroupID else {
            return entity
        }
        if let known = resolved.value(for: group) { return known }
        let response = try await client.search(
            .release, query: MusicBrainzQuery.releases(ofReleaseGroup: group), limit: 25)
        entity.trackCount = Self.usualTrackCount(response.releases ?? [])
        resolved.insert(entity, for: group)
        return entity
    }

    static func query(_ entity: MB.Entity, _ partial: String, typing: Bool) -> String? {
        switch entity {
        case .artist: MusicBrainzQuery.artist(partial, partial: typing)
        case .releaseGroup: MusicBrainzQuery.releaseGroup(partial, partial: typing)
        case .recording: MusicBrainzQuery.recording(partial, partial: typing)
        case .release: nil
        }
    }

    /// The track count most official releases of an album share; ties go to the shorter (standard) edition, so a
    /// complete standard edition is not reported as incomplete against a deluxe one.
    static func usualTrackCount(_ releases: [MB.Release]) -> Int? {
        let official = releases.filter { $0.status == "Official" }
        let pool = official.isEmpty ? releases : official
        var counts: [Int: Int] = [:]
        for release in pool {
            let count = release.trackCount ?? release.media?.compactMap(\.trackCount).reduce(0, +)
            if let count, count > 0 { counts[count, default: 0] += 1 }
        }
        return counts.max { lhs, rhs in lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value }?.key
    }

    static func suggestions(from response: MB.SearchResponse, entity: MB.Entity) -> [Suggestion] {
        switch entity {
        case .artist: (response.artists ?? []).map(suggestion(artist:))
        case .releaseGroup: releaseGroupSuggestions(response.releaseGroups ?? [])
        case .recording: dedupedRecordings(response.recordings ?? []).map(suggestion(recording:))
        case .release: []
        }
    }

    /// Album rows, plus one artist row per credited artist. The album request goes first, so this puts artist rows
    /// on screen a second before the artist request can; the artist request's rows later merge with them (same id).
    static func releaseGroupSuggestions(_ groups: [MB.ReleaseGroup]) -> [Suggestion] {
        var rows = groups.map(suggestion(releaseGroup:))
        var seen = Set<String>()
        for group in groups {
            guard let artist = group.artistCredit?.first?.artist, seen.insert(artist.id).inserted else { continue }
            let entity = ResolvedEntity(
                kind: .artist, artist: artist.name, artistCredit: artist.name, artistSortName: artist.sortName,
                artistAliases: aliasNames(artist.aliases), musicBrainzID: artist.id, artistMusicBrainzID: artist.id)
            let subtitle = ["Artist", artist.disambiguation].compactMap { $0 }.filter { !$0.isEmpty }
            rows.append(
                Suggestion(
                    id: "mb:artist:\(artist.id)", kind: .artist, title: artist.name,
                    subtitle: subtitle.joined(separator: " · "), source: Suggestion.Source.musicBrainz, entity: entity,
                    relevance: Double(group.score ?? 0) / 100 * 0.9))
        }
        return rows
    }

    static func suggestion(artist: MB.Artist) -> Suggestion {
        let subtitle = ["Artist", artist.disambiguation, artist.country].compactMap { $0 }.filter { !$0.isEmpty }
        let entity = ResolvedEntity(
            kind: .artist, artist: artist.name, artistCredit: artist.name, artistSortName: artist.sortName,
            artistAliases: aliasNames(artist.aliases), musicBrainzID: artist.id, artistMusicBrainzID: artist.id)
        return Suggestion(
            id: "mb:artist:\(artist.id)", kind: .artist, title: artist.name,
            subtitle: subtitle.joined(separator: " · "), source: Suggestion.Source.musicBrainz, entity: entity,
            relevance: Double(artist.score ?? 0) / 100)
    }

    static func suggestion(releaseGroup group: MB.ReleaseGroup) -> Suggestion {
        let credits = group.artistCredit ?? []
        let credit = MB.ArtistCredit.displayName(credits)
        let year = musicBrainzYear(group.firstReleaseDate)
        let type = ([group.primaryType] + (group.secondaryTypes ?? []).map { Optional($0) }).compactMap { $0 }
        let subtitle = [credit, year.map(String.init), type.first].compactMap { $0 }.filter { !$0.isEmpty }
        let primary = credits.first?.artist
        let entity = ResolvedEntity(
            kind: .album, artist: primary?.name ?? credit, artistCredit: credit, artistSortName: primary?.sortName,
            artistAliases: aliasNames(primary?.aliases), album: group.title, year: year,
            albumType: type.joined(separator: " + "), musicBrainzID: group.id, artistMusicBrainzID: primary?.id,
            releaseGroupID: group.id)
        return Suggestion(
            id: "mb:album:\(group.id)", kind: .album, title: group.title, subtitle: subtitle.joined(separator: " · "),
            source: Suggestion.Source.musicBrainz, entity: entity, relevance: Double(group.score ?? 0) / 100)
    }

    static func suggestion(recording: MB.Recording) -> Suggestion {
        let credits = recording.artistCredit ?? []
        let credit = MB.ArtistCredit.displayName(credits)
        let primary = credits.first?.artist
        let album = preferredRelease(recording.releases ?? [])
        let subtitle = [credit, album?.title].compactMap { $0 }.filter { !$0.isEmpty }
        let entity = ResolvedEntity(
            kind: .track, artist: primary?.name ?? credit, artistCredit: credit, artistSortName: primary?.sortName,
            artistAliases: aliasNames(primary?.aliases), album: album?.title, track: recording.title,
            year: musicBrainzYear(recording.firstReleaseDate), trackCount: album?.trackCount,
            albumType: album?.releaseGroup?.primaryType, musicBrainzID: recording.id, artistMusicBrainzID: primary?.id,
            releaseGroupID: album?.releaseGroup?.id)
        return Suggestion(
            id: "mb:track:\(recording.id)", kind: .track, title: recording.title,
            subtitle: subtitle.joined(separator: " · "), source: Suggestion.Source.musicBrainz, entity: entity,
            relevance: Double(recording.score ?? 0) / 100)
    }

    /// The release a track is best known from: a studio album over a compilation, single or DJ mix.
    static func preferredRelease(_ releases: [MB.Release]) -> MB.Release? {
        releases.first { release in
            release.releaseGroup?.primaryType == "Album" && (release.releaseGroup?.secondaryTypes ?? []).isEmpty
        } ?? releases.first { $0.releaseGroup?.primaryType == "Album" } ?? releases.first
    }

    /// One row per (title, credit): MusicBrainz lists every version of a song as its own recording.
    static func dedupedRecordings(_ recordings: [MB.Recording]) -> [MB.Recording] {
        var seen = Set<String>()
        return recordings.filter { recording in
            let credit = MB.ArtistCredit.displayName(recording.artistCredit ?? [])
            let key = FindText.fold(FindText.coreTitle(recording.title)) + "|" + FindText.fold(credit)
            return seen.insert(key).inserted
        }
    }

    /// Latin-script aliases only: folder names are matched after folding, and a Japanese alias never helps there.
    static func aliasNames(_ aliases: [MB.Alias]?) -> [String] {
        var names: [String] = []
        for alias in aliases ?? [] where alias.name.unicodeScalars.allSatisfy({ $0.value < 0x0250 }) {
            if !names.contains(alias.name) { names.append(alias.name) }
            if names.count == 8 { break }
        }
        return names
    }
}
