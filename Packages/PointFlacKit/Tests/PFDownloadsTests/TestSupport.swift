import Foundation
import PFTestSupport
import Synchronization
import Testing

@testable import PFDownloads

/// A temporary folder for one test, removed when the test ends.
final class TempFolder: Sendable {
    let url: URL

    init(_ label: String = #function) throws {
        let safe = label.filter { $0.isLetter || $0.isNumber }
        url = FileManager.default.temporaryDirectory.appending(
            path: "PFDownloadsTests-\(safe)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func sub(_ name: String) -> URL { url.appending(path: name, directoryHint: .isDirectory) }
}

/// A gate a fake provider or publisher waits at until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A provider whose behaviour each test scripts. `attempt` counts calls to `download` for that track, from 1.
final class ScriptedProvider: DownloadProvider {
    typealias Script =
        @Sendable (
            _ track: RemoteTrack, _ staging: URL, _ attempt: Int,
            _ events: AsyncThrowingStream<DownloadEvent, Error>.Continuation
        ) async throws -> Void

    let id: String
    let displayName = "Scripted"
    let calls = Mutex<[String: Int]>([:])
    let active = Mutex<(now: Int, peak: Int)>((0, 0))
    private let script: Script

    init(id: String = "fake", script: @escaping Script) {
        self.id = id
        self.script = script
    }

    func search(_ query: String) -> AsyncThrowingStream<[RemoteTrack], Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func download(_ track: RemoteTrack, into staging: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        let attempt = calls.withLock { counts in
            counts[track.id, default: 0] += 1
            return counts[track.id]!
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                self.active.withLock { state in
                    state.now += 1
                    state.peak = max(state.peak, state.now)
                }
                defer { self.active.withLock { $0.now -= 1 } }
                do {
                    try await self.script(track, staging, attempt, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func callCount(_ trackID: String) -> Int { calls.withLock { $0[trackID] ?? 0 } }
}

/// Records what reached the library.
final class LibrarySpy: Sendable {
    let folder: URL
    private let published = Mutex<[String]>([])
    private let failuresLeft: Mutex<Int>
    private let gate: Gate?

    init(folder: URL, failFirst: Int = 0, gate: Gate? = nil) throws {
        self.folder = folder
        self.failuresLeft = Mutex(failFirst)
        self.gate = gate
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var names: [String] { published.withLock { $0 } }

    var publish: DownloadManager.Publish {
        { [self] url in
            if let gate { await gate.wait() }
            let shouldFail = failuresLeft.withLock { left in
                defer { left = max(0, left - 1) }
                return left > 0
            }
            if shouldFail { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
            published.withLock { $0.append(url.lastPathComponent) }
        }
    }
}

func fixtureTrack(_ fixture: String, id: String = "t1", fileName: String = "Song.flac", size: Int64? = nil)
    -> RemoteTrack
{
    let url = Fixtures.url(Fixtures.named(fixture))
    let actual = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    return RemoteTrack(
        id: id, provider: "fake", title: "Song", fileName: fileName, sizeBytes: size ?? actual,
        detail: ["fixture": fixture])
}

/// Copies the track's fixture into staging as the provider's result.
func deliverFixture(_ track: RemoteTrack, _ staging: URL) throws -> URL {
    let source = Fixtures.url(Fixtures.named(track.detail["fixture"]!))
    let target = staging.appending(path: "incoming.part")
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.copyItem(at: source, to: target)
    return target
}

func makeManager(
    _ folder: TempFolder, provider: ScriptedProvider, library: LibrarySpy, stateFile: URL? = nil,
    configure: (inout DownloadManager.Configuration) -> Void = { _ in }
) -> DownloadManager {
    var configuration = DownloadManager.Configuration(
        stagingRoot: folder.sub("Staging"), stateFile: stateFile, backoff: { _ in .zero },
        freeSpace: { _ in 100 << 30 })
    configure(&configuration)
    return DownloadManager(providers: [provider], configuration: configuration, publish: library.publish)
}

/// Polls until `predicate` holds for the queue, failing the test after `timeout`.
@discardableResult
func waitFor(
    _ manager: DownloadManager, timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation,
    _ predicate: @Sendable ([DownloadItem]) -> Bool
) async throws -> [DownloadItem] {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let items = await manager.items
        if predicate(items) { return items }
        try await Task.sleep(for: .milliseconds(5))
    }
    let items = await manager.items
    Issue.record("timed out; states: \(items.map(\.state))", sourceLocation: sourceLocation)
    return items
}

func allFinal(_ items: [DownloadItem]) -> Bool { !items.isEmpty && items.allSatisfy(\.state.isFinal) }

func failureMessage(_ state: DownloadState) -> String? {
    if case .failed(let message) = state { return message }
    return nil
}
