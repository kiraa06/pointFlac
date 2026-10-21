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
    #expect(seen.allSatisfy { $0 == .background }, "ran at \(seen)")
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
    // The pass that lost the track writes no value for the old set of three (its pool is recorded as an attempt on
    // that set), and the second phase of the same pass pools the two that are left.
    let r1 = try #require(track(library, "r1.flac")?.loudness)
    let expected = LoudnessMeter.albumLufs([try direct(-20), try direct(-26)])
    #expect(abs(try #require(r1.albumMeasuredLufs) - expected) <= 0.2)
    let after = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == after, "a current album is left alone")
    #expect(track(library, "r3.flac")?.loudness?.albumMeasuredLufs == r1.albumMeasuredLufs)
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

/// A fixture copy as a track of `album`; the audio is the same for all, which is fine here: a copy gets an ID from its
/// location.
private func quick(
    _ box: ScanSandbox, _ album: String, _ index: Int, in folder: URL? = nil, tags: [(String, String)] = []
)
    throws
{
    try TaggedFlac.write(
        "s16-44100", to: (folder ?? box.libraryFolder).appending(path: "\(album)/\(index).flac"),
        tags: [("TITLE", "\(album)\(index)"), ("ALBUM", album), ("TRACKNUMBER", String(index + 1))] + tags)
}

private final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func bump() { count.withLock { $0 += 1 } }
}

/// Counts the tracks the first phase measures (the hook runs once for each).
private func counting(_ library: Library) -> Counter {
    let counter = Counter()
    library.loudnessHook.withLock { $0 = { _ in counter.bump() } }
    return counter
}

/// An "album" of untagged files can be huge: it is measured track by track, with no album value and no retry.
@Test func aHugeAlbumIsMeasuredWithoutAnAlbumValue() async throws {
    let box = try ScanSandbox()
    for index in 0..<6 { try quick(box, "Big", index) }
    let library = try box.open()
    await library.setMaxLoudnessAlbum(5)
    await library.rescan()
    await library.scanLoudness { _, _ in }
    #expect(library.current.tracks.values.compactMap(\.loudness?.measuredPeak).count == 6)
    #expect(library.current.tracks.values.allSatisfy { $0.loudness?.albumMeasuredPeak == nil })
    let before = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == before)
}

/// N1: an album value is served only while the album still has the tracks it was measured over.
@Test func anAlbumGrowingPastTheCapLosesItsValue() async throws {
    let box = try ScanSandbox()
    for index in 0..<5 { try quick(box, "Edge", index) }
    let library = try box.open()
    await library.setMaxLoudnessAlbum(5)
    await library.rescan()
    await library.scanLoudness { _, _ in }
    #expect(library.current.tracks.values.allSatisfy { $0.loudness?.albumMeasuredPeak != nil })

    try quick(box, "Edge", 5)
    await library.rescan()
    #expect(library.current.tracks.count == 6)
    #expect(
        library.current.tracks.values.allSatisfy { $0.loudness?.albumMeasuredPeak == nil },
        "a value over five tracks is not the album's now")
    let hook = counting(library)
    let before = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(hook.value == 1 && decodes(library) - before == 1, "only the new track is decoded")
    #expect(library.current.tracks.values.allSatisfy { $0.loudness?.albumMeasuredPeak == nil })
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) - before == 1, "the blocked pool is not retried")
}

@Test func anAlbumChangingWhileATrackIsEvictedLosesItsValue() async throws {
    let box = try ScanSandbox()
    // Different audio each, or a new file would be taken for the evicted one moved.
    try box.tone("c0.flac", rmsDbfs: -20, album: "Cloud", number: 1, in: box.external)
    try box.tone("c1.flac", rmsDbfs: -23, album: "Cloud", number: 2, in: box.external)
    let library = try box.open()
    _ = try await library.addFolder(box.external)
    await library.scanLoudness { _, _ in }
    #expect(library.current.tracks.values.allSatisfy { $0.loudness?.albumMeasuredPeak != nil })

    try FileManager.default.moveItem(
        at: box.external.appending(path: "c1.flac"), to: box.external.appending(path: ".c1.flac.icloud"))
    try box.tone("c2.flac", rmsDbfs: -26, album: "Cloud", number: 3, in: box.external)
    await library.rescan()
    #expect(library.current.tracks.values.allSatisfy { $0.loudness?.albumMeasuredPeak == nil })
    let before = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) - before == 1, "the new track only; the album cannot be pooled with one evicted")
    #expect(library.current.tracks.values.allSatisfy { $0.loudness?.albumMeasuredPeak == nil })
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) - before == 1)
}

/// N1 and N2: a track joining a measured album, tagged or not, is the only track decoded in the first phase; the
/// album is then pooled once.
@Test func aJoiningTrackIsMeasuredAloneAndTheAlbumPooledOnce() async throws {
    for tagged in [false, true] {
        let box = try ScanSandbox()
        try box.tone("j1.flac", rmsDbfs: -20, album: "Join", number: 1)
        try box.tone("j2.flac", rmsDbfs: -26, album: "Join", number: 2)
        let library = try box.open()
        await library.rescan()
        await library.scanLoudness { _, _ in }
        let old = try #require(track(library, "j1.flac")?.loudness?.albumMeasuredLufs)

        try box.tone(
            "j3.flac", rmsDbfs: -10, album: "Join", number: 3,
            extra: tagged ? [("REPLAYGAIN_TRACK_GAIN", "-2.0 dB")] : [])
        await library.rescan()
        #expect(track(library, "j1.flac")?.loudness?.albumMeasuredLufs == nil, "stale until it is pooled again")

        let hook = counting(library)
        let before = decodes(library)
        await library.scanLoudness { _, _ in }
        #expect(hook.value == 1, "phase 1 decodes the new track alone (tagged: \(tagged))")
        #expect(decodes(library) - before == 1 + 3, "then one pooling over the three")
        let pooled = try #require(track(library, "j1.flac")?.loudness?.albumMeasuredLufs)
        let expected = LoudnessMeter.albumLufs([try direct(-20), try direct(-26), try direct(-10)])
        #expect(abs(pooled - expected) <= 0.2 && abs(pooled - old) > 0.5)
        await library.scanLoudness { _, _ in }
        #expect(decodes(library) - before == 4, "nothing more")
    }
}

/// N2: a scan interrupted inside a huge album keeps what it measured, picks up where it stopped, and the small albums
/// are not behind it.
@Test func anInterruptedHugeAlbumDoesNotStarveOrRestart() async throws {
    let box = try ScanSandbox()
    for index in 0..<6 { try quick(box, "Big", index) }
    for index in 0..<2 { try quick(box, "Small", index) }
    let library = try box.open()
    await library.setMaxLoudnessAlbum(5)
    await library.rescan()

    let holder = TaskBox()
    let scan = Task {
        await library.scanLoudness { done, _ in
            if done == 3 { holder.task.withLock { $0 }?.cancel() }
        }
    }
    holder.task.withLock { $0 = scan }
    await scan.value
    let states = await library.loudnessStates()
    #expect(states.values.filter { $0 == 1 }.count == 3)
    #expect(track(library, "Small0")?.loudness?.measuredPeak != nil, "the small album went first")
    #expect(track(library, "Small1")?.loudness?.albumMeasuredPeak != nil)

    let before = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) - before == 5, "the five tracks left, none again")
    #expect(library.current.tracks.values.compactMap(\.loudness?.measuredPeak).count == 8)
}

/// A FLAC that says 16 Hz overran libebur128's buffers. It is unmeasurable, recorded as such, and left alone.
@Test func aLowSampleRateFileIsUnmeasurableNotACrash() async throws {
    let box = try ScanSandbox()
    try box.tone(
        "slow.flac", rmsDbfs: -20, album: "Slow", number: 1, spec: ToneFlac.Spec(rate: 16, bits: 16, channels: 2))
    try box.tone("fine.flac", rmsDbfs: -20, album: "Fine", number: 1)
    let library = try box.open()
    await library.rescan()
    #expect(track(library, "slow.flac")?.format.sampleRate == 16)
    await library.scanLoudness { _, _ in }
    let slow = try #require(track(library, "slow.flac"))
    #expect(await library.loudnessStates()[slow.id] == 2)
    #expect(slow.loudness == nil)
    #expect(track(library, "fine.flac")?.loudness?.measuredLufs != nil)
    let before = decodes(library)
    await library.scanLoudness { _, _ in }
    #expect(decodes(library) == before, "never retried until the file changes")
}

/// A scan asked for while another runs is merged into it, not dropped.
@Test func aScanRequestedDuringAScanIsServed() async throws {
    let box = try ScanSandbox()
    try box.tone("x1.flac", rmsDbfs: -20, album: "X", number: 1)
    try box.tone("y1.flac", rmsDbfs: -22, album: "Y", number: 1)
    let library = try box.open()
    await library.rescan()
    let y = try #require(track(library, "y1.flac")?.albumID)
    let x = try #require(track(library, "x1.flac")?.albumID)

    let reached = Mutex(false)
    let gate = Mutex<(open: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))
    library.loudnessHook.withLock {
        $0 = { _ in
            reached.withLock { $0 = true }
            await withCheckedContinuation { continuation in
                let proceed = gate.withLock { state in
                    if state.open { return true }
                    state.waiter = continuation
                    return false
                }
                if proceed { continuation.resume() }
            }
        }
    }
    let first = Task { await library.scanLoudness(albums: [x]) { _, _ in } }
    while !reached.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
    await library.scanLoudness(albums: [y]) { _, _ in }  // returns at once
    #expect(track(library, "y1.flac")?.loudness == nil)
    gate.withLock { state in
        state.open = true
        state.waiter?.resume()
    }
    await first.value
    #expect(track(library, "x1.flac")?.loudness?.measuredLufs != nil)
    #expect(track(library, "y1.flac")?.loudness?.measuredLufs != nil, "served by the running scan's follow-up")
}

/// Cancelled inside a track, between decode chunks.
@Test func cancellingInsideATrackStopsAtTheNextChunk() async throws {
    let box = try ScanSandbox()
    try box.tone("long.flac", rmsDbfs: -20, number: 1)  // 18 chunks
    let library = try box.open()
    await library.rescan()
    let holder = TaskBox()
    let chunks = Mutex(0)
    library.loudnessChunkHook.withLock {
        $0 = {
            if chunks.withLock({
                $0 += 1
                return $0
            }) == 3 {
                holder.task.withLock { $0 }?.cancel()
            }
        }
    }
    let scan = Task { await library.scanLoudness { _, _ in } }
    holder.task.withLock { $0 = scan }
    await scan.value
    #expect(chunks.withLock { $0 } <= 4, "stopped within a chunk of the cancel, not after all 18")
    #expect(track(library, "long.flac")?.loudness == nil)
    library.loudnessChunkHook.withLock { $0 = nil }
    await library.scanLoudness { _, _ in }
    #expect(track(library, "long.flac")?.loudness?.measuredLufs != nil)
}
