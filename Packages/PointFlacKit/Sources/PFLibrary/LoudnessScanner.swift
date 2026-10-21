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

    /// Why a file could not be measured.
    enum MeasureError: Error, Equatable {
        /// Evicted to iCloud: the scan never downloads.
        case notDownloaded
        /// Opening or reading the file failed (`FlacDecoder`).
        case decoder(FlacDecodeError)
        /// The meter refused the file's format, or could not be made (`LoudnessMeter`).
        case meter(LoudnessMeter.Failure)
        /// The stream says it has no channels or no bits per sample.
        case noSamples
    }

    /// What a failed measurement does to its track.
    enum TrackOutcome: Equatable {
        /// A deterministic failure: the same file fails the same way. Recorded (`r128_state` 2), so it is not tried
        /// again until the file changes.
        case unmeasurable
        /// A transient failure. Left (or put back) at `r128_state` 0, so a later scan's first phase tries it again,
        /// at the cost of one open.
        case unreadable

        /// The track's `r128_state` after the failure.
        var state: Int { self == .unmeasurable ? 2 : 0 }
    }

    /// What measuring one file gave.
    enum Outcome {
        case measured(Measurement)
        case failed(TrackOutcome)
        case cancelled
    }

    /// Which failures are retried. Only the file's format is deterministic: a sample rate or channel count the meter
    /// does not take. Everything libFLAC reports while reading a file from start to end is transient. A damaged frame
    /// is not a failure at all: libFLAC reports it, resyncs and goes on (`stream_decoder.c`, `read_frame_`). A read
    /// error aborts the decoder (`ioError`). A fatal state (`decodeFailed`) is an allocation failure, or a failed
    /// `fseeko` back to the last frame sync after a damaged frame: memory, or I/O. An open failure on a file the
    /// library admitted is a missing or unreadable file.
    static func outcome(for error: MeasureError) -> TrackOutcome {
        switch error {
        case .meter(.invalidFormat), .noSamples:
            .unmeasurable
        case .meter(.initFailed), .notDownloaded:
            .unreadable
        case .decoder(let failure):
            switch failure {
            case .openFailed, .ioError, .seekFailed, .decodeFailed: .unreadable
            }
        }
    }

    /// Never asks iCloud to download. `onChunk` is called after each decoded chunk (a test hook).
    static func measure(_ url: URL, onChunk: (@Sendable () -> Void)? = nil) async -> Outcome {
        do {
            guard let measurement = try await read(url, onChunk: onChunk) else { return .cancelled }
            return .measured(measurement)
        } catch {
            return .failed(outcome(for: error))
        }
    }

    /// Nil when the task was cancelled.
    private static func read(
        _ url: URL, onChunk: (@Sendable () -> Void)?
    ) async throws(MeasureError) -> Measurement? {
        if LibraryStore.isNotDownloaded(url) { throw .notDownloaded }
        let decoder: FlacDecoder
        do throws(FlacDecodeError) {
            decoder = try FlacDecoder(url: url)
        } catch {
            throw .decoder(error)
        }
        let channels = decoder.format.channels
        let bits = decoder.format.bitsPerSample
        guard channels >= 1, bits >= 1 else { throw .noSamples }
        let meter: LoudnessMeter
        do {
            meter = try LoudnessMeter(channels: channels, sampleRate: decoder.format.sampleRate)
        } catch let failure as LoudnessMeter.Failure {
            throw .meter(failure)
        } catch {
            throw .meter(.initFailed)  // LoudnessMeter throws nothing else.
        }
        let scale = Float(1.0 / pow(2.0, Double(bits - 1)))
        var ints = [Int32](repeating: 0, count: chunkFrames * channels)
        var floats = [Float](repeating: 0, count: chunkFrames * channels)
        while true {
            if Task.isCancelled { return nil }
            let frames: Int
            do throws(FlacDecodeError) {
                frames = try ints.withUnsafeMutableBufferPointer { (buffer) throws(FlacDecodeError) -> Int in
                    try decoder.read(into: buffer, maxFrames: chunkFrames)
                }
            } catch {
                throw .decoder(error)
            }
            if frames == 0 { break }
            let count = frames * channels
            for i in 0..<count { floats[i] = Float(ints[i]) * scale }
            floats.withUnsafeBufferPointer { meter.add($0, frames: frames) }
            onChunk?()
            // Playback's decode thread comes first: give the pool back between chunks.
            await Task.yield()
        }
        if Task.isCancelled { return nil }
        let lufs = meter.integratedLufs
        let peak = pow(10, meter.truePeakDbTP / 20)
        meter.finish()
        return Measurement(meter: meter, lufs: lufs.isFinite ? lufs : nil, truePeak: peak.isFinite ? peak : 0)
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
    /// track came or went) are pooled by decoding their tracks again, small albums first. A track that fails there
    /// goes back to the first phase, and its album waits until it is measured again; nothing is held against the
    /// album. An album of more than `maxAlbumTracks`, or with a track evicted to iCloud, gets no album value. Nothing
    /// is ever downloaded; a missing or unreadable file is tried again on a later scan, at the cost of one open; a
    /// file the meter cannot take (a sample rate below 8 kHz) is recorded and left alone until it changes. `albums`
    /// narrows the scan to those IDs.
    ///
    /// One scan runs at a time. A call made while one is running does not wait: its request is merged into the
    /// running scan, which makes one more pass for it when its own is done, so an album asked for during a scan is
    /// still measured, and the second call returns at once. The first caller therefore waits for the follow-up too
    /// (for as long as others keep merging requests), and its `progress` is one cumulative count across the passes:
    /// `done` never goes down. Cancelling the first caller drops its own request only: every request merged into its
    /// scan, waiting or being served by the follow-up at that moment, is handed to a fresh background scan. A call
    /// made from a task that is already cancelled asks for nothing.
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
        if Task.isCancelled { return }
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
        // Whether `next` is other callers' requests (a follow-up), which this caller's cancellation must not drop.
        var servingOthers = false
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
                // This caller was cancelled, but other callers' requests were merged into its scan and promised: the
                // ones still waiting, and the one this pass was serving if it was a follow-up. A fresh background
                // scan, independent of the cancelled caller, serves them. What this pass did is skipped by state.
                var orphaned = merged
                if servingOthers {
                    if var both = orphaned {
                        both.merge(current)
                        orphaned = both
                    } else {
                        orphaned = current
                    }
                }
                if let orphaned {
                    Task.detached(priority: .background) { [self] in
                        await scanLoudness(albums: orphaned.albums.map(Array.init)) { _, _ in }
                    }
                }
                next = nil
            } else {
                next = merged
                servingOthers = true
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
        // Before the loop, so a cancelled pass releases what it held too.
        defer { retainedMeters(-meters.count) }
        var peaks: [Double] = []
        var loud = false
        var allMeasured = true
        for track in job.tracks {
            if Task.isCancelled { return false }
            loudnessDecodes.withLock { $0 += 1 }
            let chunkHook = loudnessChunkHook.withLock { $0 }
            switch await LoudnessScanner.measure(track.url, onChunk: chunkHook) {
            case .cancelled:
                return false
            case .failed(.unreadable):
                allMeasured = false
            case .failed(.unmeasurable):
                allMeasured = false
                // A track sent back by the second phase may still have its old values: they go.
                let stored = await store(track: track.id, state: 2, lufs: nil, peak: nil)
                publisher.unpublished = publisher.unpublished || stored
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
                loud = loud || measured.lufs != nil
            }
            counts.done += 1
            progress(counts.done, counts.total)
        }
        // A failed pool here records nothing: a track's failure is retried on its own next scan, and phase 2 pools
        // the album once every track is measured.
        if job.pool, allMeasured, let peak = peaks.max() {
            // A failed pool records nothing either: the second phase tries the album once more.
            if await storeAlbum(job, meters: meters, peak: peak, loud: loud) { publisher.unpublished = true }
        }
        await publisher.album(self)
        return true
    }

    /// Phase 2 for one album: decodes every track again to pool them. False when the scan was cancelled.
    ///
    /// A track failing here is that track's problem, not the album's. It goes back to the first phase: state 0,
    /// keeping its values, when the failure is transient; state 2 when it is not. The pool stops, since it cannot
    /// succeed in this pass. Nothing is recorded against the album, so it is pooled again once the track is
    /// measured again: a brief failure costs one pass, and a lasting one costs the first phase's failed open per
    /// scan, never another decode of the album. Only a pool that fails with every track read is recorded, under
    /// the album's files (`album_attempts`), since the same files would fail it again.
    private func poolAgain(
        _ job: LoudnessJob, _ counts: inout (done: Int, total: Int), _ publisher: inout Publisher,
        _ progress: @Sendable (Int, Int) -> Void
    ) async -> Bool {
        var meters: [LoudnessMeter] = []
        // Before the loop, so a cancelled pass releases what it held too.
        defer { retainedMeters(-meters.count) }
        var peaks: [Double] = []
        var loud = false
        for (index, track) in job.tracks.enumerated() {
            if Task.isCancelled { return false }
            loudnessDecodes.withLock { $0 += 1 }
            switch await LoudnessScanner.measure(track.url, onChunk: loudnessChunkHook.withLock { $0 }) {
            case .cancelled:
                return false
            case .failed(let failure):
                if failure == .unmeasurable {
                    let stored = await store(track: track.id, state: failure.state, lufs: nil, peak: nil)
                    publisher.unpublished = publisher.unpublished || stored
                } else {
                    await remeasure(track: track.id)
                }
                // The rest of the album is not decoded: this pass cannot pool it.
                counts.done += job.tracks.count - index
                progress(counts.done, counts.total)
                await publisher.album(self)
                return true
            case .measured(let measured):
                meters.append(measured.meter)
                retainedMeters(+1)
                peaks.append(measured.truePeak)
                loud = loud || measured.lufs != nil
            }
            counts.done += 1
            progress(counts.done, counts.total)
        }
        if let peak = peaks.max() {
            if await storeAlbum(job, meters: meters, peak: peak, loud: loud) {
                publisher.unpublished = true
            } else {
                await storeAttempt(job)
            }
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

    /// Puts a track the second phase could not read back in the first phase's hands (state 0), keeping its values.
    private func remeasure(track id: String) async {
        do {
            try await run(.never) { try $0.recordUnread(trackID: id) }
        } catch {
            Self.log(error, during: "loudness write")
        }
    }

    /// Pools `meters` into the album value and stores it. False when libebur128 could not pool them. Some track has
    /// a usable loudness (`loud`), so some gating block is above the absolute gate, and the loudest of those always
    /// passes the relative gate: a pool with no value is a failed one. (A failed write is logged, not reported: the
    /// album has no value, and the next scan tries again.)
    private func storeAlbum(_ job: LoudnessJob, meters: [LoudnessMeter], peak: Double, loud: Bool) async -> Bool {
        let pooled = loudnessPoolFault.withLock { $0 } ? -.infinity : LoudnessMeter.albumLufs(meters)
        if loud, !pooled.isFinite { return false }
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
        return true
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
