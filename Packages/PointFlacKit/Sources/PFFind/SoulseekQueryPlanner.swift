import Foundation

/// One literal Soulseek query and how its results must be filtered.
public struct QueryVariant: Sendable, Hashable {
    public enum Intent: String, Sendable, Hashable {
        case albumOnly, artistAndAlbum, artistOnly, trackOnly, artistAndTrack
    }

    /// The words to send, lower-case and space-separated.
    public var query: String
    public var intent: Intent
    /// The query does not name the artist, so results must be filtered by artist afterwards
    /// (``ResultRanker`` does this from the entity).
    public var requiresArtistFilter: Bool

    public init(query: String, intent: Intent, requiresArtistFilter: Bool) {
        self.query = query
        self.intent = intent
        self.requiresArtistFilter = requiresArtistFilter
    }
}

/// The ordered queries for one entity.
public struct SearchPlan: Sendable, Hashable {
    /// Highest priority first. The caller runs them one at a time, within the provider's search rate limit, and
    /// stops as soon as it has enough results.
    public var variants: [QueryVariant]
    /// Set when the entity's own name contains a server-excluded phrase. The plan is then empty: see
    /// ``SoulseekQueryPlanner``.
    public var blockedByExcludedPhrase: String?

    public init(variants: [QueryVariant], blockedByExcludedPhrase: String? = nil) {
        self.variants = variants
        self.blockedByExcludedPhrase = blockedByExcludedPhrase
    }
}

/// Turns a resolved artist, album or track into literal Soulseek queries.
///
/// Soulseek matches every query word literally against strangers' file paths, so one wrong word returns nothing.
/// Live, 2026-10-21: "The Mountain Gorillaz" returned 0 results, "The Mountain" returned 3,556 FLAC files from 304
/// peers with the Gorillaz album among them. The planner therefore sends the fewest, most distinctive words that
/// still identify the thing, and leaves the rest to ``ResultRanker``:
/// - an album title that is distinctive on its own goes first, alone, and results are filtered by artist after;
///   folders name albums far more consistently than artists ("VA", "Gorillaz & friends", artist only in the file
///   names). Generic titles ("Greatest Hits", "Live") lead with the artist instead;
/// - then the artist with the album's distinctive words;
/// - stopwords, punctuation, edition noise ("(Remastered 2011)", "[Deluxe]") and featured credits are dropped;
///   numbers are kept ("1999", "vol 2"); a leading "The" is dropped from artists;
/// - a diacritic-free form follows the original when they differ ("björk" then "bjork").
///
/// **Excluded phrases.** The Soulseek server sends a list of phrases that may not be searched for (rights-holder
/// requests). No variant ever contains one. Further, when the entity's own artist, album or track name contains one,
/// the plan is empty and says why, rather than searching around the exclusion with other words and filtering by
/// the excluded name afterwards: spec §5.6 says pointFlac honours that list, and doing so in letter but not in
/// spirit would not be honouring it.
public enum SoulseekQueryPlanner {
    /// Album titles that name nothing on their own.
    static let genericTitles: Set<String> = [
        "greatest hits", "the best of", "best of", "hits", "live", "the album", "album", "untitled", "demo",
        "demos", "ep", "singles", "remixes", "unplugged", "anthology", "collection", "the collection",
        "essentials", "the essential", "gold", "self titled", "s t",
    ]

    /// Words too common to search by themselves: Soulseek returns thousands of unrelated paths.
    static let weakSingleWords: Set<String> = ["music", "songs", "love", "life", "intro", "outro", "home", "one"]

    /// The ordered query variants for `entity`.
    ///
    /// - Parameters:
    ///   - excludedPhrases: the server's excluded search phrases, as received at login.
    ///   - maxVariants: an upper bound so a plan never outruns the provider's search rate limit.
    public static func plan(
        for entity: ResolvedEntity, excludedPhrases: [String] = [], maxVariants: Int = 4
    ) -> SearchPlan {
        let excluded = excludedPhrases.map(FindText.fold).filter { !$0.isEmpty }
        let names = [entity.artist, entity.album, entity.track].compactMap { $0 }
        for name in names {
            if let phrase = firstExcluded(in: name, excluded) {
                return SearchPlan(variants: [], blockedByExcludedPhrase: phrase)
            }
        }
        var variants: [QueryVariant] = []
        switch entity.kind {
        case .album:
            variants = albumVariants(entity)
        case .track:
            variants = trackVariants(entity)
        case .artist:
            variants = artistVariants(entity)
        }
        var seen = Set<String>()
        let kept = variants.filter { variant in
            !variant.query.isEmpty && firstExcluded(in: variant.query, excluded) == nil
                && seen.insert(variant.query).inserted
        }
        return SearchPlan(variants: Array(kept.prefix(maxVariants)))
    }

    // MARK: - Variants

    static func albumVariants(_ entity: ResolvedEntity) -> [QueryVariant] {
        let title = FindText.coreTitle(entity.album ?? "")
        let artist = artistWords(entity.artist)
        let titleAll = words(title)
        let titleDistinct = distinctive(titleAll)
        guard !titleAll.isEmpty else { return artistVariants(entity) }
        // One distinctive word is too broad alone ("mountain"); keep the title as written ("the mountain").
        let titleQuery = titleDistinct.count >= 2 ? titleDistinct : titleAll
        let titleIsGeneric = isGeneric(titleAll, distinct: titleDistinct)
        var variants: [QueryVariant] = []
        let titleOnly = QueryVariant(query: join(titleQuery), intent: .albumOnly, requiresArtistFilter: true)
        let artistAndTitle = QueryVariant(
            query: join(artist + titleDistinct), intent: .artistAndAlbum, requiresArtistFilter: false)
        if titleIsGeneric {
            variants.append(artistAndTitle)
        } else {
            variants.append(titleOnly)
            variants.append(artistAndTitle)
        }
        variants.append(contentsOf: folded(variants))
        if let year = entity.year, titleIsGeneric {
            variants.append(
                QueryVariant(query: join(artist + [String(year)]), intent: .artistOnly, requiresArtistFilter: false))
        }
        return variants
    }

    static func trackVariants(_ entity: ResolvedEntity) -> [QueryVariant] {
        let title = FindText.coreTitle(entity.track ?? "")
        let artist = artistWords(entity.artist)
        let titleAll = words(title)
        let titleDistinct = distinctive(titleAll)
        guard !titleAll.isEmpty else { return artistVariants(entity) }
        let titleQuery = titleDistinct.count >= 2 ? titleDistinct : titleAll
        var variants = [
            QueryVariant(query: join(artist + titleDistinct), intent: .artistAndTrack, requiresArtistFilter: false)
        ]
        if !isGeneric(titleAll, distinct: titleDistinct) {
            variants.append(QueryVariant(query: join(titleQuery), intent: .trackOnly, requiresArtistFilter: true))
        }
        if let album = entity.album {
            // The whole album is often the only place a track is shared; the ranker picks the file out of it.
            var albumEntity = entity
            albumEntity.kind = .album
            albumEntity.album = album
            variants.append(contentsOf: albumVariants(albumEntity).prefix(1))
        }
        variants.append(contentsOf: folded(variants))
        return variants
    }

    static func artistVariants(_ entity: ResolvedEntity) -> [QueryVariant] {
        let artist = artistWords(entity.artist)
        let variants = [QueryVariant(query: join(artist), intent: .artistOnly, requiresArtistFilter: false)]
        return variants + folded(variants)
    }

    // MARK: - Words

    /// Soulseek words for `text`: lower-case, diacritics kept (folders usually keep them), punctuation removed.
    /// Single letters are dropped unless they are digits: "Don't" becomes "don", which matches both spellings.
    static func words(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var current = ""
        var result: [String] = []
        func flush() {
            if current.count >= 2 || (current.count == 1 && current.first!.isNumber) { result.append(current) }
            current = ""
        }
        for character in lowered {
            if character == "&" || character == "+" {
                flush()
            } else if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// Words minus stopwords; never empty unless `words` is.
    static func distinctive(_ words: [String]) -> [String] {
        let kept = words.filter { !FindText.stopwords.contains(FindText.fold($0)) }
        return kept.isEmpty ? words : kept
    }

    /// The artist's distinctive words without a leading "The" ("The Beatles" → "beatles").
    static func artistWords(_ artist: String) -> [String] {
        distinctive(words(FindText.withoutLeadingArticle(artist)))
    }

    static func isGeneric(_ all: [String], distinct: [String]) -> Bool {
        let phrase = FindText.fold(join(all))
        if genericTitles.contains(phrase) { return true }
        if distinct.count == 1 {
            let word = FindText.fold(distinct[0])
            // A bare number ("1999", "21") matches every path with that year or track number in it.
            return word.count < 4 || weakSingleWords.contains(word) || word.allSatisfy(\.isNumber)
        }
        return false
    }

    /// Diacritic-free twins of variants whose words carry diacritics, in the same order, after all originals.
    static func folded(_ variants: [QueryVariant]) -> [QueryVariant] {
        variants.compactMap { variant in
            let plain = FindText.fold(variant.query)
            guard plain != variant.query, !plain.isEmpty else { return nil }
            return QueryVariant(
                query: plain, intent: variant.intent, requiresArtistFilter: variant.requiresArtistFilter)
        }
    }

    static func join(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    /// The first excluded phrase found in `text` (folded substring match, the strict reading).
    static func firstExcluded(in text: String, _ excluded: [String]) -> String? {
        let haystack = FindText.fold(text)
        return excluded.first { haystack.contains($0) }
    }
}
