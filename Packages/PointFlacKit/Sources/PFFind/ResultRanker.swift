import Foundation

/// How the person wants quality traded against size.
public enum FormatPreference: Sendable, Hashable {
    /// The highest resolution available (the default).
    case highest
    /// CD quality (16-bit, 44.1/48 kHz) first: smaller files, nothing audible lost for most people.
    case cdQuality
    /// The highest resolution up to a ceiling, for limited storage or a DAC that tops out.
    case atMost(bitsPerSample: Int, sampleRate: Int)
}

/// One peer's folder that looks like the wanted album.
public struct AlbumCandidate: Sendable, Hashable, Identifiable {
    /// Peer and folder: one candidate per shared folder.
    public var id: String
    public var peer: String?
    /// The album folder as the peer shares it (disc subfolders folded in).
    public var folder: String
    /// The FLAC files, in path order.
    public var files: [CandidateFile]
    public var expectedTrackCount: Int?
    public var isComplete: Bool
    /// The most common resolution in the folder.
    public var bitsPerSample: Int?
    public var sampleRate: Int?
    public var totalBytes: Int64
    /// How well the paths name the wanted album and artist, in 0…1.
    public var matchScore: Double
    /// The overall rank, in 0…1.
    public var score: Double
    /// A short explanation for the UI: "Complete album · 24/96 · free slot".
    public var why: String
}

/// One file that looks like the wanted track.
public struct TrackCandidate: Sendable, Hashable, Identifiable {
    public var id: String { (file.peer ?? "") + "|" + file.path }
    public var file: CandidateFile
    public var matchScore: Double
    public var score: Double
    public var why: String
}

/// Filters, groups and ranks raw search results against the canonical entity.
///
/// Results arrive as a flat list of files from many peers, most of them unrelated (a broad query such as
/// "the mountain" matches "Mountain Goats" folders too). The ranker keeps FLAC only, groups files by peer and
/// folder into album candidates, checks the folder names against the album and the paths against the artist
/// (so title-only queries are filtered by artist afterwards), detects complete albums against the MusicBrainz track
/// count, and ranks on match, completeness, format and availability.
public enum ResultRanker {
    /// Weights of the four ranking terms. Match dominates: a perfect rip of the wrong album is worthless. A complete
    /// album in a long queue still beats a partial one with a free slot.
    static let weights = (match: 0.45, completeness: 0.30, format: 0.13, availability: 0.12)

    /// Album candidates for `entity`, best first.
    ///
    /// - Parameters:
    ///   - minimumMatch: candidates whose album or artist match falls below this are dropped.
    ///   - excludedPhrases: the server's excluded phrases; paths containing one are dropped, as the protocol asks.
    public static func rankAlbums(
        _ files: [CandidateFile], for entity: ResolvedEntity, preference: FormatPreference = .highest,
        excludedPhrases: [String] = [], minimumMatch: Double = 0.6
    ) -> [AlbumCandidate] {
        let excluded = excludedPhrases.map(FindText.fold).filter { !$0.isEmpty }
        let albumTitle = FindText.coreTitle(entity.album ?? entity.title)
        let artistNames = entity.artistNames
        var groups: [String: (peer: String?, folder: String, files: [CandidateFile])] = [:]
        var order: [String] = []
        for file in files where isFLAC(file.path) {
            if !excluded.isEmpty, SoulseekQueryPlanner.firstExcluded(in: file.path, excluded) != nil { continue }
            let folder = albumFolder(of: file.path)
            let key = (file.peer ?? "") + "|" + folder.lowercased()
            if groups[key] == nil {
                groups[key] = (file.peer, folder, [])
                order.append(key)
            }
            groups[key]?.files.append(file)
        }
        var candidates: [AlbumCandidate] = []
        for key in order {
            guard let group = groups[key] else { continue }
            let folderParts = components(group.folder)
            let albumMatch = folderParts.suffix(3).map { phraseScore(albumTitle, in: $0) }.max() ?? 0
            let artistMatch = bestArtistMatch(artistNames, in: folderParts + group.files.map { fileName($0.path) })
            guard albumMatch >= minimumMatch, artistMatch >= minimumMatch else { continue }
            let match = albumMatch * 0.55 + artistMatch * 0.45
            let sorted = group.files.sorted { $0.path < $1.path }
            let count = sorted.count
            let completeness = completenessScore(count: count, expected: entity.trackCount)
            let (bits, rate) = dominantFormat(sorted)
            let format = formatScore(bits: bits, rate: rate, preference: preference)
            let availability = availabilityScore(sorted.first ?? CandidateFile(path: ""))
            let score =
                weights.match * match + weights.completeness * completeness + weights.format * format
                + weights.availability * availability
            let isComplete = entity.trackCount.map { count >= $0 } ?? false
            candidates.append(
                AlbumCandidate(
                    id: key, peer: group.peer, folder: group.folder, files: sorted,
                    expectedTrackCount: entity.trackCount, isComplete: isComplete, bitsPerSample: bits,
                    sampleRate: rate, totalBytes: sorted.compactMap(\.sizeBytes).reduce(0, +), matchScore: match,
                    score: score,
                    why: albumWhy(
                        count: count, expected: entity.trackCount, bits: bits, rate: rate, file: sorted.first)))
        }
        return candidates.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }

    /// Track candidates for a track `entity`, best first: the file name must name the track and the path the artist.
    public static func rankTracks(
        _ files: [CandidateFile], for entity: ResolvedEntity, preference: FormatPreference = .highest,
        excludedPhrases: [String] = [], minimumMatch: Double = 0.6
    ) -> [TrackCandidate] {
        let excluded = excludedPhrases.map(FindText.fold).filter { !$0.isEmpty }
        let title = FindText.coreTitle(entity.track ?? entity.title)
        var results: [TrackCandidate] = []
        for file in files where isFLAC(file.path) {
            if !excluded.isEmpty, SoulseekQueryPlanner.firstExcluded(in: file.path, excluded) != nil { continue }
            let name = fileName(file.path)
            let stem = (name as NSString).deletingPathExtension
            let titleMatch = phraseScore(title, in: stem)
            let artistMatch = bestArtistMatch(entity.artistNames, in: components(file.path))
            guard titleMatch >= minimumMatch, artistMatch >= minimumMatch else { continue }
            let match = titleMatch * 0.6 + artistMatch * 0.4
            let format = formatScore(bits: file.bitsPerSample, rate: file.sampleRate, preference: preference)
            let availability = availabilityScore(file)
            let score = (match * 0.6 + format * 0.2 + availability * 0.2)
            var parts: [String] = []
            if let text = formatText(bits: file.bitsPerSample, rate: file.sampleRate) { parts.append(text) }
            parts.append(contentsOf: availabilityText(file))
            results.append(
                TrackCandidate(file: file, matchScore: match, score: score, why: parts.joined(separator: " · ")))
        }
        return results.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }

    // MARK: - Paths

    static func isFLAC(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".flac")
    }

    /// Path components, Soulseek's backslashes and forward slashes alike, empty parts dropped.
    static func components(_ path: String) -> [String] {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
    }

    static func fileName(_ path: String) -> String {
        components(path).last ?? path
    }

    /// The folder that holds the album: the file's folder, or its parent when that folder is a disc ("CD1",
    /// "Disc 2", "Side A"), so a double album is one candidate.
    static func albumFolder(of path: String) -> String {
        var parts = components(path)
        parts.removeLast()
        if let last = parts.last, isDiscFolder(last), parts.count > 1 {
            parts.removeLast()
        }
        let separator = path.contains("\\") ? "\\" : "/"
        return parts.joined(separator: separator)
    }

    static func isDiscFolder(_ name: String) -> Bool {
        let folded = FindText.fold(name)
        guard let regex = try? Regex(#"^(cd|disc|disk|side)\s*([0-9]{1,2}|[a-d])$"#) else { return false }
        return folded.wholeMatch(of: regex) != nil
    }

    // MARK: - Matching

    /// How well a path component names `phrase`: 1 when the folded phrase appears whole, else the fuzzy score.
    static func phraseScore(_ phrase: String, in component: String) -> Double {
        let needle = FindText.fold(phrase)
        guard !needle.isEmpty else { return 0 }
        let haystack = " " + FindText.fold(component) + " "
        if haystack.contains(" " + needle + " ") { return 1 }
        // "Mountain, The" and "Beatles, The" style inversions.
        let withoutArticle = FindText.fold(FindText.withoutLeadingArticle(phrase))
        if withoutArticle != needle, haystack.contains(" " + withoutArticle + " ") { return 0.95 }
        return FuzzyMatcher.score(query: phrase, candidate: component)
    }

    static func bestArtistMatch(_ names: [String], in components: [String]) -> Double {
        var best = 0.0
        for name in names {
            for component in components {
                best = max(best, phraseScore(FindText.withoutLeadingArticle(name), in: component))
                if best >= 1 { return best }
            }
        }
        return best
    }

    // MARK: - Scoring

    static func completenessScore(count: Int, expected: Int?) -> Double {
        guard let expected, expected > 0 else {
            // Unknown track count: a full-looking folder is probably an album.
            return min(Double(count) / 10, 1) * 0.7
        }
        if count > expected * 2 { return 0.5 }  // A discography or "everything" folder, not this album.
        // Squared, so each missing track costs more than the last: 11 of 15 is a poor download, not 73 % of a good one.
        let fraction = min(Double(count) / Double(expected), 1)
        return fraction * fraction
    }

    static func dominantFormat(_ files: [CandidateFile]) -> (bits: Int?, rate: Int?) {
        var counts: [String: (Int?, Int?, Int)] = [:]
        for file in files {
            let key = "\(file.bitsPerSample ?? 0)/\(file.sampleRate ?? 0)"
            let previous = counts[key]?.2 ?? 0
            counts[key] = (file.bitsPerSample, file.sampleRate, previous + 1)
        }
        guard let best = counts.values.max(by: { $0.2 < $1.2 }) else { return (nil, nil) }
        return (best.0, best.1)
    }

    static func formatScore(bits: Int?, rate: Int?, preference: FormatPreference) -> Double {
        let bitsValue: Double =
            switch bits {
            case nil: 0.4
            case let value? where value >= 32: 1
            case let value? where value >= 24: 0.9
            default: 0.5
            }
        let rateValue: Double =
            switch rate {
            case nil: 0.5
            case let value? where value >= 176_400: 1
            case let value? where value >= 88_200: 0.85
            default: 0.5
            }
        let highest = (bitsValue + rateValue) / 2
        switch preference {
        case .highest:
            return highest
        case .cdQuality:
            guard let bits, let rate else { return 0.5 }
            if bits <= 16, rate <= 48_000 { return 1 }
            if bits <= 24, rate <= 48_000 { return 0.8 }
            return 0.6
        case .atMost(let maxBits, let maxRate):
            guard let bits, let rate else { return 0.4 }
            return bits <= maxBits && rate <= maxRate ? highest : 0.2
        }
    }

    static func availabilityScore(_ file: CandidateFile) -> Double {
        let slot: Double =
            switch file.freeSlot {
            case true?: 1
            case false?: 0.3
            case nil: 0.5
            }
        let speed: Double = file.speed.map { min(log10(Double(max($0, 1))) / 7, 1) } ?? 0.4
        let queue: Double = file.queueLength.map { 1 / (1 + Double(max($0, 0)) / 5) } ?? 0.5
        return slot * 0.5 + speed * 0.3 + queue * 0.2
    }

    // MARK: - Explanations

    static func albumWhy(count: Int, expected: Int?, bits: Int?, rate: Int?, file: CandidateFile?) -> String {
        var parts: [String] = []
        if let expected {
            parts.append(count >= expected ? "Complete album" : "\(count) of \(expected) tracks")
        } else {
            parts.append(count == 1 ? "1 track" : "\(count) tracks")
        }
        if let text = formatText(bits: bits, rate: rate) { parts.append(text) }
        if let file { parts.append(contentsOf: availabilityText(file)) }
        return parts.joined(separator: " · ")
    }

    /// "24/96", "16/44.1".
    static func formatText(bits: Int?, rate: Int?) -> String? {
        guard let bits, let rate, bits > 0, rate > 0 else { return nil }
        let kilohertz = Double(rate) / 1000
        let rateText =
            kilohertz.rounded() == kilohertz ? String(Int(kilohertz)) : String(format: "%.1f", kilohertz)
        return "\(bits)/\(rateText)"
    }

    static func availabilityText(_ file: CandidateFile) -> [String] {
        if file.freeSlot == true { return ["free slot"] }
        if let queue = file.queueLength, queue > 0 { return ["queue \(queue)"] }
        return []
    }
}
