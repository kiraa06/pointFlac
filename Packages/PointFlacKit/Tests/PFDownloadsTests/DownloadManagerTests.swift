import Foundation
import PFTestSupport
import Testing

@testable import PFDownloads

@Suite("DownloadManager")
struct DownloadManagerTests {
    // MARK: Happy path

    @Test("a valid FLAC is validated, published under its sanitised name, and staging is cleaned up")
    func publishesValidFlac() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.progress(0.5))
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100", fileName: "../../01 Song.flac"))

        let items = try await waitFor(manager, allFinal)
        #expect(items.first?.state == .published)
        #expect(library.names == ["01 Song.flac"])
        #expect(!FileManager.default.fileExists(atPath: folder.sub("Staging").appending(path: id).path))
    }

    @Test("the update stream walks queued, downloading, validating, saving, published in order")
    func statesInOrder() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let updates = await manager.updates(buffering: 1000)
        await manager.enqueue(fixtureTrack("s24-96000"))

        var labels: [String] = []
        for await snapshot in updates {
            guard let state = snapshot.first?.state else { continue }
            if labels.last != state.label { labels.append(state.label) }
            if state.isFinal { break }
        }
        #expect(labels == ["Queued", "Downloading", "Checking", "Saving", "Done"])
    }

    @Test("enqueueing the same track twice while it is in flight returns the same job")
    func deduplicatesInFlight() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let gate = Gate()
        let provider = ScriptedProvider { track, staging, _, events in
            await gate.wait()
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let first = await manager.enqueue(fixtureTrack("s16-44100"))
        let second = await manager.enqueue(fixtureTrack("s16-44100"))
        #expect(first == second)
        await gate.open()
        try await waitFor(manager, allFinal)
        #expect(await manager.items.count == 1)
    }

    // MARK: Admission

    @Test(
        "files that are not real FLAC never reach the library",
        arguments: ["renamed-mp3", "bad-frame-crc", "bad-streaminfo", "empty", "truncated-meta"])
    func rejectsNonFlac(fixture: String) async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack(fixture))

        let items = try await waitFor(manager, allFinal)
        let message = try #require(failureMessage(items[0].state))
        #expect(message.contains("FLAC") || message.contains("empty"))
        #expect(library.names.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.sub("Staging").appending(path: id).path))
    }

    @Test("a provider that points outside its staging folder is refused")
    func refusesEscape() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let outside = folder.url.appending(path: "outside.flac")
        try FileManager.default.copyItem(at: Fixtures.url(Fixtures.named("s16-44100")), to: outside)
        let provider = ScriptedProvider { _, staging, _, events in
            events.yield(.finished(staging.appending(path: "../../outside.flac")))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        await manager.enqueue(fixtureTrack("s16-44100"))

        let items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("outside") == true)
        #expect(library.names.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path), "a file outside staging is never moved")
    }

    @Test("a symlink in staging is refused even when it points at real FLAC")
    func refusesSymlink() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { _, staging, _, events in
            let link = staging.appending(path: "link.flac")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: Fixtures.url(Fixtures.named("s16-44100")))
            events.yield(.finished(link))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        await manager.enqueue(fixtureTrack("s16-44100"))

        let items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("plain file") == true)
        #expect(library.names.isEmpty)
    }

    @Test("a file shorter than the listed size fails as incomplete")
    func sizeMismatch() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library) { $0.maxAttempts = 1 }
        let real = fixtureTrack("s16-44100").sizeBytes!
        await manager.enqueue(fixtureTrack("s16-44100", size: real + 100))

        let items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("incomplete") == true)
        #expect(library.names.isEmpty)
    }

    @Test("a track over the size limit, or not named .flac, is refused before any download")
    func preflightRefusals() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library) { $0.maxFileBytes = 1000 }
        await manager.enqueue(fixtureTrack("s16-44100", id: "big"))
        await manager.enqueue(fixtureTrack("s16-44100", id: "mp3", fileName: "song.mp3", size: 10))

        let items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("larger") == true)
        #expect(failureMessage(items[1].state)?.contains(".flac") == true)
        #expect(provider.callCount("big") == 0 && provider.callCount("mp3") == 0)
    }

    @Test("a full disk stops the download before it starts")
    func diskFull() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library) { $0.freeSpace = { _ in 1 << 20 } }
        await manager.enqueue(fixtureTrack("s16-44100"))

        let items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("free space") == true)
        #expect(provider.callCount("t1") == 0)
    }

    // MARK: Scheduling, retry, cancel

    @Test("never more than two downloads run at once, and all of them finish")
    func boundedConcurrency() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            try await Task.sleep(for: .milliseconds(30))
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        for index in 0..<6 {
            await manager.enqueue(fixtureTrack("s16-44100", id: "t\(index)", fileName: "Song \(index).flac"))
        }

        let items = try await waitFor(manager) { $0.count == 6 && allFinal($0) }
        #expect(items.allSatisfy { $0.state == .published })
        #expect(provider.active.withLock { $0.peak } == 2)
        #expect(library.names.count == 6)
    }

    @Test("a provider's own limit replaces the shared one")
    func providerLimit() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let gate = Gate()
        let provider = ScriptedProvider(concurrencyLimit: 4) { track, staging, _, events in
            await gate.wait()
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)  // shared limit: 2
        for index in 0..<6 {
            await manager.enqueue(fixtureTrack("s16-44100", id: "t\(index)", fileName: "Song \(index).flac"))
        }

        try await waitFor(manager) { $0.filter { $0.state == .downloading(progress: nil) }.count == 4 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.items.filter { $0.state == .queued }.count == 2)
        await gate.open()
        let items = try await waitFor(manager) { $0.count == 6 && allFinal($0) }
        #expect(items.allSatisfy { $0.state == .published })
        #expect(provider.active.withLock { $0.peak } == 4)
    }

    @Test("one source cannot take every slot: a later job from another source starts while the first one's extra wait")
    func perSourceLimit() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let gate = Gate()
        let byPeer: @Sendable (RemoteTrack) -> String? = { $0.detail["peer"] }
        let provider = ScriptedProvider(concurrencyLimit: 6, source: byPeer) { track, staging, _, events in
            await gate.wait()
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        for (peer, number) in [("a", 0), ("a", 1), ("a", 2), ("b", 0)] {
            var track = fixtureTrack("s16-44100", id: "\(peer)\(number)", fileName: "\(peer) \(number).flac")
            track.detail["peer"] = peer
            await manager.enqueue(track)
        }

        let running = try await waitFor(manager) { $0.filter { $0.state == .downloading(progress: nil) }.count == 3 }
        #expect(Set(running.filter { $0.state == .downloading(progress: nil) }.map(\.track.id)) == ["a0", "a1", "b0"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.items.first { $0.track.id == "a2" }?.state == .queued)
        await gate.open()
        let items = try await waitFor(manager) { $0.count == 4 && allFinal($0) }
        #expect(items.allSatisfy { $0.state == .published })
    }

    @Test("a source holding the request without sending shows as waiting until bytes flow")
    func waitingState() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let gate = Gate()
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.queued)
            await gate.wait()
            events.yield(.progress(0.5))
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let updates = await manager.updates(buffering: 1000)
        await manager.enqueue(fixtureTrack("s24-96000"))
        try await waitFor(manager) { $0.first?.state == .waiting }
        #expect(DownloadState.waiting.label == "Waiting")
        #expect(!DownloadState.waiting.isFinal)
        await gate.open()

        var labels: [String] = []
        for await snapshot in updates {
            guard let state = snapshot.first?.state else { continue }
            if labels.last != state.label { labels.append(state.label) }
            if state.isFinal { break }
        }
        #expect(labels == ["Queued", "Downloading", "Waiting", "Downloading", "Checking", "Saving", "Done"])
    }

    @Test("a thrown error is retried with the partial file kept, so the provider can resume")
    func retriesAndResumes() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, attempt, events in
            let part = staging.appending(path: "incoming.part")
            if attempt == 1 {
                try Data([1, 2, 3]).write(to: part)
                throw URLError(.networkConnectionLost)
            }
            #expect(FileManager.default.fileExists(atPath: part.path), "the part file survives the retry")
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        await manager.enqueue(fixtureTrack("s16-44100"))

        let items = try await waitFor(manager, allFinal)
        #expect(items[0].state == .published)
        #expect(items[0].attempts == 2)
    }

    @Test("after the last attempt the job fails, and retry() starts it again")
    func givesUpThenManualRetry() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, attempt, events in
            if attempt <= 3 { throw URLError(.timedOut) }
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100"))

        var items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("gave up after 3 attempts") == true)
        #expect(await manager.retry(id))
        items = try await waitFor(manager, allFinal)
        #expect(items[0].state == .published)
    }

    @Test("a .failed event from the provider is final and not retried")
    func providerFailureIsFinal() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { _, _, _, events in events.yield(.failed("peer refused")) }
        let manager = makeManager(folder, provider: provider, library: library)
        await manager.enqueue(fixtureTrack("s16-44100"))

        let items = try await waitFor(manager, allFinal)
        #expect(items[0].state == .failed("peer refused"))
        #expect(provider.callCount("t1") == 1)
    }

    @Test("cancelling mid-download stops the provider and deletes only the staging folder")
    func cancelMidDownload() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { _, staging, _, events in
            try Data([1, 2, 3]).write(to: staging.appending(path: "incoming.part"))
            events.yield(.progress(0.3))
            try await Task.sleep(for: .seconds(60))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100"))
        try await waitFor(manager) { $0.first?.state == .downloading(progress: 0.3) }

        #expect(await manager.cancel(id))
        try await waitFor(manager) { _ in provider.active.withLock { $0.now } == 0 }
        let staging = folder.sub("Staging").appending(path: id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(await manager.items.first?.state == .cancelled)
        #expect(library.names.isEmpty)
    }

    @Test("a job that is saving cannot be cancelled, so published music is never removed")
    func cannotCancelWhileSaving() async throws {
        let folder = try TempFolder()
        let gate = Gate()
        let library = try LibrarySpy(folder: folder.sub("Library"), gate: gate)
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100"))
        try await waitFor(manager) { $0.first?.state == .saving }

        #expect(await manager.cancel(id) == false)
        await gate.open()
        let items = try await waitFor(manager, allFinal)
        #expect(items[0].state == .published)
        #expect(await manager.cancel(id) == false)
        #expect(FileManager.default.fileExists(atPath: library.folder.appending(path: "Song.flac").path))
    }

    @Test("when the library refuses a file, retry republishes it without downloading again")
    func publishFailureThenRetry() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"), failFirst: 1)
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100"))

        var items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("library") == true)
        #expect(await manager.retry(id))
        items = try await waitFor(manager, allFinal)
        #expect(items[0].state == .published)
        #expect(provider.callCount("t1") == 1)
        #expect(library.names == ["Song.flac"])
    }

    // MARK: Providers that misbehave

    @Test("after .finished the stream is drained first, so bytes written before it ends are what gets validated")
    func drainsBeforeAdmitting() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            let file = try deliverFixture(track, staging)
            events.yield(.finished(file))
            try await Task.sleep(for: .milliseconds(100))
            // Still writing after reporting the file done: the magic is overwritten.
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data("XXXX".utf8))
            try handle.close()
        }
        let manager = makeManager(folder, provider: provider, library: library)
        await manager.enqueue(fixtureTrack("s16-44100"))
        let items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("not a valid FLAC") == true)
        #expect(library.names.isEmpty)
    }

    @Test("a writer that keeps its descriptor after the stream ends cannot change the published file")
    func publishesASnapshot() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let original = try Data(contentsOf: Fixtures.url(Fixtures.named("s16-44100")))
        let provider = ScriptedProvider { track, staging, _, events in
            let file = try deliverFixture(track, staging)
            let handle = try FileHandle(forWritingTo: file)
            events.yield(.finished(file))
            let published = library.folder.appending(path: "Song.flac")
            Task.detached {
                for _ in 0..<400 where !FileManager.default.fileExists(atPath: published.path) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                try? handle.seek(toOffset: 0)
                try? handle.write(contentsOf: Data(repeating: 0, count: 64))
                try? handle.close()
            }
        }
        let manager = makeManager(folder, provider: provider, library: library)
        await manager.enqueue(fixtureTrack("s16-44100"))
        let items = try await waitFor(manager, allFinal)
        #expect(items[0].state == .published)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: library.folder.appending(path: "Song.flac")) == original)
    }

    @Test("a negative or overflowing size is refused before any download")
    func impossibleSizes() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { _, _, _, _ in Issue.record("nothing should be downloaded") }
        let manager = makeManager(folder, provider: provider, library: library) { $0.maxFileBytes = .max }
        await manager.enqueue(fixtureTrack("s16-44100", id: "negative", size: -1))
        await manager.enqueue(fixtureTrack("s16-44100", id: "huge", size: .max))
        let items = try await waitFor(manager) { $0.count == 2 && allFinal($0) }
        #expect(failureMessage(items[0].state)?.contains("impossible size") == true)
        #expect(failureMessage(items[1].state)?.contains("too large") == true)
    }

    @Test(
        "a provider of unknown size that keeps writing is stopped at the size limit, with or without progress",
        arguments: [false, true])
    func growthLimit(sendsProgress: Bool) async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { _, staging, _, events in
            let file = staging.appending(path: "endless.part")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            for step in 0..<10_000 {
                try handle.write(contentsOf: Data(repeating: 0xAB, count: 10_000))
                if sendsProgress { events.yield(.progress(Double(step) / 10_000)) }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let manager = makeManager(folder, provider: provider, library: library) {
            $0.maxFileBytes = 100_000
            // With progress the per-event check must catch it; without, only the watchdog can.
            $0.growthCheckInterval = sendsProgress ? .seconds(600) : .milliseconds(20)
        }
        let id = await manager.enqueue(fixtureTrack("s16-44100", size: nil))
        let items = try await waitFor(manager, allFinal)
        #expect(items[0].state == .failed(DownloadManager.growthFailure))
        try await waitFor(manager) { _ in provider.active.withLock { $0.now } == 0 }
        #expect(!FileManager.default.fileExists(atPath: folder.sub("Staging").appending(path: id).path))
    }

    @Test("cancelling a job that was scheduled but had not started yet still removes its staging folder")
    func cancelBeforeStart() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        // Every attempt drops the connection, leaving a part file behind for resume.
        let provider = ScriptedProvider { _, staging, _, _ in
            try Data([1, 2, 3]).write(to: staging.appending(path: "incoming.part"))
            throw URLError(.networkConnectionLost)
        }
        let manager = makeManager(folder, provider: provider, library: library) { $0.maxAttempts = 1 }
        let id = await manager.enqueue(fixtureTrack("s16-44100"))
        try await waitFor(manager, allFinal)
        let staging = folder.sub("Staging").appending(path: id)
        for _ in 0..<20 {
            try Data([1]).write(to: staging.appending(path: "incoming.part"))
            #expect(await manager.retry(id))
            #expect(await manager.cancel(id))
            try await waitFor(manager) { $0.first?.state == .cancelled }
            for _ in 0..<200 where FileManager.default.fileExists(atPath: staging.path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!FileManager.default.fileExists(atPath: staging.path))
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }
    }

    // MARK: Persistence

    @Test("the queue survives a relaunch, and an interrupted download resumes and publishes")
    func persistsAcrossLaunches() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let stateFile = folder.url.appending(path: "queue.json")

        // First launch: the download hangs, as if the app were killed mid-transfer.
        let hanging = ScriptedProvider { _, staging, _, events in
            try Data([1, 2, 3]).write(to: staging.appending(path: "incoming.part"))
            events.yield(.progress(0.1))
            try await Task.sleep(for: .seconds(60))
        }
        let first = makeManager(folder, provider: hanging, library: library, stateFile: stateFile)
        await first.restore()
        let doneID = await first.enqueue(fixtureTrack("s16-44100", id: "kept", fileName: "Kept.flac"))
        try await waitFor(first) { $0.first?.state == .downloading(progress: 0.1) }
        let snapshot = folder.url.appending(path: "queue-at-kill.json")
        try FileManager.default.copyItem(at: stateFile, to: snapshot)
        _ = doneID

        // Second launch reads the queue as it was when the app died.
        let resumed = ScriptedProvider { track, staging, _, events in
            #expect(FileManager.default.fileExists(atPath: staging.appending(path: "incoming.part").path))
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let second = makeManager(folder, provider: resumed, library: library, stateFile: snapshot)
        await second.restore()
        let items = try await waitFor(second, allFinal)
        #expect(items.map(\.track.id) == ["kept"])
        #expect(items[0].state == .published)
        #expect(library.names == ["Kept.flac"])

        // A third launch shows the finished job as history and does not download it again.
        let third = makeManager(folder, provider: resumed, library: library, stateFile: snapshot)
        await third.restore()
        #expect(await third.items.first?.state == .published)
        #expect(resumed.callCount("kept") == 1)
        await first.cancel(doneID)
    }

    @Test("a job that was saving when the app died, whose file already left staging, is not downloaded again")
    func interruptedWhileSaving() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let stateFile = folder.url.appending(path: "queue.json")
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        var item = DownloadItem(id: firstID, track: fixtureTrack("s16-44100"), state: .saving, attempts: 1)
        item.stagedFileName = "Song.flac"
        var waiting = DownloadItem(id: secondID, track: fixtureTrack("s16-44100", id: "t2"), state: .saving)
        waiting.stagedFileName = "Song.flac"
        try DownloadQueueStore(url: stateFile).save([item, waiting])
        // job-2's validated file is still in staging, so it is checked again and published.
        let staging2 = folder.sub("Staging").appending(path: secondID)
        try FileManager.default.createDirectory(at: staging2, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Fixtures.url(Fixtures.named("s16-44100")), to: staging2.appending(path: "Song.flac"))

        let provider = ScriptedProvider { _, _, _, _ in Issue.record("nothing should be downloaded") }
        let manager = makeManager(folder, provider: provider, library: library, stateFile: stateFile)
        await manager.restore()
        let items = try await waitFor(manager, allFinal)
        #expect(failureMessage(items[0].state)?.contains("check the library") == true)
        #expect(items[1].state == .published)
        #expect(library.names == ["Song.flac"])
    }

    @Test("free space is measured even before the staging folder exists")
    func diskSpaceOfMissingFolder() throws {
        let folder = try TempFolder()
        #expect(DiskSpace.available(at: folder.url.appending(path: "not/yet/here")) != nil)
    }

    @Test("a damaged queue file is moved aside rather than crashing or being overwritten")
    func damagedQueueFile() throws {
        let folder = try TempFolder()
        let file = folder.url.appending(path: "queue.json")
        try Data("{not json".utf8).write(to: file)
        #expect(DownloadQueueStore(url: file).load().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names.contains { $0.hasPrefix("queue.json.corrupt-") })
        #expect(!names.contains("queue.json"))
    }

    @Test("hostile ids and staged names in the queue file are dropped one item at a time")
    func hostileQueueItems() throws {
        let folder = try TempFolder()
        let file = folder.url.appending(path: "queue.json")
        var good = DownloadItem(id: UUID().uuidString, track: fixtureTrack("s16-44100"))
        good.stagedFileName = "Song.flac"
        try DownloadQueueStore(url: file).save([good])
        let template = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let goodItem = (template["items"] as! [[String: Any]])[0]
        var traversal = goodItem
        traversal["id"] = "../../Documents"
        var stagedEscape = goodItem
        stagedEscape["id"] = UUID().uuidString
        stagedEscape["stagedFileName"] = "../../../evil.flac"
        let broken: [String: Any] = ["id": UUID().uuidString, "state": 42]
        let body: [String: Any] = ["version": 1, "items": [traversal, goodItem, stagedEscape, broken]]
        try JSONSerialization.data(withJSONObject: body).write(to: file)

        let loaded = DownloadQueueStore(url: file).load()
        #expect(loaded.map(\.id) == [good.id])
        #expect(loaded.first?.stagedFileName == "Song.flac")
    }

    @Test("the queue file is excluded from backups")
    func queueFileNotBackedUp() throws {
        let folder = try TempFolder()
        let file = folder.url.appending(path: "queue.json")
        try DownloadQueueStore(url: file).save([])
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("restore removes staging folders that no live job owns")
    func orphanedStaging() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let stateFile = folder.url.appending(path: "queue.json")
        let done = DownloadItem(id: UUID().uuidString, track: fixtureTrack("s16-44100", id: "a"), state: .published)
        let failed = DownloadItem(
            id: UUID().uuidString, track: fixtureTrack("s16-44100", id: "b"), state: .failed("dropped"))
        try DownloadQueueStore(url: stateFile).save([done, failed])
        let root = folder.sub("Staging")
        let orphan = UUID().uuidString
        for name in [done.id, failed.id, orphan, "not-a-job"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        let provider = ScriptedProvider { _, _, _, _ in }
        let manager = makeManager(folder, provider: provider, library: library, stateFile: stateFile)
        await manager.restore()
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == [failed.id, "not-a-job"], "a failed job keeps its part file for retry")
    }
}

@Suite("DownloadsObserver")
@MainActor
struct DownloadsObserverTests {
    @Test("the main-actor mirror follows the manager to the published state")
    func mirrors() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let observer = DownloadsObserver(manager: manager)
        await manager.enqueue(fixtureTrack("s16-44100"))
        for _ in 0..<1000 where observer.items.first?.state != .published {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(observer.items.first?.state == .published)
        #expect(observer.items.first?.state.label == "Done")
        #expect(observer.items.first?.state.progress == 1)
    }
}
