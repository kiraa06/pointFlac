import Foundation

/// The smart search, wired once for the app: what the `MusicFinding` adapter talks to.
///
/// It exists so the integration cannot get the shared state wrong: one MusicBrainz client (so one cache and the
/// process-wide one-request-per-second limiter), one Soulseek search limiter, and artwork only when the person has
/// opted in (spec §5.8). Create one per process.
///
/// The flow for contract 3:
/// 1. ``suggestions(_:)`` per keystroke;
/// 2. ``resolve(_:)`` when a suggestion is picked;
/// 3. ``soulseekAlbums(for:excludedPhrases:search:)`` or ``archiveQueries(for:)`` with the resolved entity.
public final class SmartSearch: Sendable {
    public let engine: TypeaheadEngine
    public let runner: SearchPlanRunner
    private let coverArt: CoverArtArchive?

    /// - Parameters:
    ///   - library: stream A's library search, called synchronously on every keystroke.
    ///   - registryEnabled: send typed text to MusicBrainz for suggestions. Off means library rows only.
    ///   - artworkEnabled: fetch Cover Art Archive thumbnails for album rows.
    public init(
        library: @escaping TypeaheadEngine.LibrarySearch, registryEnabled: Bool = true, artworkEnabled: Bool = false,
        preference: FormatPreference = .highest, registry: (any SuggestionRegistry)? = nil,
        coverArt: CoverArtArchive? = nil
    ) {
        var configuration = TypeaheadEngine.Configuration()
        configuration.registryEnabled = registryEnabled
        let registry = registryEnabled ? (registry ?? MusicBrainzRegistry()) : nil
        engine = TypeaheadEngine(library: library, registry: registry, configuration: configuration)
        runner = SearchPlanRunner(preference: preference)
        self.coverArt = artworkEnabled ? (coverArt ?? CoverArtArchive()) : nil
    }

    /// Ranked suggestions as they become known: library rows at once, then cached and live registry rows.
    public func suggestions(_ partial: String) -> AsyncStream<[Suggestion]> {
        engine.suggestions(partial)
    }

    /// The picked suggestion's entity, completed (an album's track count) when the registry can.
    public func resolve(_ suggestion: Suggestion) async -> ResolvedEntity {
        await engine.resolve(suggestion)
    }

    /// The Soulseek queries for `entity`, highest priority first.
    public func soulseekPlan(for entity: ResolvedEntity, excludedPhrases: [String]) -> SearchPlan {
        SoulseekQueryPlanner.plan(for: entity, excludedPhrases: excludedPhrases)
    }

    /// Ranked album candidates from Soulseek for `entity`, searching variant by variant within the rate limit.
    ///
    /// - Parameter search: one literal Soulseek search (stream C's client through the controller's adapter).
    public func soulseekAlbums(
        for entity: ResolvedEntity, excludedPhrases: [String], search: @escaping SearchPlanRunner.Search
    ) -> AsyncStream<[AlbumCandidate]> {
        runner.albums(
            soulseekPlan(for: entity, excludedPhrases: excludedPhrases), for: entity,
            excludedPhrases: excludedPhrases, search: search)
    }

    /// Internet Archive `q` strings for `entity`, most precise first (stream B runs them).
    public func archiveQueries(for entity: ResolvedEntity) -> [String] {
        ArchiveQueryBuilder.queries(for: entity)
    }

    /// The album thumbnail for a suggestion row, or nil (no art, artwork off, or not an album from MusicBrainz).
    public func thumbnail(for suggestion: Suggestion) async -> Data? {
        guard let coverArt, let group = suggestion.entity.releaseGroupID else { return nil }
        return await coverArt.thumbnail(releaseGroupID: group)
    }
}
