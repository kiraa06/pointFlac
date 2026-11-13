import Foundation
import PFTestSupport
import Synchronization
import Testing

@testable import PFDownloads

/// The publish step files a download by its artist and album when the user picked a folder for downloads, so it is
/// told which track the file is; and when it had to save somewhere else (the folder could not be reached), what it
/// says is kept on the job for the Downloads list, across launches.
@Suite("DownloadManager publishing with the track")
struct PublishTrackTests {
    static func manager(
        _ folder: TempFolder, stateFile: URL? = nil, publish: @escaping DownloadManager.PublishTrack
    ) -> DownloadManager {
        let provider = ScriptedProvider { track, staging, _, events in
            events.yield(.finished(try deliverFixture(track, staging)))
        }
        let configuration = DownloadManager.Configuration(
            stagingRoot: folder.sub("Staging"), stateFile: stateFile, backoff: { _ in .zero },
            freeSpace: { _ in 100 << 30 })
        return DownloadManager(providers: [provider], configuration: configuration, publishTrack: publish)
    }

    @Test("publish is handed the validated file together with the track it is")
    func receivesTheTrack() async throws {
        let folder = try TempFolder()
        let seen = Mutex<[(name: String, artist: String?, album: String?)]>([])
        let manager = Self.manager(folder) { file, track in
            seen.withLock { $0.append((file.lastPathComponent, track.artist, track.album)) }
            try FileManager.default.removeItem(at: file)
            return Publication()
        }
        var track = fixtureTrack("s16-44100", fileName: "01 Fold.flac")
        track.artist = "Ada Vale"
        track.album = "Paper Moons"
        await manager.enqueue(track)

        let items = try await waitFor(manager, allFinal)

        #expect(items.first?.state == .published)
        #expect(items.first?.note == nil)
        let calls = seen.withLock { $0 }
        #expect(calls.count == 1)
        #expect(calls.first?.name == "01 Fold.flac")
        #expect(calls.first?.artist == "Ada Vale")
        #expect(calls.first?.album == "Paper Moons")
    }

    @Test("what publish says about where the file went is kept on the finished job, across a relaunch")
    func keepsTheNote() async throws {
        let folder = try TempFolder()
        let stateFile = folder.url.appending(path: "queue.json")
        let manager = Self.manager(folder, stateFile: stateFile) { file, _ in
            try FileManager.default.removeItem(at: file)
            return Publication(note: "Saved in pointFlac (folder unavailable)")
        }
        await manager.restore()
        await manager.enqueue(fixtureTrack("s16-44100"))

        let items = try await waitFor(manager, allFinal)
        #expect(items.first?.state == .published)
        #expect(items.first?.note == "Saved in pointFlac (folder unavailable)")

        let relaunched = Self.manager(folder, stateFile: stateFile) { _, _ in Publication() }
        await relaunched.restore()
        let restored = await relaunched.items
        #expect(restored.first?.state == .published)
        #expect(restored.first?.note == "Saved in pointFlac (folder unavailable)")
    }

    @Test("old saved queues, written before notes existed, still load")
    func oldQueuesLoad() throws {
        let folder = try TempFolder()
        let stateFile = folder.url.appending(path: "queue.json")
        let id = UUID().uuidString
        let json = """
            {"version":1,"items":[{"id":"\(id)","track":{"id":"t1","provider":"fake","title":"Song",\
            "fileName":"Song.flac","detail":{}},"state":{"published":{}},"attempts":1,"createdAt":0}]}
            """
        try Data(json.utf8).write(to: stateFile)
        let items = DownloadQueueStore(url: stateFile).load()
        #expect(items.map(\.id) == [id])
        #expect(items.first?.state == .published)
        #expect(items.first?.note == nil)
    }
}
