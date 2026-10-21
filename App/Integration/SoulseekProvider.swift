#if SOULSEEK
    import Foundation
    import PFDownloads
    import PFFind
    import PFSoulseek

    /// Contract 1's `DownloadProvider` over stream C's `SoulseekClient` (spec §5.6), for the sideloaded build only.
    ///
    /// There is exactly one client per process (`SoulseekAccount` owns it): a second sign-in with the same account
    /// would kick the first session. Search spacing is the client's own (and the smart search runner's token bucket);
    /// nothing here adds a third limiter.
    struct SoulseekProvider: DownloadProvider {
        static let providerID = "soulseek"
        let id = SoulseekProvider.providerID
        let displayName = "Soulseek"

        let client: SoulseekClient
        /// Where transfers are written, outside the download manager's per-job folders. The client names each
        /// transfer's folder after the peer and path (`slsk-<hash>`), so a retried or re-queued download of the same
        /// file finds its `.part` file and resumes.
        let partialsRoot: URL

        func search(_ query: String) -> AsyncThrowingStream<[RemoteTrack], Error> {
            let upstream = client.search(query)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await batch in upstream {
                            continuation.yield(batch.filter(\.isFLAC).map(Self.remoteTrack))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func download(_ track: RemoteTrack, into staging: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
            AsyncThrowingStream { continuation in
                guard let file = Self.searchResultFile(track) else {
                    continuation.yield(.failed("The Soulseek result is missing its peer, path or size"))
                    continuation.finish()
                    return
                }
                let client = client
                let partialsRoot = partialsRoot
                // The client yields `.finished` before its stream ends, and the manager drains a provider's stream
                // after `.finished` with no timeout. So this stream finishes at `.finished` itself, and stops
                // listening to the client's: nothing can keep a finished download waiting.
                let task = Task {
                    try? FileManager.default.createDirectory(at: partialsRoot, withIntermediateDirectories: true)
                    for await event in client.download(file, into: partialsRoot) {
                        switch event {
                        case .requested, .remotelyQueued:
                            continuation.yield(.queued)
                        case .started, .progress:
                            continuation.yield(.progress(event.fraction ?? 0))
                        case .finished(let url):
                            continuation.yield(Self.handOver(url, into: staging))
                            continuation.finish()
                            return
                        case .failed(let failure):
                            continuation.yield(.failed(failure.reason))
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Moves the finished file out of its `slsk-<hash>` folder into the job's staging folder, where admission
        /// expects it (directly inside the folder it was given), and deletes the now empty transfer folder.
        static func handOver(_ url: URL, into staging: URL) -> DownloadEvent {
            let target = staging.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                return .failed("Could not move the download into staging")
            }
            let folder = url.deletingLastPathComponent()
            if folder.lastPathComponent.hasPrefix("slsk-") { try? FileManager.default.removeItem(at: folder) }
            return .finished(target)
        }

        /// A search result as contract 1's `RemoteTrack`. The size passes through as the peer stated it; a missing
        /// size is never turned into 0 (every transfer would then be refused as larger than listed).
        static func remoteTrack(_ file: SearchResultFile) -> RemoteTrack {
            var detail = file.detail
            detail["size"] = String(file.sizeBytes)
            return RemoteTrack(
                id: file.id, provider: providerID, title: file.displayTitle, artist: file.artistGuess,
                album: file.albumGuess, fileName: file.fileName, sizeBytes: file.sizeBytes,
                bitsPerSample: file.bitsPerSample, sampleRate: file.sampleRate, detail: detail)
        }

        /// The client's file again, from the track's `detail`: the peer and the exact remote path, which only ever go
        /// back to that peer. Nil when anything needed is missing.
        static func searchResultFile(_ track: RemoteTrack) -> SearchResultFile? {
            guard let peer = track.detail["peer"], let path = track.detail["path"], let size = track.sizeBytes,
                size > 0
            else { return nil }
            return SearchResultFile(
                peer: peer, path: path, sizeBytes: size, bitsPerSample: track.bitsPerSample,
                sampleRate: track.sampleRate, freeSlot: track.detail["freeSlot"] == "1",
                uploadSpeed: Int(track.detail["speed"] ?? "") ?? 0, queueLength: Int(track.detail["queue"] ?? "") ?? 0)
        }

        /// The ranker's view of a result: one `CandidateFile` per file, upload speed as `speed`.
        static func candidate(_ file: SearchResultFile) -> CandidateFile {
            CandidateFile(
                path: file.path, sizeBytes: file.sizeBytes, bitsPerSample: file.bitsPerSample,
                sampleRate: file.sampleRate, peer: file.peer, freeSlot: file.freeSlot, speed: file.uploadSpeed,
                queueLength: file.queueLength)
        }

        /// The track for a ranked candidate file, through the client's own type so the IDs match a direct search's.
        static func remoteTrack(_ candidate: CandidateFile) -> RemoteTrack? {
            guard let peer = candidate.peer, let size = candidate.sizeBytes else { return nil }
            return remoteTrack(
                SearchResultFile(
                    peer: peer, path: candidate.path, sizeBytes: size, bitsPerSample: candidate.bitsPerSample,
                    sampleRate: candidate.sampleRate, freeSlot: candidate.freeSlot ?? false,
                    uploadSpeed: candidate.speed ?? 0, queueLength: candidate.queueLength ?? 0))
        }

        /// Raw files for the smart search's plan runner.
        func candidates(_ query: String) -> AsyncThrowingStream<[CandidateFile], Error> {
            let upstream = client.search(query)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await batch in upstream {
                            continuation.yield(batch.filter(\.isFLAC).map(Self.candidate))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
#endif
