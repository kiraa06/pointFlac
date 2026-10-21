import Foundation
import PFCore
import PFLoudness
import Synchronization
import Testing

@testable import PFLibrary

/// Plan 4, Task 11: ReplayGain tags into the library, and the background EBU R128 scan of what has none.
private final class ScanSandbox {
    let root: URL
    var libraryFolder: URL { root.appending(path: "Documents/Library", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "LoudnessScan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func open() throws -> Library {
        try Library(
            databaseURL: root.appending(path: "Support/library.sqlite"), libraryFolder: libraryFolder,
            artworkFolder: root.appending(path: "Support/Artwork", directoryHint: .isDirectory))
    }

    /// A tone of `rmsDbfs` in the library folder, tagged into `album`.
    func tone(_ name: String, rmsDbfs: Double, album: String = "Tones", number: Int, extra: [(String, String)] = [])
        throws
    {
        try ToneFlac.write(
            to: libraryFolder.appending(path: name), rmsDbfs: rmsDbfs,
            tags: [("TITLE", name), ("ARTIST", "Tone"), ("ALBUM", album), ("TRACKNUMBER", String(number))] + extra)
    }
}

private func direct(_ rmsDbfs: Double) throws -> LoudnessMeter {
    let floats = ToneFlac.floats(ToneFlac.samples(rmsDbfs: rmsDbfs))
    let meter = try LoudnessMeter(channels: 2, sampleRate: ToneFlac.rate)
    floats.withUnsafeBufferPointer { meter.add($0, frames: floats.count / 2) }
    return meter
}

private func track(_ library: Library, _ title: String) -> LibraryTrack? {
    library.current.tracks.values.first { $0.title == title }
}

@Test func tagsAreStored() async throws {
    let box = try ScanSandbox()
    try TaggedFlac.write(
        "s16-44100", to: box.libraryFolder.appending(path: "tagged.flac"),
        tags: [
            ("TITLE", "Tagged"), ("replaygain_track_gain", "-6.20 dB"), ("REPLAYGAIN_TRACK_PEAK", "0.953"),
            ("REPLAYGAIN_ALBUM_GAIN", "+1.5 dB"), ("REPLAYGAIN_ALBUM_PEAK", "1.0"),
        ])
    try TaggedFlac.write("s16-44100", to: box.libraryFolder.appending(path: "plain.flac"), tags: [("TITLE", "Plain")])
    let library = try box.open()
    await library.rescan()
    let tagged = try #require(track(library, "Tagged")?.loudness)
    #expect(tagged.trackGainDb == -6.2 && tagged.trackPeak == 0.953)
    #expect(tagged.albumGainDb == 1.5 && tagged.albumPeak == 1.0)
    #expect(tagged.measuredLufs == nil && tagged.albumMeasuredLufs == nil)
    #expect(track(library, "Plain")?.loudness == nil)
}

@Test func scanMeasuresUntagged() async throws {
    let box = try ScanSandbox()
    try box.tone("a.flac", rmsDbfs: -20, number: 1)
    try box.tone("b.flac", rmsDbfs: -26, number: 2)
    let library = try box.open()
    await library.rescan()
    #expect(track(library, "a.flac")?.loudness == nil)

    let seen = Mutex<[[Int]]>([])
    await library.scanLoudness { done, total in seen.withLock { $0.append([done, total]) } }

    let a = try #require(track(library, "a.flac")?.loudness)
    let b = try #require(track(library, "b.flac")?.loudness)
    let meterA = try direct(-20)
    let meterB = try direct(-26)
    #expect(abs(try #require(a.measuredLufs) - meterA.integratedLufs) <= 0.2)
    #expect(abs(try #require(b.measuredLufs) - meterB.integratedLufs) <= 0.2)
    let peakA = try #require(a.measuredPeak)
    #expect(abs(20 * log10(peakA) - meterA.truePeakDbTP) <= 0.2)
    let album = LoudnessMeter.albumLufs([meterA, meterB])
    #expect(abs(try #require(a.albumMeasuredLufs) - album) <= 0.2)
    #expect(a.albumMeasuredLufs == b.albumMeasuredLufs)
    #expect(a.albumMeasuredPeak == max(a.measuredPeak ?? 0, b.measuredPeak ?? 0))
    #expect(seen.withLock { $0 } == [[0, 2], [1, 2], [2, 2]])
    // Stored, so it survives a restart.
    let reopened = try box.open()
    #expect(track(reopened, "b.flac")?.loudness?.measuredLufs == b.measuredLufs)
}

@Test func scanSkipsTaggedAndMeasured() async throws {
    let box = try ScanSandbox()
    try box.tone("t1.flac", rmsDbfs: -20, album: "Tagged", number: 1, extra: [("REPLAYGAIN_TRACK_GAIN", "-3.0 dB")])
    try box.tone("t2.flac", rmsDbfs: -22, album: "Tagged", number: 2, extra: [("REPLAYGAIN_TRACK_GAIN", "-1.0 dB")])
    let library = try box.open()
    await library.rescan()
    await library.scanLoudness { _, _ in }
    #expect(library.loudnessDecodes.withLock { $0 } == 0)
    #expect(track(library, "t1.flac")?.loudness?.measuredLufs == nil)

    // A measured album is not decoded again either.
    try box.tone("u1.flac", rmsDbfs: -24, album: "Plain", number: 1)
    await library.rescan()
    await library.scanLoudness { _, _ in }
    #expect(library.loudnessDecodes.withLock { $0 } == 1)
    await library.scanLoudness { _, _ in }
    #expect(library.loudnessDecodes.withLock { $0 } == 1)
}

private final class TaskBox: Sendable {
    let task = Mutex<Task<Void, Never>?>(nil)
}

@Test func cancelledScanKeepsItsProgressAndResumes() async throws {
    let box = try ScanSandbox()
    for (index, level) in [-20.0, -23.0, -26.0].enumerated() {
        try box.tone("c\(index + 1).flac", rmsDbfs: level, number: index + 1)
    }
    let library = try box.open()
    await library.rescan()

    let holder = TaskBox()
    let scan = Task {
        await library.scanLoudness { done, _ in
            if done == 1 { holder.task.withLock { $0 }?.cancel() }
        }
    }
    holder.task.withLock { $0 = scan }
    await scan.value

    let first = try #require(track(library, "c1.flac")?.loudness)
    #expect(first.measuredLufs != nil)
    #expect(track(library, "c3.flac")?.loudness?.measuredLufs == nil)
    #expect(first.albumMeasuredLufs == nil, "an unfinished album has no album value")

    // The next scan finishes the album.
    await library.scanLoudness { _, _ in }
    for title in ["c1.flac", "c2.flac", "c3.flac"] {
        let loudness = try #require(track(library, title)?.loudness)
        #expect(loudness.measuredLufs != nil && loudness.albumMeasuredLufs != nil)
    }
}

@Test func trackRemovedDuringScanStaysRemoved() async throws {
    let box = try ScanSandbox()
    for (index, level) in [-20.0, -23.0, -26.0].enumerated() {
        try box.tone("r\(index + 1).flac", rmsDbfs: level, number: index + 1)
    }
    let library = try box.open()
    await library.rescan()
    let doomed = try #require(track(library, "r2.flac")?.id)

    let removedOnce = Mutex(false)
    library.loudnessHook.withLock {
        $0 = { _ in
            let first = removedOnce.withLock { done in
                defer { done = true }
                return !done
            }
            guard first else { return }
            _ = try? await library.remove(trackIDs: [doomed])
        }
    }
    await library.scanLoudness { _, _ in }

    #expect(library.current.tracks.count == 2)
    #expect(track(library, "r2.flac") == nil, "the scan must not bring the track back")
    #expect(try box.open().current.tracks.count == 2)
    #expect(track(library, "r1.flac")?.loudness?.measuredLufs != nil)
    #expect(track(library, "r3.flac")?.loudness?.measuredLufs != nil)
    #expect(track(library, "r1.flac")?.loudness?.albumMeasuredLufs == nil, "an album that lost a track in flight")
}

@Test func scanMeasuresMultichannelAndSurvivesUnreadableFiles() async throws {
    let box = try ScanSandbox()
    try TaggedFlac.write(
        "s16-48000-6ch", to: box.libraryFolder.appending(path: "six.flac"), tags: [("TITLE", "Six"), ("ALBUM", "M")])
    let library = try box.open()
    await library.rescan()
    #expect(track(library, "Six")?.format.channels == 6)
    // The file vanishes before the scan reaches it: no crash, no value.
    try FileManager.default.removeItem(at: box.libraryFolder.appending(path: "six.flac"))
    await library.scanLoudness { _, _ in }
    try TaggedFlac.write(
        "s16-48000-6ch", to: box.libraryFolder.appending(path: "six2.flac"), tags: [("TITLE", "Six2"), ("ALBUM", "M2")])
    await library.rescan()
    await library.scanLoudness { _, _ in }
    #expect(track(library, "Six2")?.loudness?.measuredLufs != nil)
}
