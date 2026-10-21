import Foundation
import os

/// Runs downloads from any provider through staging, validation and publication (spec §5.4).
///
/// The manager is the only path from the network into the library. It never trusts a provider: each finished file is
/// checked by `Admission` (location, file type, size, FLAC admission rule) before `publish` sees it. Failures keep
/// enough state to retry, and cancelling only ever deletes the job's own staging folder, never published music.
public actor DownloadManager {
    public struct Configuration: Sendable {
        /// A private folder for in-progress files, e.g. `Library/Caches/Downloads`. Each job gets a subfolder.
        public var stagingRoot: URL
        /// Where the queue is saved between launches; `nil` keeps it in memory only.
        public var stateFile: URL?
        /// Downloads running at once. Two keeps the Archive happy and leaves bandwidth for playback.
        public var maxConcurrent: Int
        /// The largest file accepted. A 24/192 album side is well under 2 GiB.
        public var maxFileBytes: Int64
        /// Space left free on top of two copies of the file (staging plus library) before a download may start.
        public var diskMargin: Int64
        /// Attempts per download when the provider throws (dropped connection, server error).
        public var maxAttempts: Int
        /// Wait before attempt `n + 1`, given `n`.
        public var backoff: @Sendable (Int) -> Duration
        /// Free bytes on the volume holding a folder; injectable so tests can simulate a full disk.
        public var freeSpace: @Sendable (URL) -> Int64?
        /// How often a running job's staging folder is measured, so a provider that never reports a size (or
        /// lies about it) cannot fill the disk past `maxFileBytes`.
        public var growthCheckInterval: Duration

        public init(
            stagingRoot: URL, stateFile: URL? = nil, maxConcurrent: Int = 2, maxFileBytes: Int64 = 2 << 30,
            diskMargin: Int64 = 256 << 20, maxAttempts: Int = 3,
            backoff: @escaping @Sendable (Int) -> Duration = { .seconds(1 << min($0 - 1, 6)) },
            freeSpace: @escaping @Sendable (URL) -> Int64? = DiskSpace.available(at:),
            growthCheckInterval: Duration = .milliseconds(500)
        ) {
            self.stagingRoot = stagingRoot
            self.stateFile = stateFile
            self.maxConcurrent = max(1, maxConcurrent)
            self.maxFileBytes = maxFileBytes
            self.diskMargin = diskMargin
            self.maxAttempts = max(1, maxAttempts)
            self.backoff = backoff
            self.freeSpace = freeSpace
            self.growthCheckInterval = growthCheckInterval
        }
    }

    /// Hands a validated file to the library. It may move or copy the file; it must throw if it did not keep it.
    public typealias Publish = @Sendable (URL) async throws -> Void

    private let configuration: Configuration
    private let providers: [String: any DownloadProvider]
    private let publish: Publish
    private let store: DownloadQueueStore?
    private static let log = Logger(subsystem: "io.github.kiraa06.pointflac", category: "downloads")

    private var queue: [DownloadItem] = []
    private var running: [String: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<[DownloadItem]>.Continuation] = [:]
    private var restored = false
    /// Why the manager itself stopped a job (e.g. it outgrew the size limit), as opposed to a user cancel.
    private var abortReasons: [String: String] = [:]
    private var lastGrowthCheck: [String: ContinuousClock.Instant] = [:]

    public init(providers: [any DownloadProvider], configuration: Configuration, publish: @escaping Publish) {
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.configuration = configuration
        self.publish = publish
        self.store = configuration.stateFile.map(DownloadQueueStore.init(url:))
    }

    // MARK: Queue

    /// Every job, oldest first.
    public var items: [DownloadItem] { queue }

    /// The current queue at once, then again after every change, for the UI. A slow reader only misses
    /// intermediate snapshots, never the latest one; tests ask for more buffering to see every step.
    public func updates(buffering: Int = 1) -> AsyncStream<[DownloadItem]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [DownloadItem].self, bufferingPolicy: .bufferingNewest(max(1, buffering)))
        let token = UUID()
        subscribers[token] = continuation
        continuation.yield(queue)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(token) }
        }
        return stream
    }

    /// Loads the saved queue and resumes unfinished jobs. Call once at launch, before enqueueing.
    public func restore() {
        guard !restored else { return }
        restored = true
        guard let store else { return }
        let saved = store.load()
        var known = Set(queue.map(\.id))
        for var item in saved where known.insert(item.id).inserted {
            if item.state == .saving, let staged = item.stagedFileName,
                !FileManager.default.fileExists(atPath: stagingFolder(item.id).appending(path: staged).path)
            {
                // The app stopped while the library was taking the file, and the file has left staging: the
                // library probably has it. Downloading again could duplicate it, so the user decides.
                item.state = .failed("the app closed while saving; check the library before retrying")
                item.stagedFileName = nil
            } else if !item.state.isFinal {
                // A job interrupted mid-flight starts again from the queue; a provider resumes from the staged
                // part file and a validated file is re-checked, never trusted from the last run.
                item.state = .queued
            }
            queue.append(item)
        }
        removeOrphanedStaging()
        changed(persist: true)
        pump()
    }

    /// Deletes staging folders no live job can use: those of unknown, published or cancelled jobs. Only
    /// UUID-named folders are touched, so a misconfigured staging root never loses anything else.
    private func removeOrphanedStaging() {
        let keep = Set(queue.filter { $0.state != .published && $0.state != .cancelled }.map(\.id))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: configuration.stagingRoot.path)) ?? []
        for name in names where UUID(uuidString: name) != nil && !keep.contains(name) {
            try? FileManager.default.removeItem(at: configuration.stagingRoot.appending(path: name))
        }
    }

    /// Queues `track`, or returns the job already downloading it.
    @discardableResult
    public func enqueue(_ track: RemoteTrack) -> String {
        // Only a job still in flight absorbs a repeat request; after it ends the user may want the file again.
        if let existing = queue.first(where: {
            $0.track.id == track.id && $0.track.provider == track.provider && !$0.state.isFinal
        }) {
            return existing.id
        }
        let item = DownloadItem(id: UUID().uuidString, track: track)
        Self.log.info(
            "download \(item.id.prefix(8), privacy: .public) queued (\(track.provider, privacy: .public))")
        queue.append(item)
        changed(persist: true)
        pump()
        return item.id
    }

    /// Stops a job and deletes its staging folder. Jobs already saving or published are left alone, so cancelling
    /// can never remove music the library has taken. Returns whether the job was cancelled.
    @discardableResult
    public func cancel(_ id: String) -> Bool {
        guard let index = index(of: id) else { return false }
        switch queue[index].state {
        case .saving, .published, .cancelled: return false
        case .queued, .downloading, .validating, .failed: break
        }
        queue[index].state = .cancelled
        queue[index].stagedFileName = nil
        if let task = running[id] {
            // The job's task removes the staging folder once the provider has stopped writing into it.
            task.cancel()
        } else {
            removeStaging(id)
        }
        changed(persist: true)
        return true
    }

    /// Queues a failed or cancelled job again.
    @discardableResult
    public func retry(_ id: String) -> Bool {
        guard let index = index(of: id), running[id] == nil else { return false }
        switch queue[index].state {
        case .failed, .cancelled: break
        default: return false
        }
        queue[index].state = .queued
        queue[index].attempts = 0
        changed(persist: true)
        pump()
        return true
    }

    /// Removes a finished, failed or cancelled job from the list.
    @discardableResult
    public func remove(_ id: String) -> Bool {
        guard let index = index(of: id), queue[index].state.isFinal, running[id] == nil else { return false }
        queue.remove(at: index)
        removeStaging(id)
        changed(persist: true)
        return true
    }

    // MARK: Scheduling

    private func pump() {
        while running.count < configuration.maxConcurrent,
            let next = queue.first(where: { $0.state == .queued && running[$0.id] == nil })
        {
            let id = next.id
            running[id] = Task { [weak self] in
                await self?.execute(id)
            }
        }
    }

    private func execute(_ id: String) async {
        defer {
            running[id] = nil
            abortReasons[id] = nil
            lastGrowthCheck[id] = nil
            pump()
        }
        guard let item = queue.first(where: { $0.id == id }), item.state == .queued else {
            // Cancelled between being scheduled and starting: cancel() left the folder to this task.
            if queue.first(where: { $0.id == id })?.state == .cancelled { removeStaging(id) }
            return
        }
        let staging = stagingFolder(id)
        do {
            let admitted: URL
            if let staged = item.stagedFileName,
                FileManager.default.fileExists(atPath: staging.appending(path: staged).path)
            {
                // The download already passed validation; the library refused it last time. Check it again
                // (spec §5.4 step 5) rather than trusting the earlier run, then publish.
                try setState(id, .validating)
                admitted = try await Self.admit(
                    staging.appending(path: staged), staging: staging, track: item.track,
                    maxBytes: configuration.maxFileBytes)
            } else {
                try preflight(item.track)
                guard let provider = providers[item.track.provider] else {
                    throw DownloadFailure("the \(item.track.provider) source is not available in this build")
                }
                try Self.makePrivateFolder(staging)
                try setState(id, .downloading(progress: nil))
                let watchdog = startGrowthWatchdog(id)
                defer { watchdog.cancel() }
                let file = try await download(id, track: item.track, from: provider, into: staging)
                watchdog.cancel()
                try setState(id, .validating)
                admitted = try await Self.admit(
                    file, staging: staging, track: item.track, maxBytes: configuration.maxFileBytes)
            }
            try setStaged(id, admitted.lastPathComponent)
            // Past this point cancel() refuses, so the library never receives a file from a cancelled job.
            try setState(id, .saving)
            do {
                try await publish(admitted)
            } catch {
                throw DownloadFailure("the library could not save it: \(error.localizedDescription)", retryable: true)
            }
            update(id) {
                $0.stagedFileName = nil
                $0.state = .published
            }
            removeStaging(id)
        } catch is CancellationError {
            if let reason = abortReasons[id] {
                fail(id, DownloadFailure(reason))
            } else {
                removeStaging(id)
            }
        } catch let failure as DownloadFailure {
            fail(id, failure)
        } catch {
            fail(id, DownloadFailure(error.localizedDescription))
        }
    }

    /// Size limit and disk space, checked before any byte is downloaded.
    private func preflight(_ track: RemoteTrack) throws(DownloadFailure) {
        guard SafeFileName.sanitize(track.fileName) != nil else {
            throw DownloadFailure("only .flac files are accepted")
        }
        if let claimed = track.sizeBytes, claimed < 0 {
            throw DownloadFailure("the source reported an impossible size")
        }
        let size = track.sizeBytes ?? 0
        guard size <= configuration.maxFileBytes else {
            throw DownloadFailure("the file is larger than the \(configuration.maxFileBytes >> 20) MiB limit")
        }
        // A known size needs room for staging plus a library copy. An unknown one is budgeted at the limit itself,
        // which the growth watchdog enforces while it downloads.
        let (budget, overflowA) =
            track.sizeBytes == nil ? (configuration.maxFileBytes, false) : size.multipliedReportingOverflow(by: 2)
        let (needed, overflowB) = budget.addingReportingOverflow(max(0, configuration.diskMargin))
        guard !overflowA, !overflowB else { throw DownloadFailure("the file is too large") }
        if let free = configuration.freeSpace(configuration.stagingRoot), free < needed {
            throw DownloadFailure("not enough free space (\(needed >> 20) MiB needed)", retryable: true)
        }
    }

    /// Runs the provider's download, retrying thrown errors with backoff. A `.failed` event is final.
    private func download(
        _ id: String, track: RemoteTrack, from provider: any DownloadProvider, into staging: URL
    ) async throws -> URL {
        var attempt = 0
        while true {
            attempt += 1
            update(id) { $0.attempts += 1 }
            do {
                var finished: URL?
                for try await event in provider.download(track, into: staging) {
                    try Task.checkCancellation()
                    // After `.finished` the stream is drained to its end before the file is touched, so a provider
                    // still writing cannot race admission. Later events are ignored.
                    guard finished == nil else { continue }
                    switch event {
                    case .queued:
                        break
                    case .progress(let fraction):
                        try checkGrowthOnProgress(id)
                        reportProgress(id, fraction)
                    case .finished(let url):
                        finished = url
                    case .failed(let reason):
                        throw DownloadFailure(reason)
                    }
                }
                try Task.checkCancellation()
                if let finished { return finished }
                throw DownloadFailure("the source stopped without sending the file", retryable: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as DownloadFailure where !failure.retryable {
                throw failure
            } catch {
                try Task.checkCancellation()
                guard attempt < configuration.maxAttempts else {
                    let reason = (error as? DownloadFailure)?.message ?? error.localizedDescription
                    throw DownloadFailure("\(reason) (gave up after \(attempt) attempts)", retryable: true)
                }
                Self.log.info("download attempt \(attempt, privacy: .public) failed; retrying")
                try await Task.sleep(for: configuration.backoff(attempt))
                try setState(id, .downloading(progress: currentProgress(id)))
            }
        }
    }

    // MARK: Growth

    static let growthFailure = "the download grew past the size limit"

    /// Measures the job's staging folder every `growthCheckInterval` while it downloads, for providers that send
    /// no progress at all.
    private func startGrowthWatchdog(_ id: String) -> Task<Void, Never> {
        let interval = configuration.growthCheckInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.abortIfOversized(id)
            }
        }
    }

    private func abortIfOversized(_ id: String) {
        guard running[id] != nil, stagingBytes(id) > configuration.maxFileBytes else { return }
        Self.log.error("download outgrew the size limit; stopping it")
        abortReasons[id] = Self.growthFailure
        running[id]?.cancel()
    }

    /// The same check on progress events, at most every 100 ms so a chatty provider costs little.
    private func checkGrowthOnProgress(_ id: String) throws(DownloadFailure) {
        let now = ContinuousClock.now
        if let last = lastGrowthCheck[id], now - last < .milliseconds(100) { return }
        lastGrowthCheck[id] = now
        if stagingBytes(id) > configuration.maxFileBytes { throw DownloadFailure(Self.growthFailure) }
    }

    /// Total size of the regular files in the job's staging folder, without following links.
    private func stagingBytes(_ id: String) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard
            let files = FileManager.default.enumerator(
                at: stagingFolder(id), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: State

    private func index(of id: String) -> Int? { queue.firstIndex(where: { $0.id == id }) }

    private func currentProgress(_ id: String) -> Double? {
        guard let index = index(of: id), case .downloading(let progress) = queue[index].state else { return nil }
        return progress
    }

    /// Moves a live job to `state`, or throws `CancellationError` if it was cancelled meanwhile.
    private func setState(_ id: String, _ state: DownloadState) throws(CancellationError) {
        guard let index = index(of: id), queue[index].state != .cancelled, !Task.isCancelled else {
            throw CancellationError()
        }
        queue[index].state = state
        // States only, never names or paths (§5.8): enough to follow a job in a device log.
        Self.log.info(
            "download \(id.prefix(8), privacy: .public) → \(String(describing: state).prefix(160), privacy: .public)")
        changed(persist: true)
    }

    private func setStaged(_ id: String, _ name: String) throws(CancellationError) {
        guard let index = index(of: id), queue[index].state != .cancelled else { throw CancellationError() }
        update(id, persist: true) { $0.stagedFileName = name }
    }

    private func update(_ id: String, persist: Bool = true, _ change: (inout DownloadItem) -> Void) {
        guard let index = index(of: id) else { return }
        change(&queue[index])
        changed(persist: persist)
    }

    /// Progress changes are frequent, so they are published only per whole percent and never written to disk.
    private func reportProgress(_ id: String, _ fraction: Double) {
        guard let index = index(of: id), case .downloading(let old) = queue[index].state else { return }
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        if let old, (old * 100).rounded(.down) == (clamped * 100).rounded(.down) { return }
        queue[index].state = .downloading(progress: clamped)
        changed(persist: false)
    }

    private func fail(_ id: String, _ failure: DownloadFailure) {
        guard let index = index(of: id), queue[index].state != .cancelled else {
            removeStaging(id)
            return
        }
        Self.log.error("download failed: \(failure.message, privacy: .public)")
        queue[index].state = .failed(failure.message)
        // A validated file waiting for the library is kept for retry; anything else is discarded unless the
        // provider can resume it.
        if queue[index].stagedFileName == nil && !failure.retryable { removeStaging(id) }
        changed(persist: true)
    }

    private func changed(persist: Bool) {
        if persist, let store {
            do {
                try store.save(queue)
            } catch {
                Self.log.error("could not save the download queue: \(error.localizedDescription, privacy: .public)")
            }
        }
        for continuation in subscribers.values { continuation.yield(queue) }
    }

    private func unsubscribe(_ token: UUID) { subscribers[token] = nil }

    // MARK: Files

    private func stagingFolder(_ id: String) -> URL {
        configuration.stagingRoot.appending(path: id, directoryHint: .isDirectory)
    }

    private func removeStaging(_ id: String) {
        try? FileManager.default.removeItem(at: stagingFolder(id))
    }

    /// Owner-only folder, so no other process can plant or read files in it, excluded from backups.
    private static func makePrivateFolder(_ url: URL) throws(DownloadFailure) {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var folder = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        } catch {
            throw DownloadFailure("could not create the staging folder: \(error.localizedDescription)")
        }
    }

    /// Validation reads the file, so it runs off the actor.
    private static func admit(
        _ file: URL, staging: URL, track: RemoteTrack, maxBytes: Int64
    ) async throws(DownloadFailure) -> URL {
        try Admission.admit(file, staging: staging, track: track, maxBytes: maxBytes)
    }
}
