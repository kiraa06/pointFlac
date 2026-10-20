import Foundation

/// Builds Internet Archive search queries (the `q` of advancedsearch and the scrape API) from a resolved entity.
///
/// Stream B's `PFArchive` provider owns the requests and the FLAC and licence checks against each item's file list;
/// this only chooses the words. The first query is the precise one (creator and title phrases); later ones loosen it
/// for items whose metadata spells the names differently. Every query keeps to audio items with a FLAC format, which
/// the provider then confirms per file (spec §4.7: the item-level format can match zipped derivatives).
public enum ArchiveQueryBuilder {
    /// The FLAC formats the Archive's derivation reports.
    public static let flacClause = #"mediatype:(audio) AND format:("Flac" OR "24bit Flac")"#

    /// Ordered `q` strings for `entity`, most precise first, without duplicates.
    public static func queries(for entity: ResolvedEntity) -> [String] {
        let artist = FindText.withoutLeadingArticle(entity.artist)
        var queries: [String] = []
        switch entity.kind {
        case .artist:
            queries.append("creator:(\(phrase(entity.artist))) AND \(flacClause)")
            queries.append("creator:(\(words(artist))) AND \(flacClause)")
        case .album:
            let title = FindText.coreTitle(entity.album ?? entity.title)
            queries.append("creator:(\(phrase(entity.artist))) AND title:(\(phrase(title))) AND \(flacClause)")
            queries.append("creator:(\(words(artist))) AND title:(\(words(title))) AND \(flacClause)")
            queries.append("title:(\(phrase(title))) AND \(flacClause)")
        case .track:
            let title = FindText.coreTitle(entity.track ?? entity.title)
            // Track titles live in file metadata, not item fields; the free-text index covers descriptions and
            // track listings, so search the phrase there.
            queries.append("creator:(\(phrase(entity.artist))) AND (\(phrase(title))) AND \(flacClause)")
            if let album = entity.album {
                let albumTitle = FindText.coreTitle(album)
                queries.append(
                    "creator:(\(phrase(entity.artist))) AND title:(\(phrase(albumTitle))) AND \(flacClause)")
            }
            queries.append("creator:(\(words(artist))) AND (\(words(title))) AND \(flacClause)")
        }
        var seen = Set<String>()
        return queries.filter { seen.insert($0).inserted }
    }

    /// A quoted phrase with quotes and backslashes escaped.
    static func phrase(_ text: String) -> String {
        var out = "\""
        for character in text.trimmingCharacters(in: .whitespaces) {
            if character == "\"" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out + "\""
    }

    /// The folded words joined with AND, for fields whose spelling differs from MusicBrainz.
    static func words(_ text: String) -> String {
        let tokens = FindText.significantTokens(FindText.tokens(text)).filter { !["and", "or", "not"].contains($0) }
        return tokens.map { MusicBrainzQuery.escape($0) }.joined(separator: " AND ")
    }
}
