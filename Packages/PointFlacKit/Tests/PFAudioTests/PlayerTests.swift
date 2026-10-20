import Foundation
import PFCore
import PFFlac
import PFTestSupport
import Synchronization
import Testing

@testable import PFAudio

// MARK: - Doubles

/// Records what the player publishes, and lets a test send remote commands through `onCommand`.
@MainActor
private final class FakeNowPlaying: NowPlayingPublishing {
    struct Shown: Equatable {
        var title: String
        var elapsed: Duration
        var playing: Bool
    }

    private(set) var shown: [Shown] = []
    private(set) var clearCount = 0
    var onCommand: ((RemoteCommand) -> Void)?

    func show(_ item: QueueItem, elapsed: Duration, playing: Bool) {
        shown.append(Shown(title: item.title, elapsed: elapsed, playing: playing))
    }

    func clear() {
        clearCount += 1
    }
}

/// Ten seconds of synthetic 16-bit stereo at 44.1 kHz, so nothing ends mid-test. Sample (n, c) is
/// ((2n + c) mod 65536) − 32768, so any stretch of the capture can be checked against the frame it should start at.
private final class PatternDecoder: PCMDecoding {
    static let sourceFormat = AudioFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2)
    static let frames: Int64 = 441_000

    static func samples(from frame: Int64, count frames: Int) -> [Int32] {
        (0..<(frames * 2)).map { Int32((2 * frame + Int64($0)) % 65_536) - 32_768 }
    }

    var format: AudioFormat { Self.sourceFormat }
    var totalFrames: Int64 { Self.frames }
    private var position: Int64 = 0

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        let n = Int(min(Int64(min(maxFrames, buffer.count / 2)), Self.frames - position))
        for i in 0..<(n * 2) {
            buffer[i] = Int32((2 * position + Int64(i)) % 65_536) - 32_768
        }
        position += Int64(n)
        return n
    }

    func seek(toFrame frame: Int64) throws {
        position = frame
    }
}

/// Counts the seeks a decoder receives. The decode thread bumps it, the test reads it.
private final class SeekCounter: Sendable {
    private let seeks = Atomic<Int>(0)
    var count: Int { seeks.load(ordering: .acquiring) }
    func bump() { seeks.add(1, ordering: .releasing) }
}

/// Passes everything through to a real decoder and counts its seeks.
private final class ObservedDecoder: PCMDecoding {
    private let inner: PCMDecoding
    private let seeks: SeekCounter

    init(_ inner: PCMDecoding, seeks: SeekCounter) {
        self.inner = inner
        self.seeks = seeks
    }

    var format: AudioFormat { inner.format }
    var totalFrames: Int64 { inner.totalFrames }

    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int {
        try inner.read(into: buffer, maxFrames: maxFrames)
    }

    func seek(toFrame frame: Int64) throws {
        seeks.bump()
        try inner.seek(toFrame: frame)
    }
}

/// An audio session whose `requestSampleRate` does not return until the test releases it, and which records how many
/// requests were inside it at once.
private final class SuspendingSession: AudioSessionControlling {
    private struct State {
        var entered: [Int] = []
        var inside = 0
        var mostInside = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    let events = AsyncStream<SessionEvent> { $0.finish() }
    private let state = Mutex(State())

    var currentPort: OutputPort { .builtIn }
    var outputVolume: Float { 1 }
    var sampleRate: Int { 48_000 }
    /// The rates requested so far, in the order they reached the session.
    var entered: [Int] { state.withLock { $0.entered } }
    /// The most requests that were inside the session at the same time.
    var mostInside: Int { state.withLock { $0.mostInside } }

    func activate(preferredRate: Int?) async throws {}

    func requestSampleRate(_ hz: Int) async -> Int {
        await withCheckedContinuation { continuation in
            state.withLock { s in
                s.entered.append(hz)
                s.inside += 1
                s.mostInside = max(s.mostInside, s.inside)
                s.waiting.append(continuation)
            }
        }
        state.withLock { $0.inside -= 1 }
        return hz
    }

    /// Lets the oldest request inside the session return.
    func releaseOne() {
        let next = state.withLock { s in s.waiting.isEmpty ? nil : s.waiting.removeFirst() }
        next?.resume()
    }

    /// Lets every request inside the session return.
    func releaseAll() {
        let all = state.withLock { s in
            defer { s.waiting.removeAll() }
            return s.waiting
        }
        for continuation in all { continuation.resume() }
    }
}

/// Counts the items a pipeline opens. Items whose id starts "pattern-slow" block in the open, on the decode thread,
/// until the test releases them, so a test can act between a start's activation and its negotiation.
private final class OpenLog: Sendable {
    private let opened = Atomic<Int>(0)
    private let released = Atomic<Bool>(false)

    var count: Int { opened.load(ordering: .acquiring) }

    func open(_ item: PlaybackItem) throws -> PCMDecoding {
        opened.add(1, ordering: .releasing)
        if item.id.hasPrefix("pattern-slow") {
            while !released.load(ordering: .acquiring) { usleep(200) }
        }
        return try decoderForItem(item)
    }

    func release() {
        released.store(true, ordering: .releasing)
    }
}

/// A call queued on a `PlayerEngine` that waits until the test releases it. Calls queued after it wait too.
@MainActor
private final class CallHold {
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

// MARK: - Helpers

private func fixtureItem(_ name: String, id: String? = nil, title: String = "Fixture Title") -> QueueItem {
    let f = Fixtures.named(name)
    return QueueItem(
        id: id ?? name, url: Fixtures.url(f), title: title, artist: "Fixture Artist", album: "Fixtures",
        format: AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels),
        totalFrames: f.frames)
}

private func patternItem(_ name: String) -> QueueItem {
    QueueItem(
        id: "pattern-\(name)", url: URL(fileURLWithPath: "/dev/null"), title: "Pattern \(name)", artist: "",
        album: "", format: PatternDecoder.sourceFormat, totalFrames: PatternDecoder.frames)
}

/// Ids starting "pattern" decode synthetically and ids starting "broken" fail to open. Anything else is a fixture file.
private let decoderForItem: @Sendable (PlaybackItem) throws -> PCMDecoding = { item in
    if item.id.hasPrefix("pattern") { return PatternDecoder() }
    if item.id.hasPrefix("broken") { throw FlacDecodeError.ioError }
    return try FlacDecoder(url: item.url)
}

/// Native-range samples as the Float32 client receives them: v / 2^(b−1).
private func floats(_ samples: some Sequence<Int32>, bits: Int) -> [Float] {
    let scale = Float(1 << (bits - 1))
    return samples.map { Float($0) / scale }
}

/// nil when the arrays are identical; otherwise where they first differ. Floats compare by bit pattern.
private func mismatch(_ got: [Float], _ want: [Float]) -> String? {
    guard got.count == want.count else { return "count \(got.count) ≠ \(want.count)" }
    guard let i = got.indices.first(where: { got[$0].bitPattern != want[$0].bitPattern }) else { return nil }
    return "first difference at sample \(i): \(got[i]) ≠ \(want[i])"
}

/// The strip knows nothing about a path: no source, plan or hardware side.
private func assertNoPath(_ signal: SignalState, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(signal.source == nil, sourceLocation: sourceLocation)
    #expect(signal.plan == nil, sourceLocation: sourceLocation)
    #expect(signal.hardwareRate == nil, sourceLocation: sourceLocation)
    #expect(signal.hardwareChannels == nil, sourceLocation: sourceLocation)
    #expect(signal.indicator == .idle, sourceLocation: sourceLocation)
}

/// Waits, without pulling, until `condition` holds or `timeout` passes, and returns whether it held. Each check
/// sleeps first, which hands the main actor to the player's event tasks.
@MainActor
private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// The player's output factory in tests. It keeps every output it built, newest last. Given a fixed output it returns
/// that one on every build, so a test can script it beforehand; otherwise each build is a fresh `FakeOutput`.
@MainActor
private final class OutputFactory {
    let fixed: FakeOutput?
    private(set) var built: [FakeOutput] = []
    /// While set, every build throws it, as `RemoteIOOutput()` throws when no unit can be created.
    var failure: (any Error)?

    init(fixed: FakeOutput? = nil) {
        self.fixed = fixed
    }

    func make() throws -> AudioOutput {
        if let failure { throw failure }
        let output = fixed ?? FakeOutput()
        built.append(output)
        return output
    }
}

/// A player wired to `FakeSession`, `FakeOutput` and `FakeNowPlaying`. The test plays the render thread by pulling.
@MainActor
private final class Rig {
    let session: FakeSession
    let outputs: OutputFactory
    let nowPlaying = FakeNowPlaying()
    let player: Player
    /// Real frames pulled so far, across every pipeline the player started (the FakeOutput captures exactly these).
    private(set) var pulledFrames = 0
    private var barriers = 0
    /// Stands in for `output` before the factory has built anything.
    private let unbuilt = FakeOutput()

    /// `output` is the one output the player gets, on every build; `outputs`, when given, builds them instead.
    init(
        session: FakeSession = FakeSession(), output: FakeOutput = FakeOutput(), outputs: OutputFactory? = nil,
        makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding = decoderForItem
    ) {
        self.session = session
        let outputs = outputs ?? OutputFactory(fixed: output)
        self.outputs = outputs
        player = Player(
            session: session, makeOutput: { try outputs.make() },
            capabilities: OutputCapabilities(int32Passthrough: false), nowPlaying: nowPlaying,
            makeDecoder: makeDecoder)
    }

    /// The output the player renders through now: the one built last.
    var output: FakeOutput {
        outputs.built.last ?? outputs.fixed ?? unbuilt
    }

    @discardableResult
    func pull(frames: Int = 512) -> Int {
        let n = output.pull(frames: frames)
        pulledFrames += n
        return n
    }

    /// Pulls until exactly `target` real frames have been pulled in all, letting the player run between pulls.
    func pull(upTo target: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while pulledFrames < target {
            guard clock.now < deadline else { return false }
            if pull(frames: min(512, target - pulledFrames)) == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
        return true
    }

    /// Pulls until `done()` holds, letting the player run between pulls.
    func pump(timeout: Duration = .seconds(10), until done: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !done() {
            guard clock.now < deadline else { return false }
            if pull() == 0 {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
        return true
    }

    /// Like `pull(upTo:)` but without ever suspending, so the main actor stays with the test throughout and the player
    /// sees none of what the pipeline emits meanwhile.
    func pullHoldingMainActor(upTo target: Int, timeout: Duration = .seconds(10)) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while pulledFrames < target {
            guard clock.now < deadline else { return false }
            if pull(frames: min(512, target - pulledFrames)) == 0 { usleep(200) }
        }
        return true
    }

    /// Pulls (which answers a seek's flush) without suspending until `condition` holds.
    func pullHoldingMainActor(until condition: () -> Bool, timeout: Duration = .seconds(10)) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { return false }
            pull()
            usleep(200)
        }
        return true
    }

    /// Session events are handled in order, so once a volume change sent now has landed, every event sent before it
    /// has been handled too. The fake's volume moves first, as a real session's does before its notification.
    func barrier() async -> Bool {
        barriers += 1
        let marker = Float(barriers) / 1000
        session.outputVolume = marker
        session.emit(.volumeChanged(marker))
        return await eventually { player.signal.systemVolume == marker }
    }
}

// MARK: - Tests

// Serialized: every test runs decode threads and a pull loop, and waits on wall-clock deadlines.
@MainActor @Suite(.serialized) struct PlayerTests {
    @Test func playsQueueAndEnds() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s16-44100", id: "a"), fixtureItem("s24-48000", id: "b")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.indicator == .pure)
        #expect(await rig.pump { rig.player.status == .ended }, "status: \(rig.player.status)")
        #expect(rig.pulledFrames == 8192)
        #expect(rig.player.currentIndex == 1)
        #expect(rig.session.requestedRates == [44_100, 48_000])
        #expect(rig.session.activationCount == 1)
        #expect(rig.nowPlaying.shown.last?.playing == false)
        #expect(!rig.output.isStarted)
    }

    @Test func pausesWhenOutputUnplugged() async {
        let session = FakeSession()
        session.currentPort = .wired("EarPods")
        let rig = Rig(session: session)
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 4410))
        rig.session.emit(.routeChanged(.oldDeviceUnavailable, .builtIn))
        #expect(await eventually { rig.player.status == .paused })
        #expect(rig.player.signal.port == .builtIn)
        #expect(rig.player.position == .milliseconds(100))
        #expect(!rig.output.isStarted)
        #expect(rig.session.requestedRates == [44_100])
    }

    @Test func resumesAfterInterruptionOnlyWhenAllowed() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })

        rig.session.emit(.interruptionBegan)
        #expect(await eventually { rig.player.status == .paused })
        rig.session.emit(.interruptionEnded(shouldResume: true))
        #expect(await eventually { rig.player.status == .playing })

        rig.session.emit(.interruptionBegan)
        #expect(await eventually { rig.player.status == .paused })
        rig.session.emit(.interruptionEnded(shouldResume: false))
        #expect(await rig.barrier())
        #expect(rig.player.status == .paused)

        // A user pause during the interruption wins over the system's suggestion to resume.
        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        rig.session.emit(.interruptionBegan)
        #expect(await eventually { rig.player.status == .paused })
        rig.player.pause()
        rig.session.emit(.interruptionEnded(shouldResume: true))
        #expect(await rig.barrier())
        #expect(rig.player.status == .paused)
    }

    @Test func previousRestartsAfterThreeSeconds() async {
        let rig = Rig()
        await rig.player.play([patternItem("a"), patternItem("b")], startingAt: 1)
        #expect(await eventually { rig.player.status == .playing })
        await rig.player.seek(to: .seconds(4))
        #expect(rig.player.position == .seconds(4))
        #expect(await rig.pull(upTo: 4410))
        #expect(await eventually { rig.player.position == .milliseconds(4100) })
        let afterSeek = floats(PatternDecoder.samples(from: 176_400, count: 4410), bits: 16)
        #expect(mismatch(rig.output.capturedFloat, afterSeek) == nil)

        await rig.player.previous()
        #expect(rig.player.currentIndex == 1)
        #expect(rig.player.position == .zero)
        #expect(await rig.pull(upTo: 4410 + 512))
        let restarted = Array(rig.output.capturedFloat[(4410 * 2)...])
        #expect(mismatch(restarted, floats(PatternDecoder.samples(from: 0, count: 512), bits: 16)) == nil)

        // Within the restart window, previous goes back a track instead.
        await rig.player.previous()
        #expect(await eventually { rig.player.currentIndex == 0 && rig.player.status == .playing })
    }

    @Test func signalFollowsRoute() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s24-48000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.indicator == .pure)
        rig.session.emit(.routeChanged(.newDeviceAvailable, .bluetooth("AirPods")))
        #expect(await eventually { rig.player.signal.port == .bluetooth("AirPods") })
        #expect(rig.player.signal.indicator == .bluetoothLossy)
    }

    @Test func usbVolumeWarning() async {
        let session = FakeSession()
        session.currentPort = .usb("DAC")
        session.outputVolume = 0.8
        let rig = Rig(session: session)
        #expect(rig.player.signal.port == .usb("DAC"))
        #expect(rig.player.signal.volumeWarningPercent == 80)
        rig.session.emit(.volumeChanged(0.5))
        #expect(await eventually { rig.player.signal.volumeWarningPercent == 50 })
        rig.session.emit(.volumeChanged(1.0))
        #expect(await eventually { rig.player.signal.systemVolume == 1.0 })
        #expect(rig.player.signal.volumeWarningPercent == nil)
    }

    @Test func nowPlayingShowsCurrentTrack() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s24-48000", title: "Fixture Title")], startingAt: 0)
        #expect(await eventually { rig.nowPlaying.shown.contains { $0.playing } })
        #expect(rig.nowPlaying.shown.last == .init(title: "Fixture Title", elapsed: .zero, playing: true))
        rig.player.pause()
        #expect(rig.nowPlaying.shown.last == .init(title: "Fixture Title", elapsed: .zero, playing: false))
    }

    @Test func remoteCommandsDrivePlayer() async {
        let rig = Rig()
        await rig.player.play([patternItem("a"), patternItem("b")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.nowPlaying.onCommand != nil)

        rig.nowPlaying.onCommand?(.pause)
        #expect(rig.player.status == .paused)
        rig.nowPlaying.onCommand?(.next)
        #expect(await eventually { rig.player.currentIndex == 1 })
        #expect(rig.player.status == .paused)
        rig.nowPlaying.onCommand?(.play)
        #expect(await eventually { rig.player.status == .playing && rig.player.currentIndex == 1 })
        rig.nowPlaying.onCommand?(.toggle)
        #expect(rig.player.status == .paused)
        rig.nowPlaying.onCommand?(.seek(.seconds(1)))
        #expect(await eventually { rig.player.position == .seconds(1) })
        rig.nowPlaying.onCommand?(.previous)
        #expect(await eventually { rig.player.currentIndex == 0 })
    }

    /// Ruling 11(a): a route change to another port while playing re-negotiates the rate and continues from the same
    /// frame. The reason is `.other` and the hardware rate is unchanged, so only the port change can cause the restart.
    @Test func routeChangeWhilePlayingRenegotiatesAndKeepsPosition() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 22_050))
        #expect(await eventually { rig.player.position == .milliseconds(500) })
        #expect(rig.session.requestedRates == [44_100])
        #expect(rig.session.sampleRate == 44_100)

        rig.session.emit(.routeChanged(.other, .usb("DAC")))
        #expect(await eventually { rig.session.requestedRates.count == 2 && rig.player.status == .playing })
        #expect(rig.session.requestedRates == [44_100, 44_100])
        #expect(rig.player.position == .milliseconds(500))
        #expect(rig.player.signal.port == .usb("DAC"))
        #expect(rig.output.plans.count == 2)

        #expect(await rig.pull(upTo: 22_050 + 1024))
        let continued = Array(rig.output.capturedFloat[(22_050 * 2)...])
        #expect(mismatch(continued, floats(PatternDecoder.samples(from: 22_050, count: 1024), bits: 16)) == nil)
    }

    /// Ruling 11(b): a `queueEnded` the old pipeline emitted before `play` of a new queue, but which the player had
    /// not read yet, must not end the new queue.
    @Test func staleQueueEndedDoesNotEndNewQueue() async throws {
        let seeks = SeekCounter()
        let rig = Rig(makeDecoder: { item in
            let decoder = try decoderForItem(item)
            return item.id == "old" ? ObservedDecoder(decoder, seeks: seeks) : decoder
        })
        await rig.player.play([fixtureItem("s16-44100", id: "old")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 2048))
        let old = try #require(rig.player.pipeline)

        // From here until `play` below the test never suspends, so the player cannot read the old pipeline's events.
        // Render the old track to its end: its `trackEnded` and `queueEnded` are now due.
        #expect(rig.pullHoldingMainActor(upTo: 4096))
        // Ask the old pipeline to seek, from off the main actor. Its decode thread emits whatever is due before it
        // repositions the decoder, so once the decoder has seeked, `queueEnded` is waiting, unread, in the old stream.
        Task.detached { await old.seek(toFrame: 0) }
        #expect(rig.pullHoldingMainActor(until: { seeks.count > 0 }))

        await rig.player.play([fixtureItem("s24-48000", id: "new")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing && rig.player.queue.map(\.id) == ["new"] })
        let before = rig.pulledFrames
        #expect(await rig.pump { rig.player.status != .playing })
        #expect(rig.player.status == .ended)
        #expect(rig.pulledFrames - before == 4096, "the new queue ended before it was played through")
    }

    /// A stopped pipeline touches its output once more, when it is deallocated (`PlaybackPipeline.deinit` stops the
    /// output). That can happen after the next pipeline has started, and must not silence it.
    @Test func retiredPipelineCannotSilenceItsSuccessor() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        var old = rig.player.pipeline
        await rig.player.play([patternItem("b")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(old != nil && old !== rig.player.pipeline)
        old = nil
        #expect(rig.output.isStarted)
        #expect(await rig.pull(upTo: 4096))
    }

    /// Ruling 11(c): a seek while paused moves the remembered position and nothing else.
    @Test func seekWhilePausedUpdatesPositionWithoutStarting() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 4410))
        rig.player.pause()
        #expect(rig.player.position == .milliseconds(100))

        await rig.player.seek(to: .seconds(2))
        #expect(rig.player.status == .paused)
        #expect(rig.player.position == .seconds(2))
        #expect(!rig.output.isStarted)
        #expect(rig.session.requestedRates == [44_100])
        #expect(rig.nowPlaying.shown.last == .init(title: "Pattern a", elapsed: .seconds(2), playing: false))

        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 4410 + 1024))
        let resumed = Array(rig.output.capturedFloat[(4410 * 2)...])
        #expect(mismatch(resumed, floats(PatternDecoder.samples(from: 88_200, count: 1024), bits: 16)) == nil)
    }

    /// Ruling 11(d): pause stops the pipeline and resume starts a new one at the paused frame, with nothing lost or
    /// repeated.
    @Test func resumeContinuesFromPausedFrameBitExact() async {
        let f = Fixtures.named("s24-48000")
        let rig = Rig()
        await rig.player.play([fixtureItem("s24-48000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 1500))
        rig.player.pause()
        #expect(rig.player.position == .microseconds(31_250))
        #expect(!rig.output.isStarted)

        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pump { rig.player.status == .ended })
        #expect(mismatch(rig.output.capturedFloat, floats(Fixtures.rawSamples(f), bits: 24)) == nil)
        #expect(rig.session.requestedRates == [48_000, 48_000])
        #expect(rig.output.plans.count == 2)
    }

    /// Ruling R17: the strip says "Resampled" when the hardware runs at another rate than the unit's client.
    @Test func signalShowsResamplingAfterTheUnit() async {
        let output = FakeOutput()
        output.hardwareSideSampleRate = 48_000
        let rig = Rig(output: output)
        await rig.player.play([fixtureItem("s16-44100")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.plan?.clientSampleRate == 44_100)
        #expect(rig.player.signal.hardwareRate == 48_000)
        #expect(rig.player.signal.indicator == .resampled(RateChange(from: 44_100, to: 48_000)))
        #expect(SignalStrip.text(rig.player.signal) == "FLAC · 16-bit · 48 kHz · ● Resampled 44.1→48")
    }

    /// Ruling 8: a failed item is skipped; only a queue where nothing could play fails.
    @Test func itemFailureSkipsAndFailsOnlyWhenNothingPlays() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s16-44100", id: "broken-1"), fixtureItem("s24-48000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.currentIndex == 1)

        await rig.player.play([fixtureItem("s16-44100", id: "broken-2")], startingAt: 0)
        #expect(
            await eventually {
                if case .failed = rig.player.status { return true }
                return false
            })
        #expect(rig.player.currentIndex == nil)
        #expect(rig.nowPlaying.clearCount == 1)
    }

    /// Fix round 1, item 1: a same-port route change (a category or configuration change) leaves playback alone while
    /// the hardware still runs at the negotiated rate. The session's own activation and negotiation post such changes,
    /// so restarting on them would loop.
    @Test func sameRouteAtTheSameRateDoesNotRestart() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        let pipeline = rig.player.pipeline
        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await rig.barrier())
        #expect(rig.session.requestedRates == [44_100])
        #expect(rig.player.pipeline === pipeline)
        #expect(rig.player.status == .playing)
    }

    /// Fix round 1, item 1: the hardware rate moves under an unchanged port mid-track. The player restarts at the
    /// same frame so the client rate matches the hardware again, and the restart's own negotiation leaves nothing to
    /// react to, so a further notification is a no-op.
    @Test func sameRouteRateChangeRestartsAtThePosition() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 22_050))
        #expect(await eventually { rig.player.position == .milliseconds(500) })

        rig.session.sampleRate = 48_000
        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await eventually { rig.session.requestedRates.count == 2 && rig.player.status == .playing })
        #expect(rig.session.requestedRates == [44_100, 44_100])
        #expect(rig.session.sampleRate == 44_100)
        #expect(rig.player.position == .milliseconds(500))
        #expect(rig.player.signal.indicator == .pure)

        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await rig.barrier())
        #expect(rig.session.requestedRates.count == 2)

        #expect(await rig.pull(upTo: 22_050 + 1024))
        let continued = Array(rig.output.capturedFloat[(22_050 * 2)...])
        #expect(mismatch(continued, floats(PatternDecoder.samples(from: 22_050, count: 1024), bits: 16)) == nil)
    }

    /// Fix round 1, item 1: while paused, a same-port rate change only refreshes the strip; resume re-negotiates.
    @Test func sameRouteRateChangeWhilePausedUpdatesTheSignal() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        rig.player.pause()

        rig.session.sampleRate = 48_000
        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await rig.barrier())
        #expect(rig.player.status == .paused)
        #expect(rig.session.requestedRates == [44_100])
        #expect(rig.player.signal.hardwareRate == 48_000)
        #expect(rig.player.signal.indicator == .resampled(RateChange(from: 44_100, to: 48_000)))

        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.session.requestedRates == [44_100, 44_100])
        #expect(rig.player.signal.hardwareRate == 44_100)
        #expect(rig.player.signal.indicator == .pure)
    }

    /// Fix round 1, item 2: headphones pulled during a call. When the call ends with "should resume", the music must
    /// not come back on through the speaker.
    @Test func unplugDuringInterruptionDoesNotResume() async {
        let session = FakeSession()
        session.currentPort = .wired("EarPods")
        let rig = Rig(session: session)
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        rig.session.emit(.interruptionBegan)
        #expect(await eventually { rig.player.status == .paused })
        rig.session.currentPort = .builtIn
        rig.session.emit(.routeChanged(.oldDeviceUnavailable, .builtIn))
        rig.session.emit(.interruptionEnded(shouldResume: true))
        #expect(await rig.barrier())
        #expect(rig.player.status == .paused)
        #expect(rig.player.signal.port == .builtIn)
    }

    /// Fix round 1, item 3: a pause that lands after `seek(to:)` has moved the cue, but before the pipeline has the
    /// seek, keeps the seek target rather than the frame the pipeline still reports.
    @Test func pauseWhileSeekIsInFlightKeepsTheSeek() async throws {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 4410))
        let engine = try #require(rig.player.currentEngine)

        // Park a call on the engine's queue, so the seek's call into the pipeline waits behind it: the seek is in
        // flight, deterministically, when the pause lands.
        let hold = CallHold()
        _ = engine.enqueue { _ in await hold.wait() }
        let seeking = Task { await rig.player.seek(to: .seconds(2)) }
        #expect(await eventually { rig.player.position == .seconds(2) })
        #expect(engine.pipeline.position.frame == 4410)
        rig.player.pause()
        hold.release()
        await seeking.value
        #expect(rig.player.status == .paused)
        #expect(rig.player.position == .seconds(2))

        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 4410 + 1024))
        let resumed = Array(rig.output.capturedFloat[(4410 * 2)...])
        #expect(mismatch(resumed, floats(PatternDecoder.samples(from: 88_200, count: 1024), bits: 16)) == nil)
    }

    /// Ruling 5: a media-server reset stops playback, pauses at the current point and re-activates the session.
    @Test func mediaServicesResetPausesAndReactivates() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 4410))
        #expect(rig.session.activationCount == 1)

        rig.session.emit(.mediaServicesReset)
        #expect(await eventually { rig.player.status == .paused })
        #expect(rig.player.position == .milliseconds(100))
        #expect(!rig.output.isStarted)
        #expect(await eventually { rig.session.activationCount == 2 })

        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(await rig.pull(upTo: 4410 + 512))
        let resumed = Array(rig.output.capturedFloat[(4410 * 2)...])
        #expect(mismatch(resumed, floats(PatternDecoder.samples(from: 4410, count: 512), bits: 16)) == nil)
    }

    /// I4: a media-services reset kills the RemoteIO unit with the server. The next start builds a fresh output through
    /// the factory; the old one is stopped at the reset, dropped, and never called again.
    @Test func mediaServicesResetRebuildsTheOutput() async throws {
        let outputs = OutputFactory()
        let rig = Rig(outputs: outputs)
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(outputs.built.count == 1)
        let old = try #require(outputs.built.first)
        #expect(await rig.pull(upTo: 4410))

        rig.session.emit(.mediaServicesReset)
        #expect(await eventually { rig.player.status == .paused })
        #expect(await eventually { rig.session.activationCount == 2 })
        #expect(!old.isStarted && !old.hasSource, "the old output was not stopped")
        let callsAtReset = old.outputCalls

        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(outputs.built.count == 2 && outputs.built.last !== old)
        #expect(await rig.pull(upTo: 4410 + 512))
        #expect(old.outputCalls == callsAtReset, "the dropped output was called again")
        #expect(old.capturedFloat.count == 4410 * 2)
        let resumed = rig.output.capturedFloat
        #expect(mismatch(resumed, floats(PatternDecoder.samples(from: 4410, count: 512), bits: 16)) == nil)
    }

    /// When the factory cannot build an output, the start fails with the reason, at the first play and after a reset.
    @Test func outputFactoryFailureFailsTheStart() async {
        let outputs = OutputFactory()
        outputs.failure = AudioOutputError.unitUnavailable(-1)
        let rig = Rig(outputs: outputs)
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(rig.player.status == .failed("Audio output unavailable: unitUnavailable(-1)"))
        assertNoPath(rig.player.signal)
        #expect(rig.session.activationCount == 0)

        outputs.failure = nil
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        rig.session.emit(.mediaServicesReset)
        #expect(await eventually { rig.player.status == .paused })
        outputs.failure = AudioOutputError.unitUnavailable(-2)
        rig.player.resume()
        #expect(rig.player.status == .failed("Audio output unavailable: unitUnavailable(-2)"))
        #expect(outputs.built.count == 1)
    }

    /// Ruling 10: Now Playing is published on changes, never by the 10 Hz position ticker.
    @Test func nowPlayingIsNotRepublishedWhilePlaying() async {
        let rig = Rig()
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        let published = rig.nowPlaying.shown.count
        // About a second of audio, waiting each tenth of a second for the ticker to show it.
        for tenth in 1...10 {
            #expect(await rig.pull(upTo: tenth * 4410))
            #expect(await eventually { rig.player.position == .milliseconds(100 * tenth) })
        }
        #expect(rig.nowPlaying.shown.count == published)
    }

    /// Ruling 2: after the queue ended, seek, previous and resume each play again on a fresh pipeline, which reports
    /// a fresh `trackStarted` (status only turns `.playing` on one).
    @Test func restartsAfterTheQueueEnded() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s24-48000", id: "a"), fixtureItem("s24-48000", id: "b")], startingAt: 0)
        #expect(await rig.pump { rig.player.status == .ended })
        #expect(rig.player.currentIndex == 1)
        var negotiations = rig.session.requestedRates.count

        await rig.player.seek(to: .milliseconds(40))
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.currentIndex == 1)
        #expect(rig.session.requestedRates.count == negotiations + 1)
        var before = rig.pulledFrames
        #expect(await rig.pump { rig.player.status == .ended })
        #expect(rig.pulledFrames - before == 4096 - 1920)
        negotiations = rig.session.requestedRates.count

        // At the start of the cued last track, previous goes back a track.
        await rig.player.previous()
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.currentIndex == 0)
        #expect(rig.session.requestedRates.count == negotiations + 1)
        before = rig.pulledFrames
        #expect(await rig.pump { rig.player.status == .ended })
        #expect(rig.pulledFrames - before == 8192)
        negotiations = rig.session.requestedRates.count

        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.currentIndex == 1)
        #expect(rig.session.requestedRates.count == negotiations + 1)
        before = rig.pulledFrames
        #expect(await rig.pump { rig.player.status == .ended })
        #expect(rig.pulledFrames - before == 4096)
    }

    // MARK: The strip outlives nothing it describes (final review C1, I3)

    /// A failure clears what the strip shows about the path: the old track's plan must not describe nothing.
    @Test func failureClearsTheSignalPath() async {
        let output = FakeOutput()
        output.hardwareSideChannels = 2
        let rig = Rig(output: output)
        await rig.player.play([fixtureItem("s24-48000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.indicator == .pure && rig.player.signal.hardwareChannels == 2)

        await rig.player.play([fixtureItem("s16-44100", id: "broken")], startingAt: 0)
        #expect(await eventually { rig.player.status == .failed("ioError") })
        assertNoPath(rig.player.signal)
        #expect(SignalStrip.text(rig.player.signal) == "No record")
        #expect(rig.player.signal.port == .builtIn)
    }

    /// `play([])` leaves the player idle, with nothing on the strip.
    @Test func emptyPlayClearsTheSignalPath() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s24-48000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        await rig.player.play([], startingAt: 0)
        #expect(rig.player.status == .idle)
        assertNoPath(rig.player.signal)
        #expect(SignalStrip.text(rig.player.signal) == "No record")
    }

    /// C1 through the player: a multichannel file never plays, and a queue of nothing else fails with the policy's
    /// message.
    @Test func multichannelQueueFails() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s16-48000-6ch")], startingAt: 0)
        #expect(await eventually { rig.player.status == .failed("Multichannel FLAC isn't supported yet") })
        assertNoPath(rig.player.signal)
        #expect(rig.output.plans.isEmpty)

        await rig.player.play([fixtureItem("s16-48000-6ch"), fixtureItem("s24-48000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.currentIndex == 1)
        #expect(rig.player.signal.source?.channels == 2)
    }

    /// A paused track change cues the new track: the strip shows it as starting, not with the old track's plan.
    @Test func pausedTrackChangeShowsThePendingTrack() async {
        let rig = Rig()
        await rig.player.play([patternItem("a"), fixtureItem("s24-96000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.indicator == .pure)
        rig.player.pause()
        await rig.player.next()
        #expect(rig.player.status == .paused && rig.player.currentIndex == 1)
        #expect(rig.player.signal.source == AudioFormat(sampleRate: 96_000, bitsPerSample: 24, channels: 2))
        #expect(rig.player.signal.plan == nil && rig.player.signal.hardwareRate == nil)
        #expect(rig.player.signal.indicator == .pending)
        #expect(SignalStrip.text(rig.player.signal) == "FLAC · 24-bit · 96 kHz · ● Starting…")

        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.plan?.clientSampleRate == 96_000)
        #expect(rig.player.signal.indicator == .pure)
    }

    /// "Pure" must be earned by each start: until the new pipeline's plan arrives with its track, the strip reads
    /// "Starting…", never the previous track's state.
    @Test func startShowsPendingUntilTheTrackStarts() async {
        let session = SuspendingSession()
        let output = FakeOutput()
        output.hardwareSideSampleRate = 48_000
        let player = Player(
            session: session, makeOutput: { output }, capabilities: OutputCapabilities(int32Passthrough: false),
            nowPlaying: FakeNowPlaying(), makeDecoder: decoderForItem)
        await player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { session.entered == [44_100] })
        #expect(player.status == .preparing && player.signal.indicator == .pending)
        session.releaseAll()
        #expect(await eventually { player.status == .playing })
        #expect(player.signal.indicator == .resampled(RateChange(from: 44_100, to: 48_000)))

        // A new start forgets the old plan at once; it is not left describing the new track.
        await player.play([patternItem("b")], startingAt: 0)
        #expect(await eventually { session.entered == [44_100, 44_100] })
        #expect(player.status == .preparing)
        #expect(player.signal.source == PatternDecoder.sourceFormat)
        #expect(player.signal.plan == nil && player.signal.hardwareRate == nil)
        #expect(player.signal.indicator == .pending)
        #expect(SignalStrip.text(player.signal) == "FLAC · 16-bit · 44.1 kHz · ● Starting…")
        session.releaseAll()
        #expect(await eventually { player.status == .playing })
    }

    /// Stereo into a hardware side with one channel: the system downmixes, and the strip says so.
    @Test func signalShowsADownmix() async {
        let output = FakeOutput()
        output.hardwareSideChannels = 1
        let rig = Rig(output: output)
        await rig.player.play([fixtureItem("s24-48000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.hardwareChannels == 1)
        #expect(rig.player.signal.indicator == .downmixed(from: 2, to: 1))
        #expect(SignalStrip.text(rig.player.signal) == "FLAC · 24-bit · 48 kHz · ● Downmixed 2→1")
    }

    /// The decoder's format, which `trackStarted` carries, is authoritative over the one recorded at import (a file
    /// replaced since): the strip shows what plays, and positions convert at the rate that plays.
    @Test func decodedFormatIsAuthoritative() async {
        let stale = QueueItem(
            id: "pattern-stale", url: URL(fileURLWithPath: "/dev/null"), title: "Stale", artist: "", album: "",
            format: AudioFormat(sampleRate: 48_000, bitsPerSample: 24, channels: 2), totalFrames: PatternDecoder.frames)
        let rig = Rig()
        await rig.player.play([stale], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.source == PatternDecoder.sourceFormat)
        #expect(SignalStrip.text(rig.player.signal) == "FLAC · 16-bit · 44.1 kHz · ● Pure")
        #expect(rig.player.queue[0].format == PatternDecoder.sourceFormat)
        #expect(await rig.pull(upTo: 4410))
        // 4410 frames are 100 ms at 44.1 kHz; at the stale 48 kHz they would read as 91.875 ms.
        #expect(await eventually { rig.player.position == .milliseconds(100) })
        await rig.player.seek(to: .seconds(1))
        #expect(await rig.pull(upTo: 4410 + 512))
        let afterSeek = Array(rig.output.capturedFloat[(4410 * 2)...])
        #expect(mismatch(afterSeek, floats(PatternDecoder.samples(from: 44_100, count: 512), bits: 16)) == nil)
    }

    /// Ledger M5: the decoder's length is authoritative too. A file replaced since import with a longer or shorter one
    /// shows, and seeks within, the length that plays, not the one recorded at import.
    @Test func decodedLengthIsAuthoritative() async {
        let stale = QueueItem(
            id: "pattern-short", url: URL(fileURLWithPath: "/dev/null"), title: "Stale", artist: "", album: "",
            format: PatternDecoder.sourceFormat, totalFrames: 10)
        let rig = Rig()
        await rig.player.play([stale], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.queue[0].totalFrames == PatternDecoder.frames)
        #expect(rig.player.queue[0].duration == stale.duration(ofFrames: PatternDecoder.frames))
    }

    // MARK: Refreshing the strip while nothing plays (ledger T13)

    /// A notification that leaves the hardware at the negotiated rate must not overwrite the R17 hardware-side rate:
    /// on the simulator that flipped "Resampled 44.1→48" to "Pure" while paused. Once the hardware really moves the
    /// strip follows it, and when it comes back the hardware-side rate is shown again.
    @Test func pausedRefreshKeepsTheHardwareSideRate() async {
        let output = FakeOutput()
        output.hardwareSideSampleRate = 48_000
        let rig = Rig(output: output)
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.indicator == .resampled(RateChange(from: 44_100, to: 48_000)))
        rig.player.pause()

        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await rig.barrier())
        #expect(rig.player.signal.hardwareRate == 48_000)
        #expect(rig.player.signal.indicator == .resampled(RateChange(from: 44_100, to: 48_000)))

        rig.session.sampleRate = 96_000
        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await rig.barrier())
        #expect(rig.player.signal.hardwareRate == 96_000)

        rig.session.sampleRate = 44_100
        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await rig.barrier())
        #expect(rig.player.signal.hardwareRate == 48_000)
        #expect(rig.session.requestedRates == [44_100])
    }

    /// EarPods → DAC while paused: a 96 kHz track planned at 48 kHz, and the hardware now at 96 kHz. The strip must
    /// never read "Resampled 96→96"; pointFlac's own 96→48 is what is shown.
    @Test func pausedRouteSwapNeverShowsAResampleToTheSameRate() async {
        let session = FakeSession(rateResponse: { _ in 48_000 })
        session.currentPort = .wired("EarPods")
        let rig = Rig(session: session)
        await rig.player.play([fixtureItem("s24-96000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.indicator == .resampled(RateChange(from: 96_000, to: 48_000)))
        rig.player.pause()

        session.sampleRate = 96_000
        session.currentPort = .usb("DAC")
        session.emit(.routeChanged(.newDeviceAvailable, .usb("DAC")))
        #expect(await rig.barrier())
        #expect(rig.player.status == .paused)
        #expect(rig.player.signal.hardwareRate == 96_000)
        #expect(rig.player.signal.indicator == .resampled(RateChange(from: 96_000, to: 48_000)))
        // The barrier leaves the volume below full scale, so the USB volume warning follows: not this test's concern.
        #expect(SignalStrip.text(rig.player.signal).hasPrefix("FLAC · 24-bit · 96 kHz · ● Resampled 96→48"))
    }

    /// Unplugging while playing pauses, and takes the same refresh as a route change while paused: the speaker's rate
    /// shows at once.
    @Test func unplugWhilePlayingRefreshesTheRate() async {
        let session = FakeSession()
        session.currentPort = .wired("EarPods")
        let rig = Rig(session: session)
        await rig.player.play([patternItem("a")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.player.signal.indicator == .pure)

        session.sampleRate = 48_000
        session.currentPort = .builtIn
        session.emit(.routeChanged(.oldDeviceUnavailable, .builtIn))
        #expect(await eventually { rig.player.status == .paused })
        #expect(rig.player.signal.hardwareRate == 48_000)
        #expect(rig.player.signal.indicator == .resampled(RateChange(from: 44_100, to: 48_000)))
    }

    /// After the queue ended, the cued last track is refreshed like a paused one.
    @Test func endedQueueRefreshesTheRate() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s16-44100")], startingAt: 0)
        #expect(await rig.pump { rig.player.status == .ended })
        #expect(rig.player.signal.indicator == .pure)

        rig.session.sampleRate = 48_000
        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await rig.barrier())
        #expect(rig.player.status == .ended)
        #expect(rig.player.signal.hardwareRate == 48_000)
        #expect(rig.player.signal.indicator == .resampled(RateChange(from: 44_100, to: 48_000)))
    }

    // MARK: Activation (final review I6, ledger T13)

    /// The first activation sets the first item's rate before activating, so a first play needs no deactivate and
    /// reactivate cycle. An activation after an interruption asks for the cued item's rate.
    @Test func activationAsksForTheCuedItemsRate() async {
        let rig = Rig()
        await rig.player.play([fixtureItem("s24-96000"), patternItem("b")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.session.activationRates == [96_000])
        rig.session.emit(.interruptionBegan)
        #expect(await eventually { rig.player.status == .paused })
        await rig.player.next()
        rig.player.resume()
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.session.activationRates == [96_000, 44_100])
    }

    /// Ledger T13: activation records the rate it leaves the hardware at, as a negotiation does.
    @Test func activationSettlesTheRate() async throws {
        let session = FakeSession(rateResponse: { _ in 96_000 })
        let gate = SessionGate(session: session)
        #expect(gate.settledRate == nil)
        try await gate.activate(preferredRate: 96_000)
        #expect(gate.settledRate == 96_000)
        session.sampleRate = 0
        try await gate.activate(preferredRate: nil)
        // An inactive session's 0 is no rate: the last real one stands.
        #expect(gate.settledRate == 96_000)
    }

    /// Ledger T13: before the fix, the settled rate after an activation was the previous negotiation's, so a same-port
    /// notification arriving between a start's activation and its negotiation (the activation itself posts them)
    /// looked like the hardware moving, and restarted the start for nothing.
    @Test func activationCausedNotificationDoesNotRestart() async {
        let opens = OpenLog()
        let rig = Rig(makeDecoder: { try opens.open($0) })
        await rig.player.play([fixtureItem("s24-48000")], startingAt: 0)
        #expect(await eventually { rig.player.status == .playing })
        rig.session.emit(.interruptionBegan)
        #expect(await eventually { rig.player.status == .paused })

        // Activation at 44.1 kHz; the pipeline then blocks opening the item, before it negotiates.
        await rig.player.play([patternItem("slow")], startingAt: 0)
        #expect(await eventually { rig.session.activationCount == 2 && opens.count == 2 })
        #expect(rig.session.sampleRate == 44_100)
        rig.session.emit(.routeChanged(.other, .builtIn))
        #expect(await rig.barrier())
        #expect(opens.count == 2, "the start was restarted")

        opens.release()
        #expect(await eventually { rig.player.status == .playing })
        #expect(rig.session.requestedRates == [48_000, 44_100])
    }

    /// Ruling 6: one session call at a time, in arrival order; a stopped pipeline's request never reaches the session.
    @Test func negotiationIsSerialized() async throws {
        let session = SuspendingSession()
        let gate = SessionGate(session: session)
        let lease = try OutputArbiter().lease(building: { FakeOutput() })

        #expect(gate.settledRate == nil)
        let first = Task.detached { await gate.requestSampleRate(44_100, for: lease) }
        #expect(await eventually { session.entered == [44_100] })
        let second = Task.detached { await gate.requestSampleRate(48_000, for: lease) }
        #expect(await eventually { gate.waiting == 1 || session.entered.count > 1 })
        let third = Task.detached { await gate.requestSampleRate(96_000, for: lease) }
        #expect(await eventually { gate.waiting == 2 || session.entered.count > 1 })
        #expect(session.entered == [44_100])

        session.releaseOne()
        #expect(await first.value == 44_100)
        // The second request holds the turn now, so the rate is not settled.
        #expect(await eventually { session.entered.count == 2 })
        #expect(gate.settledRate == nil)
        #expect(await eventually { session.entered == [44_100, 48_000] })
        // The third request's pipeline is stopped while it waits: it must not touch the session when its turn comes.
        // (Releasing everything inside, not just the second, makes a broken gate fail here instead of hanging.)
        lease.revoke()
        session.releaseAll()
        #expect(await second.value == 48_000)
        #expect(await third.value == 0)
        #expect(session.entered == [44_100, 48_000])
        #expect(session.mostInside == 1)
        // What the last negotiation that reached the session read back; the refused one records nothing.
        #expect(gate.settledRate == 48_000)
    }
}
