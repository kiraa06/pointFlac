import Foundation
import PFCore
import PFFlac
import PFLoudness
import Synchronization

/// Decodes one file and measures it (EBU R128 integrated loudness and true peak) without holding it in memory:
/// `FlacDecoder` reads a chunk of native-range integers, which become Float32 and go to the meter, chunk by chunk.
enum LoudnessScanner {
    /// Frames per decode chunk: about 190 ms at 44.1 kHz, short enough to yield and to notice a cancellation.
    static let chunkFrames = 8192

    /// An album of more than this many tracks (a folder of untagged files grouped as one album, or a very large box
    /// set) is measured track by track but gets no album value. Each finished meter pooled into an album value
    /// holds about 25 KB (`LoudnessMeter.finish`), so 400 tracks hold about 10 MB.
    static let maxAlbumTracks = 400

    struct Measurement {
        /// Finished (`LoudnessMeter.finish`), kept only to pool into the album value (`LoudnessMeter.albumLufs`). Not
        /// `Sendable`: stays on the scan's task.
        var meter: LoudnessMeter
        /// Nil when there is no usable integrated loudness: silence, or shorter than one 400 ms gating block.
        var lufs: Double?
        var truePeak: Double
    }

    enum Outcome {
        case measured(Measurement)
        /// A deterministic failure: the file's format is one the meter does not take (a sample rate below 8 kHz, say),
        /// or its stream cannot be decoded. Recorded, so it is not tried again until the file changes.
        case unmeasurable
        /// A transient failure: evicted to iCloud, missing, a read error, an allocation failure. Tried again on a
        /// later scan.
        case unreadable
        case cancelled
    }

    /// Never asks iCloud to download. `onChunk` is called after each decoded chunk (a test hook).
    static func measure(_ url: URL, onChunk: (@Sendable () -> Void)? = nil) async -> Outcome {
        if LibraryStore.isNotDownloaded(url) { return .unreadable }
        guard let decoder = try? FlacDecoder(url: url) else { return .unreadable }
        let channels = decoder.format.channels
        let bits = decoder.format.bitsPerSample
        guard channels >= 1, bits >= 1 else { return .unmeasurable }
        let meter: LoudnessMeter
        do {
            meter = try LoudnessMeter(channels: channels, sampleRate: decoder.format.sampleRate)
        } catch LoudnessMeter.Failure.invalidFormat {
            return .unmeasurable  // Deterministic: the file's format, until it changes.
        } catch {
            return .unreadable  // An allocation failure: tried again next scan.
        }
        let scale = Float(1.0 / pow(2.0, Double(bits - 1)))
        var ints = [Int32](repeating: 0, count: chunkFrames * channels)
        var floats = [Float](repeating: 0, count: chunkFrames * channels)
        while true {
            if Task.isCancelled { return .cancelled }
            let frames: Int
            do {
                frames = try ints.withUnsafeMutableBufferPointer {
                    try decoder.read(into: $0, maxFrames: chunkFrames)
                }
            } catch FlacDecodeError.decodeFailed {
                return .unmeasurable  // libFLAC's fatal state: the stream cannot be decoded, however often it is read.
            } catch {
                return .unreadable  // A read error: transient.
            }
            if frames == 0 { break }
            let count = frames * channels
            for i in 0..<count { floats[i] = Float(ints[i]) * scale }
            floats.withUnsafeBufferPointer { meter.add($0, frames: frames) }
            onChunk?()
            // Playback's decode thread comes first: give the pool back between chunks.
            await Task.yield()
        }
        if Task.isCancelled { return .cancelled }
        let lufs = meter.integratedLufs
        let peak = pow(10, meter.truePeakDbTP / 20)
        meter.finish()
        return .measured(
            Measurement(meter: meter, lufs: lufs.isFinite ? lufs : nil, truePeak: peak.isFinite ? peak : 0))
    }
}

extension Library {
    /// What a loudness scan was asked for: everything, or some albums.
    struct LoudnessRequest: Sendable {
        var albums: Set<String>?

        mutating func merge(_ other: LoudnessRequest) {
            if let mine = albums, let theirs = other.albums { albums = mine.union(theirs) } else { albums = nil }
        }
    }

    /// Measures the loudness of albums that carry no ReplayGain tag, in the background (EBU R128), and stores each
    /// track's LUFS and true peak, then the album's LUFS (all its tracks pooled) and peak (the largest track peak).
    ///
    /// Two phases. First, every track no scan has measured, in every album that is not fully tagged: each is decoded
    /// once, and an album whose tracks were all measured in this pass is pooled from those meters at once, with no
    /// further decoding. Small albums go first, so one huge album cannot starve the rest. Second, albums that
    /// are fully measured but have no current album value (the pass above measured only some of their tracks, or a
    /// track came or went) are pooled by decoding their tracks again, once for each set of tracks and states: a failed
    /// attempt is remembered until either changes (a first-phase failure records nothing). An album of more than `maxAlbumTracks`, or with a track evicted
    /// to iCloud, gets no album value. Nothing is ever downloaded; a missing or unreadable file is tried again on
    /// a later scan; a file the meter cannot take (a sample rate below 8 kHz) is recorded and left alone until it
    /// changes. `albums` narrows the scan to those IDs.
    ///
    /// One scan runs at a time. A call made while one is running does not wait: its request is merged into the
    /// running scan, which makes one more pass for it when its own is done, so an album asked for during a scan is
    /// still measured, and the second call returns at once. The first caller therefore waits for the follow-up too
    /// (for as long as others keep merging requests), and its `progress` is one cumulative count across the passes:
    /// `done` never goes down. If the first caller is cancelled, a request merged into its scan is served by a
    /// fresh background scan, not dropped.
    ///
    /// How: the plan is read on the library's queue; each file is decoded on a `.background` task, outside the queue,
    /// so playback and other library calls never wait on a decode; each result is then written on the queue, as its
    /// own short call. The caller is resumed through a continuation, not by awaiting the task, because awaiting a
    /// task raises it to the awaiter's priority. A track's row is only ever updated, never inserted, so a track
    /// removed meanwhile stays removed. A cancelled scan stops at the next chunk and keeps what it stored. The
    /// catalog is published when an album is done, at most every few seconds, and at the end. `progress(done,
    /// total)` counts tracks, `total` growing when the second phase is planned; it is called from the scan's task.
    public func scanLoudness(
        albums: [String]? = nil, progress: @escaping @Sendable (Int, Int) -> Void
    ) async {
        let request = LoudnessRequest(albums: albums.map(Set.init))
        let started = loudnessScan.withLock { state in
            if state.running {
                if var pending = state.pending {
                    pending.merge(request)
                    state.pending = pending
                } else {
                    state.pending = request
                }
                return false
            }
            state.running = true
            return true
        }
        guard started else { return }
        // One cumulative count for this caller, across the first pass and any follow-up.
        let base = Mutex((done: 0, total: 0))
        let last = Mutex((done: 0, total: 0))
        let cumulative: @Sendable (Int, Int) -> Void = { done, total in
            last.withLock { $0 = (done, total) }
            let offset = base.withLock { $0 }
            progress(offset.done + done, offset.total + total)
        }
        var next: LoudnessRequest? = request
        while let current = next {
            await runLoudnessPass(current, progress: cumulative)
            let finished = last.withLock { $0 }
            base.withLock { $0 = ($0.done + finished.total, $0.total + finished.total) }
            last.withLock { $0 = (0, 0) }
            // Under one lock: either a follow-up is taken, or the scan is over and a later call starts a new one.
            let cancelled = Task.isCancelled
            let merged = loudnessScan.withLock { state -> LoudnessRequest? in
                let pending = state.pending
                state.pending = nil
                if pending == nil || cancelled { state.running = false }
                return pending
            }
            if cancelled {
                // This caller was cancelled, but another's request was merged into its scan and promised: a fresh
                // background scan, independent of the cancelled caller, serves it.
                if let merged {
                    Task.detached(priority: .background) { [self] in
                        await scanLoudness(albums: merged.albums.map(Array.init)) { _, _ in }
                    }
                }
                next = nil
            } else {
                next = merged
            }
        }
    }

    private func runLoudnessPass(_ request: LoudnessRequest, progress: @escaping @Sendable (Int, Int) -> Void) async {
        let handle = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))
        await withTaskCancellationHandler {
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                let task = Task.detached(priority: .background) { [self] in
                    await measure(request.albums.map(Array.init), progress: progress)
                    finished.resume()
                }
                let cancelled = handle.withLock { state in
                    state.task = task
                    return state.cancelled
                }
                if cancelled { task.cancel() }
            }
        } onCancel: {
            let task = handle.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    private func measure(_ albums: [String]?, progress: @Sendable (Int, Int) -> Void) async {
        let phase1: [LoudnessJob]
        do {
            phase1 = try await run(.never) { try $0.loudnessJobs(albums: albums) }
        } catch {
            Self.log(error, during: "loudness plan")
            return
        }
        var progressState = (done: 0, total: phase1.reduce(0) { $0 + $1.tracks.count })
        var publisher = Publisher()
        if progressState.total > 0 { progress(0, progressState.total) }
        for job in phase1 {
            if Task.isCancelled { break }
            if await measureAndPool(job, &progressState, &publisher, progress) == false { break }
        }
        if !Task.isCancelled {
            let phase2 = (try? await run(.never) { try $0.poolJobs(albums: albums) }) ?? []
            progressState.total += phase2.reduce(0) { $0 + $1.tracks.count }
            if !phase2.isEmpty { progress(progressState.done, progressState.total) }
            for job in phase2 {
                if Task.isCancelled { break }
                if await poolAgain(job, &progressState, &publisher, progress) == false { break }
            }
        }
        // The end, and a cancelled scan, publish what was stored.
        if publisher.unpublished { try? await run(.always) { _ in () } }
    }

    private struct Publisher {
        var unpublished = false
        var last = ContinuousClock.now

        /// Publishes when something was stored and the last publish was a few seconds ago.
        mutating func album(_ library: Library) async {
            guard unpublished, ContinuousClock.now - last >= .seconds(5) else { return }
            try? await library.run(.always) { _ in () }
            unpublished = false
            last = .now
        }
    }

    /// Phase 1 for one album. False when the scan was cancelled.
    private func measureAndPool(
        _ job: LoudnessJob, _ counts: inout (done: Int, total: Int), _ publisher: inout Publisher,
        _ progress: @Sendable (Int, Int) -> Void
    ) async -> Bool {
        var meters: [LoudnessMeter] = []
        var peaks: [Double] = []
        var allMeasured = true
        for track in job.tracks {
            if Task.isCancelled { return false }
            loudnessDecodes.withLock { $0 += 1 }
            let chunkHook = loudnessChunkHook.withLock { $0 }
            switch await LoudnessScanner.measure(track.url, onChunk: chunkHook) {
            case .cancelled:
                return false
            case .unreadable:
                allMeasured = false
            case .unmeasurable:
                allMeasured = false
                _ = await store(track: track.id, state: 2, lufs: nil, peak: nil)
            case .measured(let measured):
                if let hook = loudnessHook.withLock({ $0 }) { await hook(track.id) }
                let stored = await store(track: track.id, state: 1, lufs: measured.lufs, peak: measured.truePeak)
                allMeasured = allMeasured && stored
                publisher.unpublished = publisher.unpublished || stored
                // A meter is kept only when this pass can pool its album; otherwise it goes now (phase 2 pools later).
                if job.pool {
                    meters.append(measured.meter)
                    retainedMeters(+1)
                }
                peaks.append(measured.truePeak)
            }
            counts.done += 1
            progress(counts.done, counts.total)
        }
        defer { retainedMeters(-meters.count) }
        // A failed pool here records nothing: a track's failure is retried on its own next scan, and phase 2 pools
        // the album once every track is measured.
        if job.pool, allMeasured, let peak = peaks.max() {
            await storeAlbum(job, meters: meters, peak: peak)
            publisher.unpublished = true
        }
        await publisher.album(self)
        return true
    }

    /// Phase 2 for one album: decodes every track again to pool them. False when the scan was cancelled.
    private func poolAgain(
        _ job: LoudnessJob, _ counts: inout (done: Int, total: Int), _ publisher: inout Publisher,
        _ progress: @Sendable (Int, Int) -> Void
    ) async -> Bool {
        var meters: [LoudnessMeter] = []
        var peaks: [Double] = []
        var allMeasured = true
        for track in job.tracks {
            if Task.isCancelled { return false }
            loudnessDecodes.withLock { $0 += 1 }
            switch await LoudnessScanner.measure(track.url, onChunk: loudnessChunkHook.withLock { $0 }) {
            case .cancelled:
                return false
            case .unreadable, .unmeasurable:
                allMeasured = false
            case .measured(let measured):
                meters.append(measured.meter)
                retainedMeters(+1)
                peaks.append(measured.truePeak)
            }
            counts.done += 1
            progress(counts.done, counts.total)
        }
        defer { retainedMeters(-meters.count) }
        if allMeasured, let peak = peaks.max() {
            await storeAlbum(job, meters: meters, peak: peak)
            publisher.unpublished = true
        } else {
            await storeAttempt(job)
        }
        await publisher.album(self)
        return true
    }

    /// For tests: how many finished meters the scan holds for pooling, now and at most.
    private func retainedMeters(_ change: Int) {
        loudnessMeters.withLock { state in
            state.current += change
            state.peak = max(state.peak, state.current)
        }
    }

    private func store(track id: String, state: Int, lufs: Double?, peak: Double?) async -> Bool {
        do {
            return try await run(.never) {
                try $0.recordLoudness(trackID: id, state: state, lufs: lufs, peak: peak)
            }
        } catch {
            Self.log(error, during: "loudness write")
            return false
        }
    }

    private func storeAlbum(_ job: LoudnessJob, meters: [LoudnessMeter], peak: Double) async {
        let pooled = LoudnessMeter.albumLufs(meters)
        let lufs = pooled.isFinite ? pooled : nil
        let id = job.albumID
        let members = job.membersHash
        do {
            try await run(.never) {
                try $0.recordAlbumLoudness(albumID: id, lufs: lufs, peak: peak, members: members)
            }
        } catch {
            Self.log(error, during: "album loudness write")
        }
    }

    private func storeAttempt(_ job: LoudnessJob) async {
        let id = job.albumID
        let key = job.attemptKey
        do {
            try await run(.never) { try $0.recordPoolAttempt(albumID: id, key: key) }
        } catch {
            Self.log(error, during: "album attempt write")
        }
    }
}
