import Foundation
import PFCore

/// One search result, for a results list or a typeahead row.
public struct LibraryHit: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case artist
        case album
        case track
    }

    /// How the hit matched, worst token first: one typo makes the whole hit fuzzy, one word found only inside another
    /// makes it a substring hit.
    public enum Match: Int, Sendable, Hashable, Comparable {
        case fuzzy
        case substring
        case prefix
        case exact

        public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    /// An album's or a track's library ID; for an artist, `"artist:"` and the folded name.
    public var id: String
    /// Album title, artist name or track title.
    public var title: String
    /// Album: its artist. Track: "artist · album". Artist: the number of albums.
    public var subtitle: String
    /// Ranges of `title` and `subtitle` that matched, for bold or tinted letters (spec §4.6).
    public var titleHighlights: [Range<String.Index>]
    public var subtitleHighlights: [Range<String.Index>]
    public var match: Match
}

/// What a search found, grouped as spec §4.6 lists them, best first in each group.
public struct LibrarySearchResults: Sendable {
    public var albums: [LibraryHit] = []
    public var artists: [LibraryHit] = []
    public var tracks: [LibraryHit] = []
    /// How long the search took, for the budget readout and tests.
    public var elapsed: Duration = .zero

    public var isEmpty: Bool { albums.isEmpty && artists.isEmpty && tracks.isEmpty }
}

/// The in-memory search index over one library catalog (spec §5.5, the "[call]" design).
///
/// Built once per catalog, off the main actor, then immutable: any thread may query it, including the main actor
/// inside a keystroke. A query costs a binary search and a scan over the postings of the matching words, plus one
/// pass over the vocabulary for typos, never a pass over the tracks themselves; at 10k tracks that is well under a
/// millisecond in a release build (see `SearchBenchmarkTests`).
///
/// - Documents are albums (title, artist), artists (name) and tracks (title, artist, album).
/// - The vocabulary is every distinct folded token (`TextFolding`), sorted, flat. Each token has postings: document,
///   field, word position, and whether it is a piece of a punctuated word.
/// - Each query token matches vocabulary words exactly, as a prefix, inside the word (3+ letters: "ove" in "Love",
///   "ヒカル" in "宇多田ヒカル"), or with one typo (5+ letters). Documents must match every query token (AND).
/// - Ranking, highest first: no typo at all; the query is the whole title; the title starts with the query; the sum
///   of match quality (exact 100, prefix 60, substring 40, typo 25) × field weight (title 4, artist 2, album 2);
///   albums, then artists, then tracks; shorter titles; library order. That is the spec's order: exact title, title
///   word, title start, title substring, artist or album word, typo.
public final class SearchIndex: Sendable {
    public typealias Token = TextFolding.Token

    /// More query words than this are ignored: they only narrow, and each costs a postings pass.
    static let maxQueryTokens = 8

    private static let kindAlbum: UInt8 = 0
    private static let kindArtist: UInt8 = 1
    private static let kindTrack: UInt8 = 2
    private static let fieldWeights: [Int32] = [4, 2, 2]
    private static let exactQuality: Int32 = 100
    private static let prefixQuality: Int32 = 60
    private static let substringQuality: Int32 = 40
    private static let typoQuality: Int32 = 25

    // Documents, in library order: albums, then artists, then tracks album by album.
    private let kinds: [UInt8]
    private let ids: [String]
    private let titles: [String]
    private let subtitles: [String]
    private let titleWordCounts: [UInt8]
    private let bits: [Int32]
    private let rates: [Int32]

    // Vocabulary: token k is `vocabulary[vocabularyStarts[k]..<vocabularyStarts[k + 1]]`, sorted.
    private let vocabulary: [UInt32]
    private let vocabularyStarts: [Int32]
    // Postings of token k: `postings[postingStarts[k]..<postingStarts[k + 1]]`, each
    // `document << 10 | field << 8 | piece << 7 | position`.
    private let postingStarts: [Int32]
    private let postings: [UInt32]

    public var documentCount: Int { kinds.count }
    public var vocabularySize: Int { vocabularyStarts.count - 1 }

    public init(_ catalog: LibraryCatalog) {
        var kinds: [UInt8] = []
        var ids: [String] = []
        var titles: [String] = []
        var subtitles: [String] = []
        var titleWordCounts: [UInt8] = []
        var bits: [Int32] = []
        var rates: [Int32] = []
        var table: [Token: [UInt32]] = [:]

        func add(kind: UInt8, id: String, title: String, subtitle: String, fields: [String], format: AudioFormat?) {
            let document = UInt32(kinds.count)
            kinds.append(kind)
            ids.append(id)
            titles.append(title)
            subtitles.append(subtitle)
            bits.append(Int32(format?.bitsPerSample ?? 0))
            rates.append(Int32(format?.sampleRate ?? 0))
            var titleWords = 0
            for (field, text) in fields.enumerated() where !text.isEmpty {
                let words = TextFolding.words(text)
                if field == 0 { titleWords = words.count }
                for (position, word) in words.enumerated() {
                    let base = document << 10 | UInt32(field) << 8 | UInt32(min(position, 127))
                    table[word.joined, default: []].append(base)
                    for piece in word.pieces where piece != word.joined {
                        table[piece, default: []].append(base | 1 << 7)
                    }
                }
            }
            titleWordCounts.append(UInt8(min(titleWords, 255)))
        }

        var artistAlbums: [String: (name: String, count: Int)] = [:]
        var artistOrder: [String] = []
        func noteArtist(_ name: String, album: Bool) {
            guard !name.isEmpty, name != AlbumGrouping.variousArtists, name != AlbumGrouping.unknownArtist else {
                return
            }
            let key = TextFolding.fold(name)
            if artistAlbums[key] == nil {
                artistAlbums[key] = (name, 0)
                artistOrder.append(key)
            }
            if album { artistAlbums[key]?.count += 1 }
        }

        for album in catalog.albums {
            add(
                kind: Self.kindAlbum, id: album.id, title: album.title, subtitle: album.artist,
                fields: [album.title, album.artist], format: album.bestFormat)
            noteArtist(album.artist, album: true)
        }
        for album in catalog.albums {
            for track in catalog.tracks(of: album.id) { noteArtist(track.displayArtist, album: false) }
        }
        for key in artistOrder {
            guard let artist = artistAlbums[key] else { continue }
            let subtitle = artist.count == 1 ? "1 album" : artist.count == 0 ? "Artist" : "\(artist.count) albums"
            add(
                kind: Self.kindArtist, id: "artist:\(key)", title: artist.name, subtitle: subtitle,
                fields: [artist.name], format: nil)
        }
        for album in catalog.albums {
            for track in catalog.tracks(of: album.id) {
                let albumTitle = track.album.isEmpty ? album.title : track.album
                let artist = track.displayArtist
                add(
                    kind: Self.kindTrack, id: track.id, title: track.title,
                    subtitle: artist.isEmpty ? albumTitle : "\(artist) · \(albumTitle)",
                    fields: [track.title, artist, albumTitle], format: track.format)
            }
        }

        let sorted = table.keys.sorted { $0.lexicographicallyPrecedes($1) }
        var vocabulary: [UInt32] = []
        var vocabularyStarts: [Int32] = [0]
        var postingStarts: [Int32] = [0]
        var postings: [UInt32] = []
        vocabularyStarts.reserveCapacity(sorted.count + 1)
        postingStarts.reserveCapacity(sorted.count + 1)
        for token in sorted {
            vocabulary.append(contentsOf: token)
            vocabularyStarts.append(Int32(vocabulary.count))
            postings.append(contentsOf: table[token] ?? [])
            postingStarts.append(Int32(postings.count))
        }

        self.kinds = kinds
        self.ids = ids
        self.titles = titles
        self.subtitles = subtitles
        self.titleWordCounts = titleWordCounts
        self.bits = bits
        self.rates = rates
        self.vocabulary = vocabulary
        self.vocabularyStarts = vocabularyStarts
        self.postingStarts = postingStarts
        self.postings = postings
    }

    // MARK: Queries

    /// Results for `query` under `filter`, at most `limit` per group. An empty query finds nothing under `.all`, and
    /// lists the library under any other chip ("all my 24-bit albums").
    public func search(_ query: String, filter: SearchFilter = .all, limit: Int = 50) -> LibrarySearchResults {
        let clock = ContinuousClock()
        let start = clock.now
        let tokens = Array(TextFolding.queryTokens(query).prefix(Self.maxQueryTokens))
        var results = LibrarySearchResults()
        var albums = TopK(limit: limit)
        var artists = TopK(limit: limit)
        var tracks = TopK(limit: limit)

        if tokens.isEmpty {
            guard filter != .all else {
                results.elapsed = clock.now - start
                return results
            }
            for document in 0..<kinds.count where allows(filter, document) {
                let entry = (key: Int64(0), document: Int32(document), match: LibraryHit.Match.exact)
                switch kinds[document] {
                case Self.kindAlbum: albums.insert(entry)
                case Self.kindTrack: tracks.insert(entry)
                default: break
                }
            }
        } else {
            for entry in rank(tokens) where allows(filter, Int(entry.document)) {
                switch kinds[Int(entry.document)] {
                case Self.kindAlbum: albums.insert(entry)
                case Self.kindArtist: artists.insert(entry)
                default: tracks.insert(entry)
                }
            }
        }
        results.albums = albums.items.map { hit($0, tokens) }
        results.artists = artists.items.map { hit($0, tokens) }
        results.tracks = tracks.items.map { hit($0, tokens) }
        results.elapsed = clock.now - start
        return results
    }

    /// The best `limit` hits of any kind for a partly typed `prefix`, for the typeahead (stream E's "library"
    /// suggestions). Synchronous and allocation-light: safe to call on every keystroke from the main actor.
    public func suggest(_ prefix: String, limit: Int) -> [LibraryHit] {
        let tokens = Array(TextFolding.queryTokens(prefix).prefix(Self.maxQueryTokens))
        guard !tokens.isEmpty, limit > 0 else { return [] }
        var top = TopK(limit: limit)
        for entry in rank(tokens) { top.insert(entry) }
        return top.items.map { hit($0, tokens) }
    }

    private func allows(_ filter: SearchFilter, _ document: Int) -> Bool {
        let kind = kinds[document]
        switch filter {
        case .all: return true
        case .albums: return kind == Self.kindAlbum
        case .songs: return kind == Self.kindTrack
        case .hiRes24: return kind != Self.kindArtist && bits[document] >= 24
        case .bit32: return kind != Self.kindArtist && bits[document] == 32
        case .rate96: return kind != Self.kindArtist && rates[document] >= 96_000
        }
    }

    private func hit(_ entry: TopK.Entry, _ tokens: [Token]) -> LibraryHit {
        let document = Int(entry.document)
        let kind: LibraryHit.Kind =
            switch kinds[document] {
            case Self.kindAlbum: .album
            case Self.kindArtist: .artist
            default: .track
            }
        let title = titles[document]
        let subtitle = subtitles[document]
        return LibraryHit(
            kind: kind, id: ids[document], title: title, subtitle: subtitle,
            titleHighlights: TextFolding.highlights(in: title, query: tokens),
            subtitleHighlights: kind == .artist ? [] : TextFolding.highlights(in: subtitle, query: tokens),
            match: entry.match)
    }

    /// A vocabulary word that matched a query token, and how.
    private struct WordMatch {
        var word: Int
        var quality: Int32
        var exact: Bool
        var typo: Bool
        /// Found inside the word, not at its start (spec §5.5 tier 3).
        var substring: Bool
    }

    /// Every document that matches all `tokens`, with its ranking key.
    private func rank(_ tokens: [Token]) -> [TopK.Entry] {
        let count = kinds.count
        guard count > 0 else { return [] }
        let tokenCount = UInt8(tokens.count)
        var stage = [UInt8](repeating: 0, count: count)
        var best = [Int32](repeating: 0, count: count)
        var flags = [UInt8](repeating: 0, count: count)
        var score = [Int32](repeating: 0, count: count)
        var titleRun = [UInt8](repeating: 0, count: count)
        var exactTitleRun = [UInt8](repeating: 0, count: count)
        var exactWords = [UInt8](repeating: 0, count: count)
        var substringsOnly = [UInt8](repeating: 0, count: count)
        var typos = [UInt8](repeating: 0, count: count)
        var touched: [Int32] = []

        postings.withUnsafeBufferPointer { postings in
            postingStarts.withUnsafeBufferPointer { starts in
                for (index, token) in tokens.enumerated() {
                    let stageBefore = UInt8(index)
                    let stageAfter = stageBefore + 1
                    var next: [Int32] = []
                    next.reserveCapacity(touched.isEmpty ? 64 : touched.count)
                    for match in matches(token) {
                        let lower = Int(starts[match.word])
                        let upper = Int(starts[match.word + 1])
                        var p = lower
                        while p < upper {
                            let posting = postings[p]
                            p += 1
                            let document = Int(posting >> 10)
                            let current = stage[document]
                            if current == stageBefore {
                                stage[document] = stageAfter
                                best[document] = 0
                                flags[document] = 0
                                next.append(Int32(document))
                            } else if current != stageAfter {
                                continue
                            }
                            let field = Int(posting >> 8 & 3)
                            let quality = match.quality * Self.fieldWeights[field]
                            if quality > best[document] { best[document] = quality }
                            var flag = flags[document]
                            if !match.typo { flag |= 4 }
                            if match.exact { flag |= 8 }
                            if !match.typo, !match.substring { flag |= 16 }
                            // A match inside a word never makes the title "start with" the query.
                            if field == 0, Int(posting & 0x7F) == index, !match.substring {
                                flag |= 1
                                if match.exact, posting & 0x80 == 0 { flag |= 2 }
                            }
                            flags[document] = flag
                        }
                    }
                    for document in next {
                        let d = Int(document)
                        score[d] += best[d]
                        let flag = flags[d]
                        if flag & 1 != 0 { titleRun[d] += 1 }
                        if flag & 2 != 0 { exactTitleRun[d] += 1 }
                        if flag & 4 == 0 {
                            typos[d] += 1
                        } else if flag & 16 == 0 {
                            substringsOnly[d] += 1
                        }
                        if flag & 8 != 0 { exactWords[d] += 1 }
                    }
                    touched = next
                    if touched.isEmpty { break }
                }
            }
        }

        var entries: [TopK.Entry] = []
        entries.reserveCapacity(touched.count)
        for document in touched {
            let d = Int(document)
            guard stage[d] == tokenCount else { continue }
            let typoFree: Int64 = typos[d] == 0 ? 1 : 0
            let exactTitle: Int64 = exactTitleRun[d] == tokenCount && titleWordCounts[d] == tokenCount ? 1 : 0
            let titleStart: Int64 = titleRun[d] == tokenCount ? 1 : 0
            let kindRank: Int64 =
                switch kinds[d] {
                case Self.kindAlbum: 2
                case Self.kindArtist: 1
                default: 0
                }
            let shortness = Int64(15 - min(15, Int(titleWordCounts[d])))
            let key =
                typoFree << 50 | exactTitle << 49 | titleStart << 48 | Int64(min(score[d], 1 << 30)) << 8
                | kindRank << 4 | shortness
            let match: LibraryHit.Match =
                typos[d] > 0
                ? .fuzzy : substringsOnly[d] > 0 ? .substring : exactWords[d] == tokenCount ? .exact : .prefix
            entries.append((key, document, match))
        }
        return entries
    }

    /// The vocabulary words `token` matches: itself, the words it starts, and (4+ letters) the words one typo away.
    private func matches(_ token: Token) -> [WordMatch] {
        var result: [WordMatch] = []
        vocabulary.withUnsafeBufferPointer { words in
            vocabularyStarts.withUnsafeBufferPointer { starts in
                token.withUnsafeBufferPointer { query in
                    let wordCount = starts.count - 1
                    func word(_ k: Int) -> UnsafeBufferPointer<UInt32> {
                        UnsafeBufferPointer(rebasing: words[Int(starts[k])..<Int(starts[k + 1])])
                    }
                    // First word not below the token: where its prefix range starts.
                    var low = 0
                    var high = wordCount
                    while low < high {
                        let mid = (low + high) / 2
                        if Self.precedes(word(mid), query) { low = mid + 1 } else { high = mid }
                    }
                    var k = low
                    while k < wordCount {
                        let w = word(k)
                        guard Self.hasPrefix(w, query) else { break }
                        let exact = w.count == query.count
                        result.append(
                            WordMatch(
                                word: k, quality: exact ? Self.exactQuality : Self.prefixQuality, exact: exact,
                                typo: false, substring: false))
                        k += 1
                    }
                    let m = query.count
                    let typos = m >= SearchMatching.minimumTypoLength
                    let substrings = m >= SearchMatching.minimumSubstringLength
                    guard typos || substrings, let base = words.baseAddress else { return }
                    // One pass over the vocabulary for both. A typo lines its first two letters up somehow, so a
                    // four-comparison test rejects nearly every word before any call; a substring needs the word to
                    // be longer than the token and to hold its first letter after the start.
                    let q0 = query[0]
                    let q1 = query[1]
                    var start = Int(starts[0])
                    for k in 0..<wordCount {
                        let end = Int(starts[k + 1])
                        defer { start = end }
                        let n = end - start
                        if substrings, n > m {
                            var offset = 1
                            var found = false
                            while offset <= n - m {
                                if base[start + offset] == q0 {
                                    var i = 1
                                    while i < m, base[start + offset + i] == query[i] { i += 1 }
                                    if i == m {
                                        found = true
                                        break
                                    }
                                }
                                offset += 1
                            }
                            if found {
                                result.append(
                                    WordMatch(
                                        word: k, quality: Self.substringQuality, exact: false, typo: false,
                                        substring: true))
                                continue
                            }
                        }
                        guard typos, n >= m - 1 else { continue }
                        let w0 = base[start]
                        let w1 = base[start + 1]
                        guard w0 == q0 || w1 == q1 || w1 == q0 || w0 == q1 else { continue }
                        let candidate = UnsafeBufferPointer(start: base + start, count: n)
                        if SearchMatching.prefixWithinOneEdit(query, candidate) {
                            result.append(
                                WordMatch(
                                    word: k, quality: Self.typoQuality, exact: false, typo: true, substring: false))
                        }
                    }
                }
            }
        }
        return result
    }

    private static func precedes(_ a: UnsafeBufferPointer<UInt32>, _ b: UnsafeBufferPointer<UInt32>) -> Bool {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] }
            i += 1
        }
        return a.count < b.count
    }

    private static func hasPrefix(_ word: UnsafeBufferPointer<UInt32>, _ prefix: UnsafeBufferPointer<UInt32>) -> Bool {
        guard word.count >= prefix.count else { return false }
        var i = 0
        while i < prefix.count {
            if word[i] != prefix[i] { return false }
            i += 1
        }
        return true
    }
}

/// The best `limit` entries seen, kept sorted, without sorting every candidate: a one-letter query can match most of
/// the library, and only the first screenful is shown.
struct TopK {
    typealias Entry = (key: Int64, document: Int32, match: LibraryHit.Match)
    let limit: Int
    private(set) var items: [Entry] = []

    init(limit: Int) {
        self.limit = max(0, limit)
        // Bounded, so a caller asking for "everything" (Int.max) cannot overflow the reservation.
        items.reserveCapacity(min(self.limit, 256) + 1)
    }

    /// Higher keys first; equal keys in library order.
    @inline(__always)
    static func before(_ a: Entry, _ b: Entry) -> Bool {
        a.key != b.key ? a.key > b.key : a.document < b.document
    }

    mutating func insert(_ entry: Entry) {
        guard limit > 0 else { return }
        if items.count == limit, let last = items.last, !Self.before(entry, last) { return }
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if Self.before(items[mid], entry) { low = mid + 1 } else { high = mid }
        }
        items.insert(entry, at: low)
        if items.count > limit { items.removeLast() }
    }
}
