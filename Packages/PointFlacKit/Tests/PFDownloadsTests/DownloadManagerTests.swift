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

    @Test("a damaged queue file is ignored rather than crashing")
    func damagedQueueFile() throws {
        let folder = try TempFolder()
        let file = folder.url.appending(path: "queue.json")
        try Data("{not json".utf8).write(to: file)
        #expect(DownloadQueueStore(url: file).load().isEmpty)
    }
}
