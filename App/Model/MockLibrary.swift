import Foundation
import Observation
import PFAudio
import PFCore
import PFDesign
import PFLibrary

/// A `LibraryBrowsing` over the import inbox: what the app has imported (in Debug, the bundled fixtures and the demo
/// albums), grouped into albums by their tags. It really plays, because its queue items are the imported files.
///
/// Why a stand-in at all: stream A builds the real library and search tonight. The UI codes against the protocol, and
/// the controller swaps this out at integration. The search here is a plain scan, fine for a few hundred tracks.
@MainActor
@Observable
final class MockLibrary: LibraryBrowsing {
    private(set) var albums: [AlbumCard] = []
    @ObservationIgnored private var tracksByAlbum: [AlbumCard.ID: [TrackRow]] = [:]
    @ObservationIgnored private var files: [String: ImportedFile] = [:]
    @ObservationIgnored private var bits: [String: Int] = [:]
    @ObservationIgnored private var rates: [String: Int] = [:]
    /// Imports through the app model, so the inbox stays the one place files come in.
    @ObservationIgnored var importer: (([URL]) async -> (added: Int, rejected: [String])?)?

    /// Regroups the library after the inbox lists it.
    func update(from imported: [ImportedFile]) {
        let playable = imported.filter(\.isSupported)
        files = Dictionary(playable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [String: [ImportedFile]] = [:]
        var order: [String] = []
        for file in playable.sorted(by: { $0.id < $1.id }) {
            let key = Self.albumID(file)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        var cards: [AlbumCard] = []
        var tracks: [AlbumCard.ID: [TrackRow]] = [:]
        for key in order {
            guard let members = groups[key], let first = members.first else { continue }
            let layout = SideLayout(durations: members.map(Self.seconds))
            let rows = members.enumerated().map { index, file in
                bits[file.id] = file.format.bitsPerSample
                rates[file.id] = file.format.sampleRate
                return TrackRow(
                    id: file.id, title: file.title.isEmpty ? file.stem : file.title,
                    artist: file.artist.isEmpty ? "Unknown artist" : file.artist,
                    album: first.album.isEmpty ? "Unknown album" : first.album,
                    durationSeconds: Self.seconds(file), format: Self.format(file.format),
                    side: layout.code(ofTrack: index))
            }
            let best = members.map(\.format).max {
                ($0.bitsPerSample, $0.sampleRate) < ($1.bitsPerSample, $1.sampleRate)
            }
            bits[key] = best?.bitsPerSample
            rates[key] = best?.sampleRate
            tracks[key] = rows
            cards.append(
                AlbumCard(
                    id: key, title: first.album.isEmpty ? "Unknown album" : first.album,
                    artist: first.artist.isEmpty ? "Unknown artist" : first.artist, year: nil, artwork: nil,
                    trackCount: rows.count, bestFormat: best.map(Self.format) ?? "FLAC"))
        }
        tracksByAlbum = tracks
        albums = cards
    }

    func tracks(of album: AlbumCard.ID) -> [TrackRow] {
        tracksByAlbum[album] ?? []
    }

    func search(_ query: String, filter: SearchFilter) -> SearchResults {
        let start = ContinuousClock.now
        let words = Self.fold(query).split(separator: " ").map(String.init)
        func matches(_ fields: [String]) -> Bool {
            guard !words.isEmpty else { return true }
            let haystack = fields.map(Self.fold).joined(separator: " ")
            let tokens = haystack.split(separator: " ").map(String.init)
            return words.allSatisfy { word in
                haystack.contains(word) || tokens.contains { Self.withinOneEdit(word, String($0.prefix(word.count))) }
            }
        }
        func passes(_ id: String) -> Bool {
            switch filter {
            case .all, .albums, .songs: true
            case .hiRes24: (bits[id] ?? 0) >= 24
            case .bit32: (bits[id] ?? 0) >= 32
            case .rate96: (rates[id] ?? 0) >= 96_000
            }
        }
        let albumHits =
            filter == .songs ? [] : albums.filter { passes($0.id) && matches([$0.title, $0.artist]) }
        let trackHits =
            filter == .albums || words.isEmpty
            ? []
            : tracksByAlbum.values.joined().filter { passes($0.id) && matches([$0.title, $0.artist, $0.album]) }
                .sorted { ($0.album, $0.side ?? "") < ($1.album, $1.side ?? "") }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        return SearchResults(albums: albumHits, tracks: Array(trackHits.prefix(50)), elapsedMilliseconds: ms)
    }

    func queueItems(for tracks: [TrackRow.ID]) -> [QueueItem] {
        tracks.compactMap { files[$0].map(QueueItem.init) }
    }

    func importFiles(_ urls: [URL]) async -> (added: Int, rejected: [String]) {
        await importer?(urls) ?? (0, [])
    }

    // MARK: Helpers

    private static func albumID(_ file: ImportedFile) -> String {
        "album:" + fold(file.artist) + "|" + fold(file.album.isEmpty ? "unknown" : file.album)
    }

    private static func seconds(_ file: ImportedFile) -> Double {
        file.format.sampleRate > 0 ? Double(file.totalFrames) / Double(file.format.sampleRate) : 0
    }

    /// "FLAC 24/96", "FLAC 16/44.1".
    static func format(_ format: AudioFormat) -> String {
        "FLAC \(format.bitsPerSample)/\(format.formattedRate.replacingOccurrences(of: " kHz", with: ""))"
    }

    /// Case, accents and punctuation folded away, so "Beyoncé!" finds "beyonce".
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// One-letter typo tolerance for words of four letters or more: a substitution, insertion or deletion.
    private static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        guard a.count >= 4 else { return false }
        let x = Array(a)
        let y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0
        var j = 0
        var edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] {
                i += 1
                j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if x.count > y.count {
                i += 1
            } else if x.count < y.count {
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }
}
