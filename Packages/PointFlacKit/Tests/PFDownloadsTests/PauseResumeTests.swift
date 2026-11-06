import Foundation
import PFTestSupport
import Synchronization
import Testing

@testable import PFDownloads

/// Kiran's request: pause, resume and cancel downloads. Pausing stops the transfer but keeps the job's staging folder
/// and its partial file; resuming queues the job again into that same folder, so the provider continues from the
/// partial file (an Internet Archive Range request, a Soulseek `.part` offset) instead of starting over.
@Suite("DownloadManager pause and resume")
struct PauseResumeTests {
    /// What a provider saw when a transfer started: the folder it was given, and how much of the part file was there.
    final class StartLog: Sendable {
        private let starts = Mutex<[(staging: URL, offset: Int64)]>([])

        func record(_ staging: URL) {
            let part = staging.appending(path: "incoming.part")
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value
            starts.withLock { $0.append((staging, size ?? 0)) }
        }

        var all: [(staging: URL, offset: Int64)] { starts.withLock { $0 } }
    }

    /// A provider that, like the real ones, resumes from `incoming.part`: the first transfer writes three bytes and
    /// reports 42% before stalling until the job is stopped; a later one finishes, starting where the part file ends.
    static func resumingProvider(_ log: StartLog, gate: Gate? = nil) -> ScriptedProvider {
        ScriptedProvider { track, staging, attempt, events in
            log.record(staging)
            let part = staging.appending(path: "incoming.part")
            if !FileManager.default.fileExists(atPath: part.path) {
                try Data([1, 2, 3]).write(to: part)
                events.yield(.progress(0.42))
                try await Task.sleep(for: .seconds(60))
            }
            if let gate { try await gate.waitCancellably() }
            events.yield(.finished(try deliverFixture(track, staging)))
        }
    }

    @Test("pausing stops the transfer but keeps the staging folder and its partial file; resuming continues from it")
    func pauseKeepsThePartialFileAndResumeContinues() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let log = StartLog()
        let provider = Self.resumingProvider(log)
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100"))
        try await waitFor(manager) { $0.first?.state == .downloading(progress: 0.42) }

        #expect(await manager.pause(id))
        try await waitFor(manager) { _ in provider.active.withLock { $0.now } == 0 }
        try await Task.sleep(for: .milliseconds(50))
        let staging = folder.sub("Staging").appending(path: id)
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: "incoming.part").path))
        let paused = await manager.items.first?.state
        #expect(paused == .paused(progress: 0.42))
        #expect(paused?.label == "Paused · 42%")
        #expect(paused?.isFinal == false)
        #expect(library.names.isEmpty)

        #expect(await manager.resume(id))
        let items = try await waitFor(manager, allFinal)
        #expect(items.first?.state == .published)
        let starts = log.all
        #expect(starts.count == 2)
        #expect(starts.map(\.staging.path) == [staging.path, staging.path], "the same staging folder both times")
        #expect(starts.last?.offset == 3, "the resumed transfer starts where the part file ends")
        #expect(library.names == ["Song.flac"])
    }

    @Test("a queued job that has not started can be paused, stays put, and starts once resumed")
    func pauseAQueuedJob() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let gate = Gate()
        let provider = ScriptedProvider { track, staging, _, events in
            try await gate.waitCancellably()
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library) { $0.maxConcurrent = 1 }
        let first = await manager.enqueue(fixtureTrack("s16-44100", id: "a", fileName: "A.flac"))
        let second = await manager.enqueue(fixtureTrack("s16-44100", id: "b", fileName: "B.flac"))
        try await waitFor(manager) { $0.first?.state == .downloading(progress: nil) }

        #expect(await manager.pause(second))
        #expect(await manager.items.last?.state == .paused(progress: nil))
        #expect(DownloadState.paused(progress: nil).label == "Paused")
        await gate.open()
        try await waitFor(manager) { $0.first?.state == .published }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.items.last?.state == .paused(progress: nil), "a paused job never starts by itself")
        #expect(provider.callCount("b") == 0)

        #expect(await manager.resume(second))
        let items = try await waitFor(manager) { $0.count == 2 && allFinal($0) }
        #expect(items.allSatisfy { $0.state == .published })
        _ = first
    }

    @Test("a job waiting in the source's queue can be paused")
    func pauseAWaitingJob() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { _, _, _, events in
            events.yield(.queued)
            try await Task.sleep(for: .seconds(60))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100"))
        try await waitFor(manager) { $0.first?.state == .waiting }
        #expect(await manager.pause(id))
        #expect(await manager.items.first?.state == .paused(progress: nil))
        try await waitFor(manager) { _ in provider.active.withLock { $0.now } == 0 }
    }

    @Test("once a job is validating, saving or published it is too late to pause")
    func tooLateToPause() async throws {
        let folder = try TempFolder()
        let saving = Gate()
        let library = try LibrarySpy(folder: folder.sub("Library"), gate: saving)
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        let validating = Gate()
        await manager.setValidationHook { _ in await validating.wait() }
        let id = await manager.enqueue(fixtureTrack("s16-44100"))

        try await waitFor(manager) { $0.first?.state == .validating }
        #expect(await manager.pause(id) == false)
        #expect(await manager.items.first?.state == .validating)
        await validating.open()

        try await waitFor(manager) { $0.first?.state == .saving }
        #expect(await manager.pause(id) == false)
        await saving.open()

        let items = try await waitFor(manager, allFinal)
        #expect(items.first?.state == .published)
        #expect(await manager.pause(id) == false)
        #expect(await manager.resume(id) == false, "only a paused job resumes")
        #expect(library.names == ["Song.flac"])
    }

    @Test("a paused job stays paused across a relaunch, with its partial file, and does not start by itself")
    func pausedSurvivesARelaunch() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let stateFile = folder.url.appending(path: "queue.json")
        let log = StartLog()
        let first = makeManager(folder, provider: Self.resumingProvider(log), library: library, stateFile: stateFile)
        await first.restore()
        let id = await first.enqueue(fixtureTrack("s16-44100"))
        try await waitFor(first) { $0.first?.state == .downloading(progress: 0.42) }
        #expect(await first.pause(id))
        try await waitFor(first) { _ in log.all.count == 1 }

        let provider = Self.resumingProvider(log)
        let second = makeManager(folder, provider: provider, library: library, stateFile: stateFile)
        await second.restore()
        try await Task.sleep(for: .milliseconds(100))
        let restored = await second.items
        #expect(restored.map(\.id) == [id])
        #expect(restored.first?.state == .paused(progress: 0.42))
        #expect(provider.callCount("t1") == 0, "a paused job never starts at launch")
        let part = folder.sub("Staging").appending(path: id).appending(path: "incoming.part")
        #expect(FileManager.default.fileExists(atPath: part.path), "restore keeps a paused job's staging")

        #expect(await second.resume(id))
        let items = try await waitFor(second, allFinal)
        #expect(items.first?.state == .published)
        #expect(log.all.last?.offset == 3)
    }

    @Test("a paused job frees its slot for the next queued job; resuming waits for a free slot")
    func pauseFreesASlot() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let gate = Gate()
        let provider = ScriptedProvider { track, staging, _, events in
            try await gate.waitCancellably()
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)  // two at once
        var ids: [String] = []
        for name in ["a", "b", "c"] {
            ids.append(await manager.enqueue(fixtureTrack("s16-44100", id: name, fileName: "\(name).flac")))
        }
        try await waitFor(manager) { $0.filter { $0.state == .downloading(progress: nil) }.count == 2 }
        #expect(await manager.items[2].state == .queued)

        #expect(await manager.pause(ids[0]))
        try await waitFor(manager) { $0[2].state == .downloading(progress: nil) }

        #expect(await manager.resume(ids[0]))
        try await Task.sleep(for: .milliseconds(50))
        let held = await manager.items
        #expect(held[0].state == .queued, "two are running, so the resumed job waits its turn")
        #expect(held.filter { $0.state == .downloading(progress: nil) }.map(\.id) == [ids[1], ids[2]])

        await gate.open()
        let items = try await waitFor(manager) { $0.count == 3 && allFinal($0) }
        #expect(items.allSatisfy { $0.state == .published })
    }

    @Test("resuming respects the per-source cap")
    func resumeRespectsTheSourceCap() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let gate = Gate()
        let byPeer: @Sendable (RemoteTrack) -> String? = { $0.detail["peer"] }
        let provider = ScriptedProvider(concurrencyLimit: 6, source: byPeer) { track, staging, _, events in
            try await gate.waitCancellably()
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library) { $0.maxPerSource = 1 }
        var ids: [String] = []
        for (peer, number) in [("a", 0), ("a", 1), ("b", 0)] {
            var track = fixtureTrack("s16-44100", id: "\(peer)\(number)", fileName: "\(peer) \(number).flac")
            track.detail["peer"] = peer
            ids.append(await manager.enqueue(track))
        }
        try await waitFor(manager) { $0.filter { $0.state == .downloading(progress: nil) }.count == 2 }
        #expect(await manager.items[1].state == .queued)

        #expect(await manager.pause(ids[0]))
        try await waitFor(manager) { $0[1].state == .downloading(progress: nil) }
        #expect(await manager.resume(ids[0]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.items[0].state == .queued, "peer a already sends one, the cap")

        await gate.open()
        let items = try await waitFor(manager) { $0.count == 3 && allFinal($0) }
        #expect(items.allSatisfy { $0.state == .published })
    }

    @Test("Pause All, Resume All and Cancel All act on every job they apply to, and leave finished ones alone")
    func bulkActions() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = ScriptedProvider { track, staging, _, events in
            if track.id != "done" {
                try Data([1, 2, 3]).write(to: staging.appending(path: "incoming.part"))
                events.yield(.progress(0.1))
                try await Task.sleep(for: .seconds(60))
            }
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let manager = makeManager(folder, provider: provider, library: library)
        await manager.enqueue(fixtureTrack("s16-44100", id: "done", fileName: "Done.flac"))
        try await waitFor(manager) { $0.first?.state == .published }
        var ids: [String] = []
        for name in ["a", "b", "c"] {
            ids.append(await manager.enqueue(fixtureTrack("s16-44100", id: name, fileName: "\(name).flac")))
        }
        try await waitFor(manager) { $0.filter { $0.state == .downloading(progress: 0.1) }.count == 2 }

        #expect(await manager.pauseAll() == 3)
        var items = await manager.items
        #expect(items[0].state == .published)
        #expect(items.dropFirst().allSatisfy { if case .paused = $0.state { true } else { false } })
        try await waitFor(manager) { _ in provider.active.withLock { $0.now } == 0 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.items.dropFirst().allSatisfy { if case .paused = $0.state { true } else { false } })
        let staging = folder.sub("Staging")
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: ids[0]).path))
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: ids[1]).path))

        #expect(await manager.resumeAll() == 3)
        items = try await waitFor(manager) { $0.filter { $0.state == .downloading(progress: 0.1) }.count == 2 }
        #expect(items.filter { $0.state == .queued }.count == 1)

        #expect(await manager.cancelAll() == 3)
        items = await manager.items
        #expect(items[0].state == .published)
        #expect(items.dropFirst().allSatisfy { $0.state == .cancelled })
        try await waitFor(manager) { _ in provider.active.withLock { $0.now } == 0 }
        let anyLeft = { ids.contains { FileManager.default.fileExists(atPath: staging.appending(path: $0).path) } }
        for _ in 0..<200 where anyLeft() {
            try await Task.sleep(for: .milliseconds(5))
        }
        for id in ids { #expect(!FileManager.default.fileExists(atPath: staging.appending(path: id).path)) }
        #expect(library.names == ["Done.flac"])
        #expect(await manager.pauseAll() == 0)
        #expect(await manager.resumeAll() == 0)
        #expect(await manager.cancelAll() == 0)
    }

    @Test("cancelling a paused job deletes its staging folder")
    func cancelAPausedJob() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = Self.resumingProvider(StartLog())
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100"))
        try await waitFor(manager) { $0.first?.state == .downloading(progress: 0.42) }
        #expect(await manager.pause(id))
        try await waitFor(manager) { _ in provider.active.withLock { $0.now } == 0 }
        try await Task.sleep(for: .milliseconds(50))
        let staging = folder.sub("Staging").appending(path: id)
        #expect(FileManager.default.fileExists(atPath: staging.path))

        #expect(await manager.cancel(id))
        #expect(await manager.items.first?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("paused, then resumed and cancelled before the transfer stopped: nothing is left behind")
    func pauseResumeCancelInQuickSuccession() async throws {
        let folder = try TempFolder()
        let library = try LibrarySpy(folder: folder.sub("Library"))
        let provider = Self.resumingProvider(StartLog())
        let manager = makeManager(folder, provider: provider, library: library)
        let id = await manager.enqueue(fixtureTrack("s16-44100"))
        try await waitFor(manager) { $0.first?.state == .downloading(progress: 0.42) }
        #expect(await manager.pause(id))
        #expect(await manager.resume(id))
        #expect(await manager.cancel(id))
        try await waitFor(manager) { _ in provider.active.withLock { $0.now } == 0 }
        let staging = folder.sub("Staging").appending(path: id)
        for _ in 0..<200 where FileManager.default.fileExists(atPath: staging.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.items.first?.state == .cancelled)
    }
}

/// When a job publishes, the job remembers the library track it became, so the Downloads list can delete that song.
@Suite("DownloadManager published track")
struct PublishedTrackTests {
    @Test("the library track the publish step reports is kept on the job, across a relaunch")
    func keepsTheTrackID() async throws {
        let folder = try TempFolder()
        let stateFile = folder.url.appending(path: "queue.json")
        let manager = PublishTrackTests.manager(folder, stateFile: stateFile) { file, _ in
            try FileManager.default.removeItem(at: file)
            return Publication(note: nil, trackID: "library-track-7")
        }
        await manager.restore()
        await manager.enqueue(fixtureTrack("s16-44100"))
        let items = try await waitFor(manager, allFinal)
        #expect(items.first?.state == .published)
        #expect(items.first?.publishedTrackID == "library-track-7")

        let relaunched = PublishTrackTests.manager(folder, stateFile: stateFile) { _, _ in Publication() }
        await relaunched.restore()
        #expect(await relaunched.items.first?.publishedTrackID == "library-track-7")
    }

    @Test("old saved queues, written before the track was remembered, still load")
    func oldQueuesLoad() throws {
        let folder = try TempFolder()
        let stateFile = folder.url.appending(path: "queue.json")
        let id = UUID().uuidString
        let json = """
            {"version":1,"items":[{"id":"\(id)","track":{"id":"t1","provider":"fake","title":"Song",\
            "fileName":"Song.flac","detail":{}},"state":{"published":{}},"attempts":1,"createdAt":0,\
            "note":"Saved in pointFlac (folder unavailable)"}]}
            """
        try Data(json.utf8).write(to: stateFile)
        let items = DownloadQueueStore(url: stateFile).load()
        #expect(items.map(\.id) == [id])
        #expect(items.first?.publishedTrackID == nil)
        #expect(items.first?.note == "Saved in pointFlac (folder unavailable)")
    }
}
