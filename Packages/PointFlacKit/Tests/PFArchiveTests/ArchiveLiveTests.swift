import Foundation
import PFDownloads
import PFFlac
import Synchronization
import Testing

@testable import PFArchive

/// Talks to the real Internet Archive. Off by default; run with `PF_LIVE_TESTS=1 swift test --filter ArchiveLive`.
@Suite("Archive live", .enabled(if: ProcessInfo.processInfo.environment["PF_LIVE_TESTS"] == "1"))
struct ArchiveLiveTests {
    @Test("search the real Archive and publish one small open-licence FLAC end to end", .timeLimit(.minutes(3)))
    func endToEnd() async throws {
        let provider = ArchiveProvider()
        var found: [RemoteTrack] = []
        // "dusty-sense" is a 3.5 MB 24-bit CC0 upload, small enough to download in a test.
        for try await batch in provider.search("dusty-sense") { found += batch }
        print("live: \(found.count) tracks: \(found.prefix(5).map { "\($0.id) [\($0.detail["licence"] ?? "?")]" })")
        let track = try #require(
            found.filter { ($0.sizeBytes ?? .max) < 10_000_000 }.min { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) })
        #expect(track.detail["licence"] != nil)

        let scratch = try Scratch()
        let library = scratch.url.appending(path: "Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let published = Locked<[URL]>([])
        let manager = DownloadManager(
            providers: [provider],
            configuration: .init(stagingRoot: scratch.url.appending(path: "Staging")),
            publish: { url in
                let target = library.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                published.update { $0.append(target) }
            })
        let started = ContinuousClock.now
        await manager.enqueue(track)
        var state = DownloadState.queued
        while !state.isFinal, ContinuousClock.now - started < .seconds(150) {
            try await Task.sleep(for: .milliseconds(200))
            state = await manager.items.first?.state ?? .queued
        }
        print("live: \(track.id) → \(state.label) in \(ContinuousClock.now - started)")
        #expect(state == .published)
        let file = try #require(published.value.first)
        let info = try FlacValidator.validate(fileAt: file)
        print("live: published \(file.lastPathComponent), \(info.bitsPerSample)-bit \(info.sampleRate) Hz")
        #expect(info.bitsPerSample == track.bitsPerSample ?? info.bitsPerSample)
    }

    @Test("a broad real search yields only open-licence original FLAC, in batches", .timeLimit(.minutes(2)))
    func broadSearch() async throws {
        let started = ContinuousClock.now
        var batches: [[RemoteTrack]] = []
        var firstBatch: Duration?
        for try await batch in ArchiveProvider().search("ambient drone") {
            if firstBatch == nil { firstBatch = ContinuousClock.now - started }
            batches.append(batch)
        }
        let tracks = batches.flatMap { $0 }
        let licences = Set(tracks.compactMap { $0.detail["licence"] })
        print(
            "live: 'ambient drone' → \(batches.count) items, \(tracks.count) tracks, first batch after "
                + "\(firstBatch ?? .zero), all after \(ContinuousClock.now - started); licences \(licences.sorted())")
        #expect(!tracks.isEmpty)
        #expect(tracks.allSatisfy { $0.fileName.lowercased().hasSuffix(".flac") && $0.detail["licence"] != nil })
        #expect(tracks.allSatisfy { ($0.sizeBytes ?? 0) > 0 && $0.detail["md5"]?.count == 32 })
    }

    @Test("this week's real Friday Drops shelf holds confirmed open-licence FLAC albums", .timeLimit(.minutes(2)))
    func fridayDrops() async throws {
        let scratch = try Scratch()
        let started = ContinuousClock.now
        let shelf = try await FridayDrops(
            provider: ArchiveProvider(), snapshotFile: scratch.url.appending(path: "d.json")
        )
        .shelf()
        print("live: Friday Drops \(shelf.week) → \(shelf.drops.count) albums in \(ContinuousClock.now - started)")
        for drop in shelf.drops {
            print("live:   \(drop.id) | \(drop.title) | \(drop.licence) | \(drop.tracks.count) tracks")
        }
        #expect(shelf.drops.count == FridayDrops.shelfSize)
        #expect(shelf.drops.allSatisfy { !$0.tracks.isEmpty && $0.licence != ArchiveLicence.etree.name })
    }

    @Test("a real download resumes from a part file with a Range request through the Archive's redirect")
    func resume() async throws {
        let provider = ArchiveProvider()
        var found: [RemoteTrack] = []
        for try await batch in provider.search("dusty-sense") { found += batch }
        let track = try #require(found.first { $0.id == "archive:dusty-sense/dusty-sense.flac" })

        let scratch = try Scratch()
        let whole = scratch.url.appending(path: "whole", directoryHint: .isDirectory)
        let partial = scratch.url.appending(path: "partial", directoryHint: .isDirectory)
        for folder in [whole, partial] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var first: URL?
        for try await event in provider.download(track, into: whole) {
            if case .finished(let url) = event { first = url }
        }
        let reference = try Data(contentsOf: try #require(first))
        let split = 1_000_000
        try reference.prefix(split).write(to: partial.appending(path: "dusty-sense.flac.part"))

        var fractions: [Double] = []
        var resumed: URL?
        for try await event in provider.download(track, into: partial) {
            if case .progress(let fraction) = event { fractions.append(fraction) }
            if case .finished(let url) = event { resumed = url }
        }
        print("live: resume from \(split) bytes, first progress \(fractions.first ?? -1)")
        #expect(try Data(contentsOf: try #require(resumed)) == reference)
        #expect((fractions.first ?? 0) >= Double(split) / Double(reference.count), "the transfer started mid-file")
    }
}
