import Foundation
import Observation
import PFArchive
import PFDownloads
import PFFind
import PFLibrary
import PFSearch

#if SOULSEEK
    import PFSoulseek
#endif

/// `MusicFinding` over the real engines (contracts 2 and 3): PFFind's smart search for typeahead, stream B's Internet
/// Archive provider and download manager, and, in the sideloaded build, stream C's Soulseek client.
///
/// - Suggestions come from one `SmartSearch` whose library source is the current `LibrarySnapshot`. The picked
///   suggestion is looked up by ID in `picked`, because the UI's `Suggestion` is a field copy without the entity.
/// - Internet Archive is searched only on Search or a picked suggestion, never per keystroke: one search costs about
///   21 requests (one listing, then a metadata call per item).
/// - Every provider's batches are accumulated here, so each emission is the full list so far, as the UI expects.
/// - Downloads go through one `DownloadManager`, whose `publish` hands the validated file to the library and then
///   deletes the staged copy, so a finished download is moved, not duplicated.
@MainActor
@Observable
final class RealMusicFinder: MusicFinding {
    let providers: [(id: String, name: String)]

    @ObservationIgnored private let library: RealLibrary
    @ObservationIgnored private let archive: ArchiveProvider
    @ObservationIgnored let manager: DownloadManager
    @ObservationIgnored private let observer: DownloadsObserver
    @ObservationIgnored private var smartSearch: SmartSearch
    @ObservationIgnored private var registryEnabled: Bool
    @ObservationIgnored private var artworkEnabled: Bool
    /// Suggestion ID → PFFind's suggestion, with the entity the planners need.
    @ObservationIgnored private var picked: [String: PFFind.Suggestion] = [:]
    /// Result row ID → the tracks a Download of that row queues (one for a file, several for a Soulseek folder).
    @ObservationIgnored private var rowTracks: [String: [RemoteTrack]] = [:]
    #if SOULSEEK
        @ObservationIgnored private let soulseek: SoulseekProvider
        @ObservationIgnored private let client: SoulseekClient
    #endif

    #if SOULSEEK
        init(library: RealLibrary, soulseek client: SoulseekClient, registryEnabled: Bool, artworkEnabled: Bool) {
            self.client = client
            let caches = URL.cachesDirectory
            let soulseek = SoulseekProvider(
                client: client, partialsRoot: caches.appending(path: "SoulseekPartials", directoryHint: .isDirectory))
            self.soulseek = soulseek
            let archive = ArchiveProvider()
            self.archive = archive
            providers = [(archive.id, archive.displayName), (soulseek.id, soulseek.displayName)]
            self.library = library
            self.registryEnabled = registryEnabled
            self.artworkEnabled = artworkEnabled
            smartSearch = Self.makeSmartSearch(library.box, registry: registryEnabled, artwork: artworkEnabled)
            manager = Self.makeManager(providers: [archive, soulseek], library: library.library)
            observer = DownloadsObserver(manager: manager)
        }
    #else
        init(library: RealLibrary, registryEnabled: Bool, artworkEnabled: Bool) {
            let archive = ArchiveProvider()
            self.archive = archive
            providers = [(archive.id, archive.displayName)]
            self.library = library
            self.registryEnabled = registryEnabled
            self.artworkEnabled = artworkEnabled
            smartSearch = Self.makeSmartSearch(library.box, registry: registryEnabled, artwork: artworkEnabled)
            manager = Self.makeManager(providers: [archive], library: library.library)
            observer = DownloadsObserver(manager: manager)
        }
    #endif

    /// Resumes the saved download queue. Call once at launch.
    func start() async {
        await manager.restore()
    }

    /// Applies the Settings privacy switches at once. SmartSearch fixes them at creation, so a change builds a new
    /// one; the MusicBrainz request limiter is process-wide, so the new one shares its budget.
    func setLookups(registry: Bool, artwork: Bool) {
        guard registry != registryEnabled || artwork != artworkEnabled else { return }
        registryEnabled = registry
        artworkEnabled = artwork
        smartSearch = Self.makeSmartSearch(library.box, registry: registry, artwork: artwork)
    }

    // MARK: Downloads

    var downloads: [DownloadRow] {
        // Newest first, one row per result row: a track downloaded again shows its latest job only.
        var seen = Set<String>()
        return observer.items.reversed().compactMap { item in
            let id = Self.rowID(item.track)
            guard seen.insert(id).inserted else { return nil }
            return DownloadRow(
                id: id, title: item.track.title, state: Self.label(item.state), progress: Self.progress(item.state))
        }
    }

    func download(_ row: RemoteResultRow) {
        guard let tracks = rowTracks[row.id], !tracks.isEmpty else { return }
        let manager = manager
        Task {
            for track in tracks { await manager.enqueue(track) }
        }
    }

    /// The UI's words for each state (contract 2): "Queued", "Downloading", "Validating", "Saving", "Done", "Failed: …".
    static func label(_ state: DownloadState) -> String {
        switch state {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .validating: "Validating"
        case .saving: "Saving"
        case .published: "Done"
        case .failed(let reason): "Failed: \(reason)"
        case .cancelled: "Cancelled"
        }
    }

    /// Non-nil exactly while the job is under way, so the progress bar and the tab badge track live transfers only.
    static func progress(_ state: DownloadState) -> Double? {
        switch state {
        case .downloading(let progress): progress ?? 0
        case .validating, .saving: 1
        case .queued, .published, .failed, .cancelled: nil
        }
    }

    static func rowID(_ track: RemoteTrack) -> String { "\(track.provider)|\(track.id)" }

    // MARK: Suggestions

    func suggestions(_ partial: String) -> AsyncStream<[Suggestion]> {
        let upstream = smartSearch.suggestions(partial)
        return AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await batch in upstream {
                    guard let self else { break }
                    for suggestion in batch { self.picked[suggestion.id] = suggestion }
                    continuation.yield(batch.map(Self.suggestion))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func suggestion(_ s: PFFind.Suggestion) -> Suggestion {
        let kind: Suggestion.Kind =
            switch s.kind {
            case .artist: .artist
            case .album: .album
            case .track: .track
            }
        return Suggestion(id: s.id, kind: kind, title: s.title, subtitle: s.subtitle, source: s.source)
    }

    // MARK: Search

    func search(_ query: String, provider: String) -> AsyncStream<[RemoteResultRow]> {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Self.empty }
        switch provider {
        case archive.id:
            return archiveSearch(text)
        #if SOULSEEK
            case soulseek.id:
                return soulseekFolders(text)
        #endif
        default:
            return Self.empty
        }
    }

    func search(_ suggestion: Suggestion, provider: String) -> AsyncStream<[RemoteResultRow]> {
        guard let found = picked[suggestion.id] else { return search(suggestion.title, provider: provider) }
        let smartSearch = smartSearch
        let (stream, continuation) = AsyncStream.makeStream(of: [RemoteResultRow].self)
        let task = Task { @MainActor [weak self] in
            let entity = await smartSearch.resolve(found)
            guard let self, !Task.isCancelled else { return continuation.finish() }
            let inner: AsyncStream<[RemoteResultRow]>
            switch provider {
            case self.archive.id:
                // ArchiveProvider quotes each word of plain text itself, so it gets words, not the Lucene strings of
                // `archiveQueries(for:)`, which it would split into words and search for literally.
                inner = self.archiveSearch(Self.words(for: entity))
            #if SOULSEEK
                case self.soulseek.id:
                    inner = await self.soulseekAlbums(entity)
            #endif
            default:
                inner = Self.empty
            }
            for await batch in inner { continuation.yield(batch) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The plain words that name a resolved entity: its artist and, for an album or a track, its title.
    static func words(for entity: ResolvedEntity) -> String {
        switch entity.kind {
        case .artist: entity.artist
        case .album: [entity.artist, entity.album ?? ""].joined(separator: " ")
        case .track: [entity.artist, entity.track ?? ""].joined(separator: " ")
        }
    }

    private func archiveSearch(_ text: String) -> AsyncStream<[RemoteResultRow]> {
        accumulate(archive.search(text)) { tracks in
            tracks.map { track in
                let row = RemoteResultRow(
                    id: Self.rowID(track), provider: track.provider, title: track.title,
                    subtitle: [track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }
                        .joined(separator: " · "),
                    format: track.formatLabel, sizeText: track.sizeLabel, licence: track.detail["licence"])
                return (row, [track])
            }
        }
    }

    /// Runs a provider search, keeping every batch so far, and emits the full mapped list after each batch.
    private func accumulate(
        _ upstream: AsyncThrowingStream<[RemoteTrack], Error>,
        _ map: @escaping ([RemoteTrack]) -> [(RemoteResultRow, [RemoteTrack])]
    ) -> AsyncStream<[RemoteResultRow]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [RemoteResultRow].self)
        let task = Task { @MainActor [weak self] in
            var all: [RemoteTrack] = []
            var seen = Set<String>()
            do {
                for try await batch in upstream {
                    for track in batch where seen.insert(track.id).inserted { all.append(track) }
                    let rows = map(all)
                    for (row, tracks) in rows { self?.rowTracks[row.id] = tracks }
                    continuation.yield(rows.map(\.0))
                }
            } catch {
                // A failed search ends with what it found so far; the UI shows "No FLAC results" when that is nothing.
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static var empty: AsyncStream<[RemoteResultRow]> {
        AsyncStream { $0.finish() }
    }

    #if SOULSEEK
        /// Typed words: one literal Soulseek search, grouped by peer and folder (spec §4.7). Each row is a folder; its
        /// Download queues every FLAC file in it.
        private func soulseekFolders(_ text: String) -> AsyncStream<[RemoteResultRow]> {
            accumulate(soulseek.search(text)) { tracks in
                let files = tracks.compactMap(SoulseekProvider.searchResultFile)
                return SearchResultFolder.group(files).prefix(60).map { folder in
                    let tracks = folder.files.map(SoulseekProvider.remoteTrack)
                    let format = Self.format(bits: folder.bestBitsPerSample, rate: folder.bestSampleRate)
                    let slot = folder.freeSlot ? "free slot" : "queue \(folder.queueLength)"
                    let row = RemoteResultRow(
                        id: "soulseek-folder|\(folder.id)", provider: SoulseekProvider.providerID, title: folder.name,
                        subtitle: "\(folder.peer) · \(slot) · \(folder.files.count) files", format: format,
                        sizeText: ByteCountFormatter.string(fromByteCount: folder.totalBytes, countStyle: .file))
                    return (row, tracks)
                }
            }
        }

        /// A picked suggestion: the smart search's plan, ranked into album candidates (complete albums first).
        private func soulseekAlbums(_ entity: ResolvedEntity) async -> AsyncStream<[RemoteResultRow]> {
            let phrases = await client.excludedPhrases
            let soulseek = soulseek
            let upstream = smartSearch.soulseekAlbums(for: entity, excludedPhrases: phrases) { query in
                soulseek.candidates(query)
            }
            let (stream, continuation) = AsyncStream.makeStream(of: [RemoteResultRow].self)
            let task = Task { @MainActor [weak self] in
                for await candidates in upstream {
                    let rows = candidates.map { candidate in
                        let tracks = candidate.files.compactMap(SoulseekProvider.remoteTrack)
                        let row = RemoteResultRow(
                            id: "soulseek-album|\(candidate.id)", provider: SoulseekProvider.providerID,
                            title: candidate.folder.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(
                                String.init)
                                ?? candidate.folder,
                            subtitle: [candidate.peer ?? "", candidate.why, "\(candidate.files.count) files"]
                                .filter { !$0.isEmpty }.joined(separator: " · "),
                            format: Self.format(bits: candidate.bitsPerSample, rate: candidate.sampleRate),
                            sizeText: ByteCountFormatter.string(fromByteCount: candidate.totalBytes, countStyle: .file))
                        return (row, tracks)
                    }
                    for (row, tracks) in rows { self?.rowTracks[row.id] = tracks }
                    continuation.yield(rows.map(\.0))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
    #endif

    /// "FLAC 24/96" from what the peer stated, "FLAC" when it stated nothing.
    static func format(bits: Int?, rate: Int?) -> String {
        RemoteTrack(id: "", provider: "", title: "", fileName: "x.flac", bitsPerSample: bits, sampleRate: rate)
            .formatLabel
    }

    // MARK: Wiring

    private static func makeSmartSearch(_ box: SnapshotBox, registry: Bool, artwork: Bool) -> SmartSearch {
        SmartSearch(
            library: { query, limit in
                let snapshot = box.snapshot
                return snapshot.suggest(query, limit: limit).compactMap { Self.findHit($0, in: snapshot) }
            }, registryEnabled: registry, artworkEnabled: artwork, preference: .highest)
    }

    /// Stream A's hit as stream E's: the names come from the catalog rather than the display subtitle.
    nonisolated static func findHit(_ hit: PFSearch.LibraryHit, in snapshot: LibrarySnapshot) -> PFFind.LibraryHit? {
        switch hit.kind {
        case .artist:
            return PFFind.LibraryHit(id: hit.id, kind: .artist, title: hit.title, artist: hit.title)
        case .album:
            guard let album = snapshot.album(hit.id) else { return nil }
            return PFFind.LibraryHit(
                id: album.id, kind: .album, title: album.title, artist: album.artist, year: album.year,
                trackCount: album.trackIDs.count)
        case .track:
            guard let track = snapshot.track(hit.id) else { return nil }
            return PFFind.LibraryHit(
                id: track.id, kind: .track, title: track.title, artist: track.displayArtist,
                album: track.album.isEmpty ? nil : track.album, year: track.year)
        }
    }

    /// The manager publishes into the library and deletes the staged file once the library has it (or already had
    /// it), so a download is moved rather than copied, and publishing the same file twice is harmless. A refusal
    /// throws, so the job shows as failed instead of done.
    private static func makeManager(providers: [any DownloadProvider], library: Library) -> DownloadManager {
        let support = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let configuration = DownloadManager.Configuration(
            stagingRoot: URL.cachesDirectory.appending(path: "Downloads", directoryHint: .isDirectory),
            stateFile: support.appending(path: "downloads.json"),
            // Two at once, whichever the source: the Archive's politeness and the Soulseek cap of two transfers.
            maxConcurrent: 2)
        return DownloadManager(providers: providers, configuration: configuration) { file in
            let result = await library.importFiles([file])
            if let rejection = result.rejected.first {
                throw PublishError(message: "\(rejection.fileName): \(rejection.message)")
            }
            if let error = result.error { throw PublishError(message: error) }
            guard !result.added.isEmpty || result.duplicates > 0 else {
                throw PublishError(message: "the library did not take the file")
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    struct PublishError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
