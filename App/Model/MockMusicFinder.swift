import Foundation
import Observation
import PFDownloads

#if DEBUG

    /// A `MusicFinding` that answers with demo rows and simulates downloads, so Get Music and Downloads can be built and
    /// tested before streams B, C and E land. Every row it makes says "Demo" in its subtitle: should it ever reach a
    /// tester's build, nothing pretends to be a real result.
    ///
    /// Suggestions follow contract 3's shape: the library's hits at once, then the registry's after a short delay.
    ///
    /// Given a publisher (DEBUG's `-PFDownloadFolder`), a finished demo download is real: a copy of a bundled demo song,
    /// Ada Vale's "Fold" from Paper Moons, goes through the app's own publish step, so a UI test can follow a real file
    /// into the chosen folder and onto the shelf. Without one, nothing is saved, as before.
    @MainActor
    @Observable
    final class MockMusicFinder: MusicFinding {
        let providers: [(id: String, name: String)] = [("archive", "Internet Archive"), ("soulseek", "Soulseek")]
        private(set) var downloads: [DownloadRow] = []
        @ObservationIgnored private let library: any LibraryBrowsing
        @ObservationIgnored private var transfers: [String: Task<Void, Never>] = [:]
        @ObservationIgnored private let publisher: DownloadPublisher?

        init(library: any LibraryBrowsing, publisher: DownloadPublisher? = nil) {
            self.library = library
            self.publisher = publisher
        }

        func search(_ query: String, provider: String) -> AsyncStream<[RemoteResultRow]> {
            let rows = Self.rows(for: query, provider: provider)
            return AsyncStream { continuation in
                let task = Task {
                    // Two batches, as a real provider streams them.
                    try? await Task.sleep(for: .milliseconds(350))
                    continuation.yield(Array(rows.prefix(2)))
                    try? await Task.sleep(for: .milliseconds(450))
                    continuation.yield(rows)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func search(_ suggestion: Suggestion, provider: String) -> AsyncStream<[RemoteResultRow]> {
            search(suggestion.title, provider: provider)
        }

        func suggestions(_ partial: String) -> AsyncStream<[Suggestion]> {
            let trimmed = partial.trimmingCharacters(in: .whitespaces)
            let local = localSuggestions(trimmed)
            return AsyncStream { continuation in
                continuation.yield(local)
                guard trimmed.count >= 2 else {
                    continuation.finish()
                    return
                }
                let task = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    let name = trimmed.capitalized
                    let registry = [
                        Suggestion(
                            id: "mb-artist-\(trimmed)", kind: .artist, title: name, subtitle: "Artist · Demo registry",
                            source: "musicbrainz"),
                        Suggestion(
                            id: "mb-album-\(trimmed)", kind: .album, title: "\(name) Live",
                            subtitle: "Album · Demo registry",
                            source: "musicbrainz"),
                    ]
                    continuation.yield(local + registry)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func download(_ row: RemoteResultRow) {
            guard transfers[row.id] == nil else { return }
            downloads.insert(DownloadRow(id: row.id, title: row.title, state: "Queued", progress: nil), at: 0)
            transfers[row.id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                for step in 0...20 {
                    guard !Task.isCancelled else { return }
                    self?.set(row, "Downloading", Double(step) / 20)
                    try? await Task.sleep(for: .milliseconds(220))
                }
                self?.set(row, "Validating", nil)
                try? await Task.sleep(for: .milliseconds(500))
                self?.set(row, "Saving", nil)
                try? await Task.sleep(for: .milliseconds(300))
                guard let publisher = self?.publisher else {
                    self?.set(row, "Done (demo, nothing saved)", nil)
                    return
                }
                do {
                    let published = try await Self.publishDemoSong(for: row, through: publisher)
                    self?.set(row, "Done", nil, note: published.note)
                } catch {
                    self?.set(row, "Failed: \(error.localizedDescription)", nil)
                }
            }
        }

        /// Stages a copy of the bundled "Fold" as a provider would leave a validated download, and publishes it with
        /// the demo song's own artist and album, so the folder it is filed in matches the album the shelf shows.
        private static func publishDemoSong(for row: RemoteResultRow, through publisher: DownloadPublisher)
            async throws -> Publication
        {
            guard
                let fixture = Bundle.main.url(
                    forResource: "demo-paper-moons-01", withExtension: "flac",
                    subdirectory: "Fixtures")
            else { throw CocoaError(.fileNoSuchFile) }
            let staging = FileManager.default.temporaryDirectory.appending(
                path: "MockDownload-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let staged = staging.appending(path: "01 Fold.flac")
            try FileManager.default.copyItem(at: fixture, to: staged)
            let track = RemoteTrack(
                id: row.id, provider: row.provider, title: "Fold", artist: "Ada Vale", album: "Paper Moons",
                fileName: "01 Fold.flac")
            return try await publisher.publish(staged, track: track)
        }

        /// Only finished rows go, as with the real manager; the demo's row can then be downloaded again.
        func removeDownload(_ id: DownloadRow.ID) {
            guard let row = downloads.first(where: { $0.id == id }), Self.isFinal(row.state) else { return }
            downloads.removeAll { $0.id == id }
            transfers[id] = nil
        }

        func clearDownloads(finished: Bool, failed: Bool) {
            for row in downloads {
                let done = row.state.hasPrefix("Done")
                if (finished && done) || (failed && !done && Self.isFinal(row.state)) { removeDownload(row.id) }
            }
        }

        private static func isFinal(_ state: String) -> Bool {
            state.hasPrefix("Done") || state.hasPrefix("Failed") || state.hasPrefix("Cancelled")
        }

        private func set(_ row: RemoteResultRow, _ state: String, _ progress: Double?, note: String? = nil) {
            guard let index = downloads.firstIndex(where: { $0.id == row.id }) else { return }
            downloads[index] = DownloadRow(id: row.id, title: row.title, state: state, progress: progress, note: note)
        }

        private func localSuggestions(_ partial: String) -> [Suggestion] {
            guard !partial.isEmpty else { return [] }
            let hits = library.search(partial, filter: .all)
            var seen = Set<String>()
            var out: [Suggestion] = []
            for album in hits.albums.prefix(4) {
                if seen.insert("artist:\(album.artist)").inserted {
                    out.append(
                        Suggestion(
                            id: "lib-artist-\(album.artist)", kind: .artist, title: album.artist,
                            subtitle: "Artist · In your library", source: "library"))
                }
                out.append(
                    Suggestion(
                        id: "lib-\(album.id)", kind: .album, title: album.title, subtitle: "Album · \(album.artist)",
                        source: "library"))
            }
            for track in hits.tracks.prefix(3) {
                out.append(
                    Suggestion(
                        id: "lib-\(track.id)", kind: .track, title: track.title, subtitle: "Song · \(track.artist)",
                        source: "library"))
            }
            return out
        }

        private static func rows(for query: String, provider: String) -> [RemoteResultRow] {
            let name = query.trimmingCharacters(in: .whitespaces).capitalized
            guard !name.isEmpty else { return [] }
            if provider == "archive" {
                return [
                    RemoteResultRow(
                        id: "ia-\(name)-1", provider: provider, title: "\(name): Live at the Roundhouse",
                        subtitle: "Demo · Live Music Archive · 14 files", format: "FLAC 24/96", sizeText: "1.2 GB",
                        licence: "Live Music Archive: trading allowed"),
                    RemoteResultRow(
                        id: "ia-\(name)-2", provider: provider, title: "\(name) Sessions",
                        subtitle: "Demo · netlabel · 8 files", format: "FLAC 16/44.1", sizeText: "310 MB",
                        licence: "CC BY-NC-SA 4.0"),
                    RemoteResultRow(
                        id: "ia-\(name)-3", provider: provider, title: "\(name): Field Recordings",
                        subtitle: "Demo · 5 files", format: "FLAC 24/48", sizeText: "640 MB", licence: "Public domain"),
                ]
            }
            return [
                RemoteResultRow(
                    id: "slsk-\(name)-1", provider: provider, title: "\(name) – Discography/Album (2019)",
                    subtitle: "Demo · peer vinyl_ghost · free slot · 11 files", format: "FLAC 24/96", sizeText: "1.1 GB"
                ),
                RemoteResultRow(
                    id: "slsk-\(name)-2", provider: provider, title: "\(name) – Singles",
                    subtitle: "Demo · peer lossless_lu · queue 3 · 6 files", format: "FLAC 16/44.1", sizeText: "220 MB"),
                RemoteResultRow(
                    id: "slsk-\(name)-3", provider: provider, title: "\(name) – Live 1998",
                    subtitle: "Demo · peer tapehead · free slot · 9 files", format: "FLAC 24/48", sizeText: "780 MB"),
            ]
        }
    }
#endif
