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
    /// Why a plan has no variants. An empty plan always says which.
    public enum EmptyReason: Sendable, Hashable {
        /// The entity's own name contains this server-excluded phrase.
        case excludedPhrase(String)
        /// The names have nothing Soulseek can match (no letters, digits or symbols).
        case noSearchableWords
        /// Every variant contained an excluded phrase.
        case everyVariantExcluded
    }

    /// Highest priority first. The caller runs them one at a time, within the provider's search rate limit, and
    /// stops as soon as it has enough results.
    public var variants: [QueryVariant]
    /// Set when the entity's own name contains a server-excluded phrase. The plan is then empty: see
    /// ``SoulseekQueryPlanner``.
    public var blockedByExcludedPhrase: String? {
        if case .excludedPhrase(let phrase) = emptyReason { return phrase }
        return nil
    }
    /// Set exactly when ``variants`` is empty.
    public var emptyReason: EmptyReason?

    public init(variants: [QueryVariant], emptyReason: EmptyReason? = nil) {
        self.variants = variants
        self.emptyReason = variants.isEmpty ? (emptyReason ?? .noSearchableWords) : nil
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
        let excluded = ResultRanker.usableExcludedPhrases(excludedPhrases)
        let names = [entity.artist, entity.album, entity.track].compactMap { $0 }
        for name in names {
            if let phrase = firstExcluded(in: name, excluded) {
                return SearchPlan(variants: [], emptyReason: .excludedPhrase(phrase))
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
        let searchable = variants.filter { !$0.query.isEmpty }
        let kept = searchable.filter { variant in
            firstExcluded(in: variant.query, excluded) == nil && seen.insert(variant.query).inserted
        }
        let reason: SearchPlan.EmptyReason = searchable.isEmpty ? .noSearchableWords : .everyVariantExcluded
        return SearchPlan(variants: Array(kept.prefix(maxVariants)), emptyReason: reason)
    }

    // MARK: - Variants

    static func albumVariants(_ entity: ResolvedEntity) -> [QueryVariant] {
        let title = FindText.coreTitle(entity.album ?? "")
        let artist = artistWords(entity.artist)
        let titleAll = searchWords(title)
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
        let titleAll = searchWords(title)
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
    /// Single letters are words ("R.E.M." is "r e m", "Jay-Z" is "jay z", "嵐" stays), except the tail of a
    /// contraction: "Don't" becomes "don", which matches both spellings ("B'z" keeps both letters).
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsTail = false
        var nextIsTail = false
        func flush() {
            if !current.isEmpty, !(currentIsTail && current.count == 1) { result.append(current) }
            current = ""
            currentIsTail = false
        }
        for character in text.lowercased() {
            if character == "'" || character == "’" || character == "`" {
                let wordLength = current.count
                flush()
                nextIsTail = wordLength >= 2
            } else if character.isLetter || character.isNumber {
                if current.isEmpty {
                    currentIsTail = nextIsTail
                    nextIsTail = false
                }
                current.append(character)
            } else {
                flush()
                nextIsTail = false
            }
        }
        flush()
        return result
    }

    /// ``words(_:)``, or the whole name lower-cased when it has no letters or digits at all ("!!!").
    static func searchWords(_ text: String) -> [String] {
        let found = words(text)
        if !found.isEmpty { return found }
        let raw = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return raw.isEmpty ? [] : [raw]
    }

    /// Words minus stopwords; never empty unless `words` is.
    static func distinctive(_ words: [String]) -> [String] {
        let kept = words.filter { !FindText.stopwords.contains(FindText.fold($0)) }
        return kept.isEmpty ? words : kept
    }

    /// The artist's words without a leading "The" ("The Beatles" → "beatles"). Stopwords go only when two words
    /// remain, and single letters are never stopwords: "a-ha" stays "a ha", "Florence and the Machine" becomes
    /// "florence machine".
    static func artistWords(_ artist: String) -> [String] {
        let all = searchWords(FindText.withoutLeadingArticle(artist))
        let kept = all.filter { $0.count < 2 || !FindText.stopwords.contains(FindText.fold($0)) }
        return kept.count >= 2 ? kept : all
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

    /// Longer queries only lose results: every word must appear in the path.
    static let maximumWordsPerQuery = 6

    static func join(_ words: [String]) -> String {
        words.prefix(maximumWordsPerQuery).joined(separator: " ")
    }

    /// The first excluded phrase found in `text` (folded substring match, the strict reading).
    static func firstExcluded(in text: String, _ excluded: [String]) -> String? {
        let haystack = FindText.fold(text)
        return excluded.first { haystack.contains($0) }
    }
}
