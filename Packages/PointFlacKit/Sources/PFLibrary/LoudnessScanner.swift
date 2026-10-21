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

    /// Nil when the file cannot be read, is evicted to iCloud, or the task was cancelled before the end.
    /// Never asks iCloud to download.
    static func measure(_ url: URL) async -> Measurement? {
        if LibraryStore.isNotDownloaded(url) { return nil }
        guard let decoder = try? FlacDecoder(url: url) else { return nil }
        let channels = decoder.format.channels
        let bits = decoder.format.bitsPerSample
        guard channels >= 1, bits >= 1,
            let meter = try? LoudnessMeter(channels: channels, sampleRate: decoder.format.sampleRate)
        else { return nil }
        let scale = Float(1.0 / pow(2.0, Double(bits - 1)))
        var ints = [Int32](repeating: 0, count: chunkFrames * channels)
        var floats = [Float](repeating: 0, count: chunkFrames * channels)
        while true {
            if Task.isCancelled { return nil }
            let frames: Int
            do {
                frames = try ints.withUnsafeMutableBufferPointer {
                    try decoder.read(into: $0, maxFrames: chunkFrames)
                }
            } catch {
                return nil
            }
            if frames == 0 { break }
            let count = frames * channels
            for i in 0..<count { floats[i] = Float(ints[i]) * scale }
            floats.withUnsafeBufferPointer { meter.add($0, frames: frames) }
            // Playback's decode thread comes first: give the pool back between chunks.
            await Task.yield()
        }
        let lufs = meter.integratedLufs
        let peak = pow(10, meter.truePeakDbTP / 20)
        meter.finish()
        return Measurement(meter: meter, lufs: lufs.isFinite ? lufs : nil, truePeak: peak.isFinite ? peak : 0)
    }
}

extension Library {
    /// Measures the loudness of albums that carry no ReplayGain tag, in the background (EBU R128), and stores each
    /// track's LUFS and true peak, then the album's LUFS (all its tracks pooled) and peak (the largest track peak).
    ///
    /// Which albums: see `LibraryStore.loudnessJobs`. A measured, current or fully tagged album is never decoded. A
    /// track evicted to iCloud is left alone (nothing is downloaded), as is one that is missing or unreadable; an
    /// album that loses a track this way gets its tracks' values but no album value. `albums` narrows the scan to
    /// those IDs. Only one scan runs at a time; a second call returns at once.
    ///
    /// How: the plan is read on the library's queue; each file is decoded on a `.background` task, outside the queue,
    /// so playback and other library calls never wait on a decode; each result is then written on the queue, as its
    /// own short call. The caller is resumed through a continuation, not by awaiting the task, because awaiting a
    /// task raises it to the awaiter's priority: a scan started from the UI would otherwise decode at user-initiated
    /// priority. A track's row is only ever updated, never inserted, so a track removed meanwhile stays removed. A
    /// cancelled scan stops at the next chunk and keeps what it stored. The catalog is published when an album is
    /// done, at most every few seconds, and at the end. `progress(done, total)` counts tracks and is called from
    /// the scan's task.
    public func scanLoudness(
        albums: [String]? = nil, progress: @escaping @Sendable (Int, Int) -> Void
    ) async {
        let started = loudnessScanning.withLock { running in
            defer { running = true }
            return !running
        }
        guard started else { return }
        defer { loudnessScanning.withLock { $0 = false } }
        let jobs: [LoudnessJob]
        do {
            jobs = try await run(.never) { try $0.loudnessJobs(albums: albums) }
        } catch {
            Self.log(error, during: "loudness plan")
            return
        }
        let total = jobs.reduce(0) { $0 + $1.tracks.count }
        guard total > 0 else { return }

        let handle = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))
        await withTaskCancellationHandler {
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                let task = Task.detached(priority: .background) { [self] in
                    await measureAlbums(jobs, total: total, progress: progress)
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

    private func measureAlbums(
        _ jobs: [LoudnessJob], total: Int, progress: @Sendable (Int, Int) -> Void
    ) async {
        var done = 0
        var unpublished = false
        var lastPublish = ContinuousClock.now
        progress(0, total)
        jobsLoop: for job in jobs {
            if Task.isCancelled { break }
            if job.tracks.count > LoudnessScanner.maxAlbumTracks {
                Self.logger.info(
                    "Loudness: album of \(job.tracks.count, privacy: .public) tracks measured per track, no album value"
                )
            }
            var meters: [LoudnessMeter] = []
            var peaks: [Double] = []
            var allStored = job.complete
            for track in job.tracks {
                if Task.isCancelled { break jobsLoop }
                loudnessDecodes.withLock { $0 += 1 }
                guard let measured = await LoudnessScanner.measure(track.url) else {
                    // Cancelled, or unreadable: no value; the album then has none either.
                    if Task.isCancelled { break jobsLoop }
                    allStored = false
                    done += 1
                    progress(done, total)
                    continue
                }
                if let hook = loudnessHook.withLock({ $0 }) { await hook(track.id) }
                let stored = await store(track: track.id, lufs: measured.lufs, peak: measured.truePeak)
                allStored = allStored && stored
                unpublished = unpublished || stored
                if job.complete { meters.append(measured.meter) }
                peaks.append(measured.truePeak)
                done += 1
                progress(done, total)
            }
            if allStored, let peak = peaks.max() {
                let lufs = LoudnessMeter.albumLufs(meters)
                await storeAlbum(job.albumID, lufs: lufs.isFinite ? lufs : nil, peak: peak, members: job.membersHash)
                unpublished = true
            }
            if unpublished, ContinuousClock.now - lastPublish >= .seconds(5) {
                try? await run(.always) { _ in () }
                unpublished = false
                lastPublish = .now
            }
        }
        // The end, and a cancelled scan, publish what was stored.
        if unpublished { try? await run(.always) { _ in () } }
    }

    private func store(track id: String, lufs: Double?, peak: Double) async -> Bool {
        do {
            return try await run(.never) { try $0.recordLoudness(trackID: id, lufs: lufs, peak: peak) }
        } catch {
            Self.log(error, during: "loudness write")
            return false
        }
    }

    private func storeAlbum(_ id: String, lufs: Double?, peak: Double, members: String) async {
        do {
            try await run(.never) {
                try $0.recordAlbumLoudness(albumID: id, lufs: lufs, peak: peak, members: members)
            }
        } catch {
            Self.log(error, during: "album loudness write")
        }
    }
}
