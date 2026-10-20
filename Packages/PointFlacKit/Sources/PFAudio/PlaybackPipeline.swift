import Foundation
import PFCore
import Synchronization

/// One entry of the play queue, as the pipeline sees it.
public struct PlaybackItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var url: URL
    /// The format recorded at import. During playback the decoder's own format is authoritative.
    public var format: AudioFormat
    public var totalFrames: Int64

    public init(id: String, url: URL, format: AudioFormat, totalFrames: Int64) {
        self.id = id
        self.url = url
        self.format = format
        self.totalFrames = totalFrames
    }
}

/// What the pipeline reports, in order. Track events fire once their boundary has been *rendered* (within a few
/// milliseconds), not when it was decoded, which runs up to half a second ahead.
public enum PipelineEvent: Sendable, Equatable {
    /// The output was configured for a new plan: for the first item, and at each boundary where the plan changes.
    case planChanged(OutputPlan)
    case trackStarted(Int)
    case trackEnded(Int)
    /// The item could not be opened, positioned, decoded or output. Playback moves on to the next item, and the failed
    /// item gets no `trackEnded`. Audio decoded before a mid-track failure still plays; the event fires after it.
    case itemFailed(Int, String)
    case queueEnded
}

/// pointFlac's playback engine (spec §5.2): decode thread → format conversion → lock-free ring → real-time render.
///
/// - A dedicated decode thread (`.userInitiated`) reads 4096-frame blocks and converts each per the `OutputPlan`:
///   Int32 client `v << (32 − b)`; Float32 client `v / 2^(b−1)`, TPDF-dithered first when the plan reduces to 24
///   bits; then resampled when the hardware refused the file's rate. The ring holds 0.5 s at the client rate.
/// - A next item with the same plan (at the current hardware rate) and channel count continues into the same ring,
///   sample-exact, and through the same resampler. Otherwise the pipeline lets the ring drain, stops the output,
///   negotiates the next item's rate, configures and starts the output for the new plan, and emits `.planChanged`.
/// - Boundaries are markers keyed by absolute rendered frame. The render callback only counts frames; the decode
///   thread emits each event once `RenderSource.renderedFrames` reaches its marker.
/// - A seek holds the output silent at once, then the decode thread flushes the ring through `RenderSource`'s
///   handshake (never `reset()` while the output runs), seeks the decoder and refills. The newest request wins.
/// - A decoder error emits `.itemFailed` and playback moves to the next item.
///
/// Dropping the pipeline stops playback.
public final class PlaybackPipeline: @unchecked Sendable {
    /// The pipeline's events, for a single consumer. Finishes when the pipeline is deallocated.
    public let events: AsyncStream<PipelineEvent>
    private let core: PipelineCore

    /// - Parameters:
    ///   - negotiateRate: asks the audio session for the item's rate and returns the actual hardware rate it got,
    ///     always > 0; the pipeline then resamples itself if that differs. A value ≤ 0 means no usable rate: that item
    ///     fails with `.itemFailed(index, "Output rate unavailable")`. Called (in a task) before the first item and at
    ///     every plan change; if the pipeline stops meanwhile, the task is cancelled and its answer ignored.
    ///   - makeDecoder: opens an item. Called on the decode thread, which is the only user of the decoder.
    ///   - ditherSeed: seeds the `TPDFDither` that each track (and each seek) starts afresh, so a 32→24-bit capture is
    ///     reproducible against `TPDFDither(seed:)` run over the source from the same frame.
    public init(
        output: AudioOutput, capabilities: OutputCapabilities,
        negotiateRate: @escaping @Sendable (Int) async -> Int,
        makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding,
        ditherSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) {
        let (events, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
        self.events = events
        core = PipelineCore(
            output: output, capabilities: capabilities, negotiateRate: negotiateRate, makeDecoder: makeDecoder,
            ditherSeed: ditherSeed, continuation: continuation)
    }

    deinit {
        core.shutDown()
    }

    /// Replaces the queue and plays `items` from `index`, starting at `fromFrame`. Whatever was playing stops first.
    ///
    /// Returns once the queue is registered. The decode thread then negotiates the rate, configures and starts the
    /// output (`.planChanged`), and fills the ring. A "Play to first frame" signpost interval runs from here to the
    /// first real frame rendered.
    public func start(_ items: [PlaybackItem], at index: Int, fromFrame: Int64) async {
        core.start(items, at: index, fromFrame: fromFrame, firstFrame: FirstFrameInterval(.play))
    }

    /// `start(_:at:fromFrame:)` with the caller's own interval, begun when its request came in (the player's play,
    /// resume or restart, before it activated the session), so the interval covers the whole path to the first frame.
    func start(_ items: [PlaybackItem], at index: Int, fromFrame: Int64, firstFrame: FirstFrameInterval) async {
        core.start(items, at: index, fromFrame: fromFrame, firstFrame: firstFrame)
    }

    /// Seeks within the item being rendered.
    ///
    /// Returns as soon as the request is registered, without waiting for audio: from then on nothing buffered before
    /// the request is rendered, and audio from `frame` follows once the decode thread has flushed the ring and
    /// refilled it, which needs the output to keep pulling. A newer seek supersedes one not yet served. A "Seek to
    /// first frame" signpost interval runs from here to the first real frame at the new position.
    public func seek(toFrame frame: Int64) async {
        core.seek(toFrame: frame, firstFrame: FirstFrameInterval(.seek))
    }

    /// `seek(toFrame:)` with the caller's own interval, begun when its request came in.
    func seek(toFrame frame: Int64, firstFrame: FirstFrameInterval) async {
        core.seek(toFrame: frame, firstFrame: firstFrame)
    }

    /// Stops the output and ends the queue. Does not wait for the decode thread, which may be blocked in file I/O or
    /// in `negotiateRate`; it exits on its own and can no longer touch the output or emit events.
    public func stop() {
        core.stop()
    }

    /// The item being rendered and the source frame reached, derived from rendered frames, not decoded ones (the
    /// decoder runs up to half a second ahead). While a seek is pending this reports its target.
    public var position: (index: Int, frame: Int64) {
        core.position
    }

    /// Decode threads still running, including a stopped session's thread that has not unwound yet. Tests use it to
    /// prove `stop()` ends the session even while `negotiateRate` never answers.
    var liveDecodeThreads: Int {
        core.liveDecodeThreads.load(ordering: .acquiring)
    }
}

// MARK: - Shared state

/// State shared by the facade, the live decode session and readers of `position`.
///
/// Split from `PlaybackPipeline` so that a decode thread never keeps the facade alive: dropping the pipeline stops
/// playback. Lock order: `outputGate`, then `shared`. The render thread takes neither.
final class PipelineCore: @unchecked Sendable {
    struct Shared {
        /// The live session. Any other session's thread is on its way out and may not touch shared state.
        var session: DecodeSession?
        /// The live session's render source, kept after `stop()` so `position` stays put.
        var source: RenderSource?
        var timeline = Timeline()
        /// The newest seek not yet taken by the decode thread.
        var requestedSeek: Int64?
        /// `requestedSeek`'s signpost interval, taken by the decode thread with it.
        var seekInterval: FirstFrameInterval?
    }

    let capabilities: OutputCapabilities
    let negotiateRate: @Sendable (Int) async -> Int
    let makeDecoder: @Sendable (PlaybackItem) throws -> PCMDecoding
    let ditherSeed: UInt64
    let shared = Mutex(Shared())
    /// Decode threads that have not returned yet, including stopped sessions still unwinding. For tests.
    let liveDecodeThreads = Atomic<Int>(0)
    private let continuation: AsyncStream<PipelineEvent>.Continuation
    /// Serialises every call into `output`.
    private let outputGate = NSLock()
    /// Not `Sendable`: touched only while holding `outputGate`.
    private let output: AudioOutput

    init(
        output: AudioOutput, capabilities: OutputCapabilities, negotiateRate: @escaping @Sendable (Int) async -> Int,
        makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding, ditherSeed: UInt64,
        continuation: AsyncStream<PipelineEvent>.Continuation
    ) {
        self.output = output
        self.capabilities = capabilities
        self.negotiateRate = negotiateRate
        self.makeDecoder = makeDecoder
        self.ditherSeed = ditherSeed
        self.continuation = continuation
    }

    func start(_ items: [PlaybackItem], at index: Int, fromFrame: Int64, firstFrame: FirstFrameInterval) {
        let first = max(index, 0)
        let session = DecodeSession(
            core: self, items: items, startIndex: first, startFrame: max(fromFrame, 0), firstFrame: firstFrame)
        let dropped = outputGate.withLock {
            let dropped = shared.withLock { s in
                s.session?.requestStop()
                s.session = session
                s.source = nil
                s.timeline = Timeline(startIndex: first, startFrame: max(fromFrame, 0))
                s.requestedSeek = nil
                return s.seekInterval.take()
            }
            output.stop()
            output.source = nil
            return dropped
        }
        dropped?.end(.abandoned)
        session.launch()
    }

    func seek(toFrame frame: Int64, firstFrame: FirstFrameInterval) {
        // The interval this request supersedes, or this one when there is nothing to seek. Ended outside the lock.
        let abandoned = shared.withLock { s -> FirstFrameInterval? in
            guard let session = s.session else { return firstFrame }
            s.requestedSeek = frame
            let superseded = s.seekInterval
            s.seekInterval = firstFrame
            s.source?.holdForSeek()
            s.timeline.pendingFrame = frame
            session.wake()
            return superseded
        }
        abandoned?.end(.abandoned)
    }

    func stop() {
        let dropped = outputGate.withLock {
            let dropped = shared.withLock { s in
                s.session?.requestStop()
                s.session = nil
                s.requestedSeek = nil
                s.timeline.pendingFrame = nil
                return s.seekInterval.take()
            }
            output.stop()
            output.source = nil
            return dropped
        }
        dropped?.end(.abandoned)
    }

    func shutDown() {
        stop()
        continuation.finish()
    }

    var position: (index: Int, frame: Int64) {
        shared.withLock { s in s.timeline.position(rendered: s.source?.renderedFrames ?? 0) }
    }

    // MARK: For the live session

    /// Runs `body` on the output if `session` is still the live one; nil otherwise.
    func withOutput<T>(for session: DecodeSession, _ body: (AudioOutput) throws -> T) rethrows -> T? {
        try outputGate.withLock {
            guard shared.withLock({ $0.session === session }) else { return nil }
            return try body(output)
        }
    }

    /// Runs `body` on the shared state if `session` is still the live one; nil otherwise.
    func withShared<T: Sendable>(for session: DecodeSession, _ body: (inout Shared) -> T) -> T? {
        shared.withLock { s in s.session === session ? body(&s) : nil }
    }

    func emit(_ events: [PipelineEvent], for session: DecodeSession) {
        _ = withShared(for: session) { _ in
            for event in events { continuation.yield(event) }
        }
    }
}

/// Maps rendered frames back to (item, source frame) for `position`. Each segment is a stretch of one item written
/// contiguously to the ring: a track start, a gapless join, or a seek.
struct Timeline {
    struct Segment {
        var index: Int
        var renderedStart: Int64
        var sourceStart: Int64
        /// Rendered frames scale back to source frames by `from / to` when the segment is resampled.
        var rate: RateChange?
        var totalFrames: Int64
    }

    var startIndex = 0
    var startFrame: Int64 = 0
    /// A seek's target until the decode thread has established it.
    var pendingFrame: Int64?
    /// In rendered order. Only the segment being rendered and those after it are kept.
    private(set) var segments: [Segment] = []

    init(startIndex: Int = 0, startFrame: Int64 = 0) {
        self.startIndex = startIndex
        self.startFrame = startFrame
    }

    func position(rendered: Int64) -> (index: Int, frame: Int64) {
        guard let segment = segments.last(where: { $0.renderedStart <= rendered }) ?? segments.first else {
            return (startIndex, pendingFrame ?? startFrame)
        }
        if let pendingFrame { return (segment.index, pendingFrame) }
        var frame = max(rendered - segment.renderedStart, 0)
        if let rate = segment.rate {
            frame = frame * Int64(rate.from) / Int64(rate.to)
        }
        frame += segment.sourceStart
        if segment.totalFrames > 0 {
            frame = min(frame, segment.totalFrames)
        }
        return (segment.index, frame)
    }

    /// Pulls segment starts predicted past the true end of the stream back to it (see `clampBoundariesToWritten`).
    mutating func clampStarts(to end: Int64) {
        for i in segments.indices where segments[i].renderedStart > end {
            segments[i].renderedStart = end
        }
    }

    /// Adds a segment, dropping those wholly rendered before it.
    mutating func append(_ segment: Segment, rendered: Int64) {
        if let current = segments.lastIndex(where: { $0.renderedStart <= rendered }) {
            segments.removeFirst(current)
        }
        segments.append(segment)
    }

    /// Forgets the segments that start after `rendered` (a seek means they will never play) and returns the item
    /// being rendered, if any.
    mutating func truncate(after rendered: Int64) -> Int? {
        segments.removeAll { $0.renderedStart > rendered }
        return segments.last?.index
    }
}
