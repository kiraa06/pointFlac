import CryptoKit
import Foundation
import PFDownloads
import PFTestSupport
import Synchronization
import Testing

@testable import PFArchive

@Suite("Archive downloads")
struct ArchiveDownloadTests {
    static func bytes(_ fixture: String) -> Data {
        (try? Data(contentsOf: Fixtures.url(Fixtures.named(fixture)))) ?? Data()
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func track(for data: Data, md5: String? = nil, size: Int64? = nil) -> RemoteTrack {
        RemoteTrack(
            id: "archive:item-1/disc 1/Song #1.flac", provider: "archive", title: "Song", fileName: "Song #1.flac",
            sizeBytes: size ?? Int64(data.count),
            detail: [
                "identifier": "item-1", "path": "disc 1/Song #1.flac", "md5": md5 ?? Self.md5(data),
                "licence": "CC0 1.0",
            ])
    }

    static let downloadPath = "/download/item-1/disc%201/Song%20%231.flac"

    /// Runs one download and returns its events, or the error the stream threw.
    func run(_ provider: ArchiveProvider, _ track: RemoteTrack, into staging: URL) async -> (
        events: [DownloadEvent], error: Error?
    ) {
        var events: [DownloadEvent] = []
        do {
            for try await event in provider.download(track, into: staging) { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    @Test("a download streams progress, checks size and MD5, and finishes with the sanitised name")
    func happyPath() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s16-44100")
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in
            .success(StubReply(headers: ["Content-Type": "application/octet-stream"], body: data))
        }
        let (events, error) = await run(network.provider(), Self.track(for: data), into: scratch.url)
        #expect(error == nil)
        let last = try #require(events.last)
        guard case .finished(let url) = last else {
            Issue.record("expected .finished, got \(last)")
            return
        }
        #expect(url.lastPathComponent == "Song #1.flac")
        #expect(url.deletingLastPathComponent().standardizedFileURL == scratch.url.standardizedFileURL)
        #expect(try Data(contentsOf: url) == data)
        #expect(events.contains(.progress(1)))
        #expect(network.paths() == [Self.downloadPath])
    }

    @Test("an existing part file is resumed with a Range request and the result is byte-identical")
    func resume() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s24-96000")
        let split = 10_000
        try data.prefix(split).write(to: scratch.url.appending(path: "Song #1.flac.part"))
        let network = StubNetwork()
        network.route(Self.downloadPath) { request in
            guard request.value(forHTTPHeaderField: "Range") == "bytes=\(split)-" else {
                return .success(StubReply(status: 400))
            }
            return .success(
                StubReply(
                    status: 206, headers: ["Content-Range": "bytes \(split)-\(data.count - 1)/\(data.count)"],
                    body: data.suffix(from: split)))
        }
        let (events, error) = await run(network.provider(), Self.track(for: data), into: scratch.url)
        #expect(error == nil)
        guard case .finished(let url) = events.last else {
            Issue.record("no file: \(events) \(String(describing: error))")
            return
        }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("a server that ignores Range sends the whole file, which replaces the part")
    func resumeIgnored() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s16-48000")
        try Data(repeating: 0xEE, count: 5000).write(to: scratch.url.appending(path: "Song #1.flac.part"))
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in .success(StubReply(body: data)) }
        let (events, _) = await run(network.provider(), Self.track(for: data), into: scratch.url)
        guard case .finished(let url) = events.last else {
            Issue.record("no file: \(events)")
            return
        }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("a dropped connection throws (so the manager retries) and the next attempt resumes where it stopped")
    func truncatedThenResumed() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s24-96000")
        let half = data.count / 2
        let network = StubNetwork()
        network.route(Self.downloadPath) { request in
            if let range = request.value(forHTTPHeaderField: "Range") {
                #expect(range == "bytes=\(half)-")
                return .success(
                    StubReply(
                        status: 206, headers: ["Content-Range": "bytes \(half)-\(data.count - 1)/\(data.count)"],
                        body: data.suffix(from: half)))
            }
            return .success(StubReply(body: data.prefix(half), failure: URLError(.networkConnectionLost)))
        }
        let provider = network.provider()
        let first = await run(provider, Self.track(for: data), into: scratch.url)
        #expect(first.error as? ArchiveError == .offline)
        let part = scratch.url.appending(path: "Song #1.flac.part")
        #expect((try? Data(contentsOf: part))?.count == half)

        let second = await run(provider, Self.track(for: data), into: scratch.url)
        guard case .finished(let url) = second.events.last else {
            Issue.record("no file on resume: \(second)")
            return
        }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("a body that ends early without an error is reported as truncated, keeping the part")
    func shortBody() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s16-44100")
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in .success(StubReply(body: data.prefix(100))) }
        let result = await run(network.provider(), Self.track(for: data), into: scratch.url)
        #expect(result.error as? ArchiveError == .truncated)
        #expect(FileManager.default.fileExists(atPath: scratch.url.appending(path: "Song #1.flac.part").path))
    }

    @Test("404 is a final failure with a readable reason")
    func notFound() async throws {
        let scratch = try Scratch()
        let network = StubNetwork()
        let result = await run(network.provider(), Self.track(for: Data([1])), into: scratch.url)
        #expect(result.error == nil)
        #expect(result.events.last == .failed(ArchiveError.notFound.localizedDescription))
    }

    @Test("offline is thrown, not reported as final, so the manager can retry")
    func offline() async throws {
        let scratch = try Scratch()
        let network = StubNetwork()
        network.route("/") { _ in .failure(URLError(.notConnectedToInternet)) }
        let result = await run(network.provider(), Self.track(for: Data([1])), into: scratch.url)
        #expect(result.error as? ArchiveError == .offline)
    }

    @Test("an MD5 mismatch is final and discards the bytes")
    func checksumMismatch() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s16-44100")
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in .success(StubReply(body: data)) }
        let track = Self.track(for: data, md5: String(repeating: "0", count: 32))
        let result = await run(network.provider(), track, into: scratch.url)
        #expect(result.events.last == .failed(ArchiveError.checksumMismatch.localizedDescription))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).isEmpty)
    }

    @Test("more bytes than listed are refused")
    func oversize() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s16-44100")
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in .success(StubReply(headers: ["Content-Length": "0"], body: data)) }
        let result = await run(network.provider(), Self.track(for: data, size: 1000), into: scratch.url)
        #expect(result.events.last == .failed(ArchiveError.tooLarge.localizedDescription))
    }

    @Test("a web page served in place of the file is refused before it is saved")
    func htmlPayload() async throws {
        let scratch = try Scratch()
        let page = Data("<html>Item not available</html>".utf8)
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in .success(StubReply(headers: ["Content-Type": "text/html"], body: page))
        }
        let result = await run(network.provider(), Self.track(for: page), into: scratch.url)
        #expect(result.events.last == .failed(ArchiveError.notAudio("a web page").localizedDescription))
    }

    @Test("a redirect that leaves HTTPS or the Archive is refused")
    func offsiteRedirect() async throws {
        let scratch = try Scratch()
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in
            .success(StubReply(status: 302, headers: ["Location": "http://evil.example/song.flac"]))
        }
        let result = await run(network.provider(), Self.track(for: Data([1])), into: scratch.url)
        #expect(result.events.last == .failed(ArchiveError.insecure.localizedDescription))
    }

    @Test("a redirect to an Archive storage host is followed and keeps the Range header")
    func storageRedirect() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s16-44100")
        let split = 4096
        try data.prefix(split).write(to: scratch.url.appending(path: "Song #1.flac.part"))
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in
            .success(
                StubReply(status: 302, headers: ["Location": "https://ia800.\(network.host)/7/items/item-1/x.flac"]))
        }
        network.route("/7/items/") { request in
            guard request.value(forHTTPHeaderField: "Range") == "bytes=\(split)-" else {
                return .success(StubReply(body: data))
            }
            return .success(
                StubReply(
                    status: 206, headers: ["Content-Range": "bytes \(split)-\(data.count - 1)/\(data.count)"],
                    body: data.suffix(from: split)))
        }
        let result = await run(network.provider(), Self.track(for: data), into: scratch.url)
        guard case .finished(let url) = result.events.last else {
            Issue.record("no file: \(result)")
            return
        }
        #expect(try Data(contentsOf: url) == data)
        #expect(network.paths().contains("/7/items/item-1/x.flac"))
    }

    // MARK: Through the manager

    func makeManager(_ network: StubNetwork, _ scratch: Scratch, published: Locked<[String]>) -> DownloadManager {
        let library = scratch.url.appending(path: "Library")
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return DownloadManager(
            providers: [network.provider()],
            configuration: .init(
                stagingRoot: scratch.url.appending(path: "Staging"), backoff: { _ in .zero },
                freeSpace: { _ in 100 << 30 }),
            publish: { url in
                try FileManager.default.moveItem(at: url, to: library.appending(path: url.lastPathComponent))
                published.update { $0.append(url.lastPathComponent) }
            })
    }

    func waitFinal(_ manager: DownloadManager) async throws -> DownloadState {
        for _ in 0..<1000 {
            if let state = await manager.items.first?.state, state.isFinal { return state }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await manager.items.first?.state ?? .queued
    }

    @Test("end to end through the manager: an Archive FLAC is downloaded, validated and published")
    func managerHappyPath() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s24-48000")
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in .success(StubReply(body: data)) }
        let published = Locked<[String]>([])
        let manager = makeManager(network, scratch, published: published)
        await manager.enqueue(Self.track(for: data))
        #expect(try await waitFinal(manager) == .published)
        #expect(published.value == ["Song #1.flac"])
    }

    @Test("a non-FLAC payload with a .flac name and a matching MD5 is refused by validation")
    func nonFlacPayload() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("renamed-mp3")
        let network = StubNetwork()
        network.route(Self.downloadPath) { _ in .success(StubReply(body: data)) }
        let published = Locked<[String]>([])
        let manager = makeManager(network, scratch, published: published)
        await manager.enqueue(Self.track(for: data))
        let state = try await waitFinal(manager)
        guard case .failed(let reason) = state else {
            Issue.record("expected failure, got \(state)")
            return
        }
        #expect(reason.contains("not a valid FLAC"))
        #expect(published.value.isEmpty)
    }

    @Test("the manager retries a dropped Archive connection and resumes to a published file")
    func managerResumes() async throws {
        let scratch = try Scratch()
        let data = Self.bytes("s24-96000")
        let half = data.count / 2
        let network = StubNetwork()
        network.route(Self.downloadPath) { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=\(half)-" {
                return .success(
                    StubReply(
                        status: 206, headers: ["Content-Range": "bytes \(half)-\(data.count - 1)/\(data.count)"],
                        body: data.suffix(from: half)))
            }
            return .success(StubReply(body: data.prefix(half), failure: URLError(.networkConnectionLost)))
        }
        let published = Locked<[String]>([])
        let manager = makeManager(network, scratch, published: published)
        await manager.enqueue(Self.track(for: data))
        #expect(try await waitFinal(manager) == .published)
        #expect(await manager.items.first?.attempts == 2)
        #expect(network.requests.withLock { $0.count } == 2)
    }
}
