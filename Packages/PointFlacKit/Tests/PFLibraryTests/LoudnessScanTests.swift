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

    var external: URL { root.appending(path: "External Music", directoryHint: .isDirectory) }

    /// A tone of `rmsDbfs` tagged into `album`, in the library folder or in `folder`.
    func tone(
        _ name: String, rmsDbfs: Double, album: String = "Tones", number: Int, extra: [(String, String)] = [],
        spec: ToneFlac.Spec = .stereo16, in folder: URL? = nil
    ) throws {
        try ToneFlac.write(
            to: (folder ?? libraryFolder).appending(path: name), rmsDbfs: rmsDbfs, spec,
            tags: [("TITLE", name), ("ARTIST", "Tone"), ("ALBUM", album), ("TRACKNUMBER", String(number))] + extra)
    }
}

private func direct(_ rmsDbfs: Double, _ spec: ToneFlac.Spec = .stereo16) throws -> LoudnessMeter {
    let floats = ToneFlac.floats(ToneFlac.samples(rmsDbfs: rmsDbfs, spec), spec)
    let meter = try LoudnessMeter(channels: spec.channels, sampleRate: spec.rate)
    floats.withUnsafeBufferPointer { meter.add($0, frames: floats.count / spec.channels) }
    return meter
}

private func track(_ library: Library, _ title: String) -> LibraryTrack? {
    library.current.tracks.values.first { $0.title == title }
}

private func decodes(_ library: Library) -> Int { library.loudnessDecodes.withLock { $0 } }

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
    #expect(decodes(library) == 0)
    #expect(track(library, "t1.flac")?.loudness?.measuredLufs == nil)

    // A measured, current album is not decoded again either.
    try box.tone("u1.flac", rmsDbfs: -24, album: "Plain", number: 1)
    await library.rescan()
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == 1)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == 1)
}

@Test func hiResAndMultichannelMatchADirectMeter() async throws {
    let box = try ScanSandbox()
    let hires = ToneFlac.Spec(rate: 96_000, bits: 24, channels: 2)
    let surround = ToneFlac.Spec(rate: 48_000, bits: 16, channels: 6)
    try box.tone("hi.flac", rmsDbfs: -18, album: "Hi", number: 1, spec: hires)
    try box.tone("six.flac", rmsDbfs: -24, album: "Six", number: 1, spec: surround)
    let library = try box.open()
    await library.rescan()
    #expect(track(library, "six.flac")?.format.channels == 6)
    await library.scanLoudness { _, _ in }
    let hi = try #require(track(library, "hi.flac")?.loudness)
    let six = try #require(track(library, "six.flac")?.loudness)
    let hiMeter = try direct(-18, hires)
    let sixMeter = try direct(-24, surround)
    #expect(abs(try #require(hi.measuredLufs) - hiMeter.integratedLufs) <= 0.2)
    #expect(abs(try #require(six.measuredLufs) - sixMeter.integratedLufs) <= 0.2)
    #expect(abs(20 * log10(try #require(hi.measuredPeak)) - hiMeter.truePeakDbTP) <= 0.2)
    // Nothing near the floor: a 24-bit scale error would show as tens of dB.
    #expect(try #require(hi.measuredLufs) > -30)
}

/// No sentinel: a track with no usable integrated loudness is measured (its peak is set) and says so with a nil LUFS.
@Test func silentAndTooShortTracksAreMeasuredWithoutLufs() async throws {
    let box = try ScanSandbox()
    try box.tone("silent.flac", rmsDbfs: -300, album: "Odd", number: 1)
    try TaggedFlac.write(  // 93 ms: shorter than one gating block
        "s16-44100", to: box.libraryFolder.appending(path: "short.flac"),
        tags: [("TITLE", "short.flac"), ("ALBUM", "Odd"), ("TRACKNUMBER", "2")])
    let library = try box.open()
    await library.rescan()
    await library.scanLoudness { _, _ in }
    let silent = try #require(track(library, "silent.flac")?.loudness)
    let short = try #require(track(library, "short.flac")?.loudness)
    #expect(silent.measuredLufs == nil && silent.measuredPeak == 0)
    #expect(short.measuredLufs == nil && (short.measuredPeak ?? 0) > 0)
    #expect(silent.albumMeasuredLufs == nil && silent.albumMeasuredPeak != nil)
    // Measured, so not decoded again.
    let before = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == before)
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

/// Cancelled before the first chunk: nothing stored, nothing crashes, and the next scan does the work.
@Test func cancellingAtTheStartStoresNothing() async throws {
    let box = try ScanSandbox()
    try box.tone("s1.flac", rmsDbfs: -20, number: 1)
    let library = try box.open()
    await library.rescan()
    let holder = TaskBox()
    let scan = Task {
        await library.scanLoudness { done, _ in
            if done == 0 { holder.task.withLock { $0 }?.cancel() }
        }
    }
    holder.task.withLock { $0 = scan }
    await scan.value
    #expect(track(library, "s1.flac")?.loudness == nil)
    await library.scanLoudness { _, _ in }
    #expect(track(library, "s1.flac")?.loudness?.measuredLufs != nil)
}

/// Awaiting a task raises it to the awaiter's priority, so a scan started by the UI must not decode at the UI's.
@Test func scanRunsAtBackgroundPriorityEvenWhenAwaitedFromAHighOne() async throws {
    let box = try ScanSandbox()
    try box.tone("p1.flac", rmsDbfs: -20, number: 1)
    let library = try box.open()
    await library.rescan()
    let observed = Mutex<[TaskPriority]>([])
    library.loudnessHook.withLock { $0 = { _ in observed.withLock { $0.append(Task.currentPriority) } } }
    await Task(priority: .userInitiated) {
        #expect(Task.currentPriority == .userInitiated)
        await library.scanLoudness { _, _ in }
    }.value
    let seen = observed.withLock { $0 }
    #expect(!seen.isEmpty)
    #expect(seen.allSatisfy { $0 <= .utility }, "ran at \(seen)")
}

/// The track is removed from the library after it was measured and before its measurement is stored, from a folder
/// added in place, so its file is still there. The write must not bring the row back, and the album, which lost a
/// track in flight, gets no value from that pass. The next pass gives the two tracks left their own.
@Test func trackRemovedDuringScanStaysRemoved() async throws {
    let box = try ScanSandbox()
    for (index, level) in [-20.0, -23.0, -26.0].enumerated() {
        try box.tone("r\(index + 1).flac", rmsDbfs: level, number: index + 1, in: box.external)
    }
    let library = try box.open()
    _ = try await library.addFolder(box.external)
    let doomed = try #require(track(library, "r2.flac")?.id)

    library.loudnessHook.withLock {
        $0 = { id in
            if id == doomed { _ = try? await library.remove(trackIDs: [id]) }
        }
    }
    await library.scanLoudness { _, _ in }

    #expect(FileManager.default.fileExists(atPath: box.external.appending(path: "r2.flac").path))
    #expect(library.current.tracks.count == 2)
    #expect(track(library, "r2.flac") == nil, "the write must not bring the track back")
    let reopened = try box.open()
    #expect(reopened.current.tracks.count == 2)
    #expect(track(library, "r1.flac")?.loudness?.measuredLufs != nil)
    #expect(track(library, "r3.flac")?.loudness?.measuredLufs != nil)
    #expect(track(library, "r1.flac")?.loudness?.albumMeasuredLufs == nil, "no value for an album that lost a track")

    library.loudnessHook.withLock { $0 = nil }
    await library.scanLoudness { _, _ in }
    let r1 = try #require(track(library, "r1.flac")?.loudness)
    let expected = LoudnessMeter.albumLufs([try direct(-20), try direct(-26)])
    #expect(abs(try #require(r1.albumMeasuredLufs) - expected) <= 0.2)
    let after = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == after, "a current album is left alone")
}

/// A file whose size or date changed loses its measurement; an album retagged into a new album gets a value there.
@Test func changedFilesLoseTheirMeasurementAndRetaggedAlbumsAreRemeasured() async throws {
    let box = try ScanSandbox()
    try box.tone("m1.flac", rmsDbfs: -20, album: "Old", number: 1)
    try box.tone("m2.flac", rmsDbfs: -26, album: "Old", number: 2)
    let library = try box.open()
    await library.rescan()
    await library.scanLoudness { _, _ in }
    #expect(track(library, "m1.flac")?.loudness?.measuredLufs != nil)

    // Only the date changes: the measurement goes.
    let file = box.libraryFolder.appending(path: "m1.flac")
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: file.path)
    await library.rescan()
    #expect(track(library, "m1.flac")?.loudness?.measuredLufs == nil)
    #expect(track(library, "m2.flac")?.loudness?.measuredLufs != nil)

    // Retagged into another album: the audio is the same, the file changed.
    try box.tone("m1.flac", rmsDbfs: -20, album: "New", number: 1)
    try box.tone("m2.flac", rmsDbfs: -26, album: "New", number: 2)
    await library.rescan()
    #expect(track(library, "m2.flac")?.loudness?.measuredLufs == nil)
    await library.scanLoudness { _, _ in }
    let m1 = try #require(track(library, "m1.flac")?.loudness)
    let expected = LoudnessMeter.albumLufs([try direct(-20), try direct(-26)])
    #expect(abs(try #require(m1.albumMeasuredLufs) - expected) <= 0.2)
    #expect(track(library, "m1.flac")?.album == "New")
}

/// A removal that leaves a measured album with a different set of tracks makes its value stale.
@Test func aPartialRemovalMakesTheAlbumValueStale() async throws {
    let box = try ScanSandbox()
    for (index, level) in [-20.0, -23.0, -26.0].enumerated() {
        try box.tone("p\(index + 1).flac", rmsDbfs: level, number: index + 1)
    }
    let library = try box.open()
    await library.rescan()
    await library.scanLoudness { _, _ in }
    let before = try #require(track(library, "p1.flac")?.loudness?.albumMeasuredLufs)
    _ = try await library.remove(trackIDs: [try #require(track(library, "p3.flac")?.id)])
    await library.scanLoudness { _, _ in }
    let after = try #require(track(library, "p1.flac")?.loudness?.albumMeasuredLufs)
    let expected = LoudnessMeter.albumLufs([try direct(-20), try direct(-23)])
    #expect(abs(after - expected) <= 0.2 && abs(after - before) > 0.2)
}

/// An evicted file is never decoded or downloaded; its album still gets its readable tracks' values, but no album value.
@Test func evictedTracksAreLeftAlone() async throws {
    let box = try ScanSandbox()
    try box.tone("e1.flac", rmsDbfs: -20, number: 1, in: box.external)
    try box.tone("e2.flac", rmsDbfs: -26, number: 2, in: box.external)
    let library = try box.open()
    _ = try await library.addFolder(box.external)
    try FileManager.default.moveItem(
        at: box.external.appending(path: "e2.flac"), to: box.external.appending(path: ".e2.flac.icloud"))
    await library.rescan()
    #expect(track(library, "e2.flac")?.isCloudPending == true)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == 1)
    let first = try #require(track(library, "e1.flac")?.loudness)
    #expect(first.measuredLufs != nil && first.albumMeasuredPeak == nil)
    #expect(track(library, "e2.flac")?.loudness == nil)
    let before = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == before, "an album with an evicted track is not retried on every scan")
}

/// An "album" of untagged files can be huge: it is measured track by track, with no album value and no retry.
@Test func aHugeAlbumIsMeasuredWithoutAnAlbumValue() async throws {
    let box = try ScanSandbox()
    let count = LoudnessScanner.maxAlbumTracks + 1
    for index in 0..<count {
        try TaggedFlac.write(
            "s16-44100", to: box.libraryFolder.appending(path: "big/\(index).flac"),
            tags: [("TITLE", "t\(index)"), ("ALBUM", "Big"), ("TRACKNUMBER", String(index + 1))])
    }
    let library = try box.open()
    await library.rescan()
    await library.scanLoudness { _, _ in }
    let measured = library.current.tracks.values.compactMap(\.loudness?.measuredPeak)
    #expect(measured.count == count)
    #expect(library.current.tracks.values.allSatisfy { $0.loudness?.albumMeasuredPeak == nil })
    let before = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == before)
}
