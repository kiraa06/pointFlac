import Foundation
import Synchronization

/// The typeahead middleware between the search field and every source of names.
///
/// For each keystroke, ``suggestions(_:)`` returns a stream that emits cumulative, ranked snapshots:
/// 1. local library hits, yielded before the call returns, so the first row is on screen in the same frame;
/// 2. the same plus cached registry rows (the exact phrase, or the longest cached prefix of it), still synchronous;
/// 3. after a short debounce, live registry rows as each request lands.
///
/// A newer keystroke cancels the older stream's debounce and requests, so MusicBrainz only ever sees the phrase
/// the person paused on, and its one-request-per-second budget goes to what they actually want.
public final class TypeaheadEngine: Sendable {
    public typealias LibrarySearch = @Sendable (_ query: String, _ limit: Int) -> [LibraryHit]

    public struct Configuration: Sendable {
        /// The pause after the last keystroke before asking the registry. Short enough to feel live, long enough
        /// that steady typing never spends a request.
        public var debounce: Duration
        /// Fewer folded characters than this never reach the registry ("go" matches half of it).
        public var minimumRegistryCharacters: Int
        public var libraryLimit: Int
        public var maximumSuggestions: Int
        /// Registry rows scoring below this against the typed text are noise and dropped.
        public var minimumRegistryScore: Double
        /// Off sends nothing to any registry: library rows only (spec §5.8 privacy, the user's choice).
        public var registryEnabled: Bool

        public init(
            debounce: Duration = .milliseconds(250), minimumRegistryCharacters: Int = 3, libraryLimit: Int = 8,
            maximumSuggestions: Int = 12, minimumRegistryScore: Double = 0.35, registryEnabled: Bool = true
        ) {
            self.debounce = debounce
            self.minimumRegistryCharacters = minimumRegistryCharacters
            self.libraryLimit = libraryLimit
            self.maximumSuggestions = maximumSuggestions
            self.minimumRegistryScore = minimumRegistryScore
            self.registryEnabled = registryEnabled
        }
    }

    public let configuration: Configuration
    private let library: LibrarySearch
    private let registry: (any SuggestionRegistry)?
    private let inFlight = Mutex<Task<Void, Never>?>(nil)

    public init(
        library: @escaping LibrarySearch, registry: (any SuggestionRegistry)?,
        configuration: Configuration = Configuration()
    ) {
        self.library = library
        self.registry = registry
        self.configuration = configuration
    }

    /// Ranked suggestions for `partial`, emitted as they become known. See the type's documentation.
    public func suggestions(_ partial: String) -> AsyncStream<[Suggestion]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Suggestion].self, bufferingPolicy: .bufferingNewest(8))
        let configuration = configuration
        let local = library(partial, configuration.libraryLimit).map(Suggestion.init(libraryHit:))
        let ranker = SuggestionRanker(query: partial, configuration: configuration)
        continuation.yield(ranker.merge(library: local, registry: []))

        let folded = FindText.fold(partial)
        guard configuration.registryEnabled, let registry, folded.count >= configuration.minimumRegistryCharacters
        else {
            replaceInFlight(with: nil)
            continuation.finish()
            return stream
        }
        // Cached rows stay in every later snapshot too, so nothing on screen blinks out while live rows arrive.
        let cached = registry.cachedSuggestions(for: partial) ?? []
        if !cached.isEmpty {
            continuation.yield(ranker.merge(library: local, registry: cached))
        }
        let task = Task {
            defer { continuation.finish() }
            do {
                try await Task.sleep(for: configuration.debounce)
                for try await batch in registry.suggestions(for: partial) {
                    continuation.yield(ranker.merge(library: local, registry: batch + cached))
                }
            } catch {
                // Cancelled by a newer keystroke, or the registry is unreachable: the rows already shown stand.
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        replaceInFlight(with: task)
        return stream
    }

    /// The entity behind a picked suggestion, completed by the registry when it needs to be (an album's track count).
    public func resolve(_ suggestion: Suggestion) async -> ResolvedEntity {
        guard suggestion.source == Suggestion.Source.musicBrainz, let registry else { return suggestion.entity }
        return (try? await registry.resolve(suggestion)) ?? suggestion.entity
    }

    /// Cancels whatever the previous keystroke started.
    private func replaceInFlight(with task: Task<Void, Never>?) {
        let previous = inFlight.withLock { slot in
            let previous = slot
            slot = task
            return previous
        }
        previous?.cancel()
    }
}

extension Suggestion {
    /// A library hit as a suggestion row.
    public init(libraryHit hit: LibraryHit) {
        let subtitle: String
        let entity: ResolvedEntity
        switch hit.kind {
        case .artist:
            subtitle = "In your library"
            entity = ResolvedEntity(kind: .artist, artist: hit.title)
        case .album:
            subtitle = [hit.artist, hit.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
            entity = ResolvedEntity(
                kind: .album, artist: hit.artist, artistCredit: hit.artist, album: hit.title, year: hit.year,
                trackCount: hit.trackCount)
        case .track:
            subtitle = [hit.artist, hit.album].compactMap { $0 }.joined(separator: " · ")
            entity = ResolvedEntity(
                kind: .track, artist: hit.artist, artistCredit: hit.artist, album: hit.album, track: hit.title,
                year: hit.year)
        }
        self.init(
            id: "library:\(hit.id)", kind: hit.kind, title: hit.title, subtitle: subtitle,
            source: Suggestion.Source.library, entity: entity)
    }
}

/// Merges, dedupes and ranks suggestion rows for one query.
///
/// Scoring is fuzzy against the typed text, tried both as "title" and as "title + artist" in either order, because
/// people type "the mountain gorillaz" as often as "gorillaz the mountain". Library rows get a small boost (you
/// probably mean what you own) and win duplicates; MusicBrainz's own score only breaks ties.
public struct SuggestionRanker: Sendable {
    public let query: String
    public let configuration: TypeaheadEngine.Configuration
    private let queryTokens: [String]
    private let partial: Bool

    public init(query: String, configuration: TypeaheadEngine.Configuration = .init()) {
        self.query = query
        self.configuration = configuration
        self.queryTokens = FindText.tokens(query)
        self.partial = !query.hasSuffix(" ")
    }

    /// The ranked, deduplicated union of `library` and `registry` rows.
    public func merge(library: [Suggestion], registry: [Suggestion]) -> [Suggestion] {
        var byKey: [String: Suggestion] = [:]
        var order: [String] = []
        for row in library + registry {
            var scored = row
            scored.relevance = score(row)
            if row.source != Suggestion.Source.library, scored.relevance < configuration.minimumRegistryScore {
                continue
            }
            let key = Self.dedupeKey(row)
            if let existing = byKey[key] {
                byKey[key] = Self.preferred(existing, scored)
            } else {
                byKey[key] = scored
                order.append(key)
            }
        }
        let rows = order.compactMap { byKey[$0] }
        let ranked = rows.enumerated().sorted { lhs, rhs in
            lhs.element.relevance == rhs.element.relevance
                ? lhs.offset < rhs.offset : lhs.element.relevance > rhs.element.relevance
        }
        return ranked.prefix(configuration.maximumSuggestions).map(\.element)
    }

    /// The relevance of one row for this query, in roughly 0…1.
    public func score(_ row: Suggestion) -> Double {
        guard !queryTokens.isEmpty else { return row.source == Suggestion.Source.library ? 0.5 : 0 }
        let entity = row.entity
        let titleTokens = FindText.tokens(FindText.coreTitle(row.title))
        // The full credit, so "feel good inc de la soul" matches "Gorillaz featuring De La Soul" ("featuring" is a
        // stopword); for an artist row, every name it goes by.
        var names = [entity.artistCredit ?? entity.artist]
        if entity.artistCredit != nil, entity.artistCredit != entity.artist { names.append(entity.artist) }
        var primaryNames = names.count
        if row.kind == .artist {
            names = entity.artistNames
            primaryNames = entity.artistSortName == nil || entity.artistSortName == entity.artist ? 1 : 2
        }
        var best = 0.0
        for (index, name) in names.enumerated() {
            // An alias match counts for less: "gorill" should put Gorillaz above Lupe Fiasco ("Lupe the Gorilla").
            let weight = index < primaryNames ? 1 : 0.85
            let artistTokens = FindText.tokens(FindText.withoutLeadingArticle(name))
            let candidates: [[String]] =
                row.kind == .artist
                ? [FindText.tokens(name), artistTokens]
                : [titleTokens, titleTokens + artistTokens, artistTokens + titleTokens]
            for candidate in candidates {
                let value = FuzzyMatcher.score(
                    queryTokens: queryTokens, candidateTokens: candidate, lastIsPartial: partial)
                best = max(best, value * weight)
            }
        }
        var value = best
        if row.source == Suggestion.Source.library { value += 0.08 }
        if row.kind == .track { value -= 0.03 }
        if row.kind == .album, let type = entity.albumType {
            if type.contains("Compilation") || type.contains("Live") || type.contains("DJ-mix") {
                value -= 0.04
            } else if type.hasPrefix("Single") {
                value -= 0.03
            } else if type.hasPrefix("EP") {
                value -= 0.01
            }
        }
        if row.source == Suggestion.Source.musicBrainz {
            value += min(max(row.relevance, 0), 1) * 0.04
        }
        return value
    }

    /// Two rows are the same thing when kind, folded core title and folded primary artist agree.
    static func dedupeKey(_ row: Suggestion) -> String {
        let title = FindText.fold(FindText.coreTitle(row.title))
        let artist = row.kind == .artist ? "" : FindText.fold(FindText.withoutLeadingArticle(row.entity.artist))
        return "\(row.kind.rawValue)|\(title)|\(artist)"
    }

    /// Library wins a duplicate, but keeps what the registry knows (IDs, track count, aliases) for planning.
    static func preferred(_ lhs: Suggestion, _ rhs: Suggestion) -> Suggestion {
        let lhsLibrary = lhs.source == Suggestion.Source.library
        let rhsLibrary = rhs.source == Suggestion.Source.library
        guard lhsLibrary != rhsLibrary else { return lhs.relevance >= rhs.relevance ? lhs : rhs }
        var winner = lhsLibrary ? lhs : rhs
        let other = lhsLibrary ? rhs : lhs
        winner.entity.musicBrainzID = winner.entity.musicBrainzID ?? other.entity.musicBrainzID
        winner.entity.artistMusicBrainzID = winner.entity.artistMusicBrainzID ?? other.entity.artistMusicBrainzID
        winner.entity.releaseGroupID = winner.entity.releaseGroupID ?? other.entity.releaseGroupID
        winner.entity.trackCount = winner.entity.trackCount ?? other.entity.trackCount
        winner.entity.albumType = winner.entity.albumType ?? other.entity.albumType
        if winner.entity.artistAliases.isEmpty { winner.entity.artistAliases = other.entity.artistAliases }
        winner.relevance = max(winner.relevance, other.relevance)
        return winner
    }
}
