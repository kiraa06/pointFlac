import Dispatch
import Foundation
import PFCore
import PFDSP
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
    ///   - negotiateRate: asks the audio session for a hardware rate and returns the rate it got. Called on the decode
    ///     thread's behalf before the first item and at every plan change.
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
    /// output (`.planChanged`), and fills the ring.
    public func start(_ items: [PlaybackItem], at index: Int, fromFrame: Int64) async {
        core.start(items, at: index, fromFrame: fromFrame)
    }

    /// Seeks within the item being rendered.
    ///
    /// Returns as soon as the request is registered, without waiting for audio: from then on nothing buffered before
    /// the request is rendered, and audio from `frame` follows once the decode thread has flushed the ring and
    /// refilled it, which needs the output to keep pulling. A newer seek supersedes one not yet served.
    public func seek(toFrame frame: Int64) async {
        core.seek(toFrame: frame)
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
}

// MARK: - Shared state

/// State shared by the facade, the live decode session and readers of `position`.
///
/// Split from `PlaybackPipeline` so that a decode thread never keeps the facade alive: dropping the pipeline stops
/// playback. Lock order: `outputGate`, then `shared`. The render thread takes neither.
private final class PipelineCore: @unchecked Sendable {
    struct Shared {
        /// The live session. Any other session's thread is on its way out and may not touch shared state.
        var session: DecodeSession?
        /// The live session's render source, kept after `stop()` so `position` stays put.
        var source: RenderSource?
        var timeline = Timeline()
        /// The newest seek not yet taken by the decode thread.
        var requestedSeek: Int64?
    }

    let capabilities: OutputCapabilities
    let negotiateRate: @Sendable (Int) async -> Int
    let makeDecoder: @Sendable (PlaybackItem) throws -> PCMDecoding
    let ditherSeed: UInt64
    let shared = Mutex(Shared())
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

    func start(_ items: [PlaybackItem], at index: Int, fromFrame: Int64) {
        let first = max(index, 0)
        let session = DecodeSession(core: self, items: items, startIndex: first, startFrame: max(fromFrame, 0))
        outputGate.withLock {
            shared.withLock { s in
                s.session?.requestStop()
                s.session = session
                s.source = nil
                s.timeline = Timeline(startIndex: first, startFrame: max(fromFrame, 0))
                s.requestedSeek = nil
            }
            output.stop()
            output.source = nil
        }
        session.launch()
    }

    func seek(toFrame frame: Int64) {
        shared.withLock { s in
            guard let session = s.session else { return }
            s.requestedSeek = frame
            s.source?.holdForSeek()
            s.timeline.pendingFrame = frame
            session.wake()
        }
    }

    func stop() {
        outputGate.withLock {
            shared.withLock { s in
                s.session?.requestStop()
                s.session = nil
                s.requestedSeek = nil
                s.timeline.pendingFrame = nil
            }
            output.stop()
            output.source = nil
        }
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
private struct Timeline {
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

/// Hands `negotiateRate`'s answer from its task to the decode thread, which blocks for it. Blocking is fine there:
/// the decode thread is a dedicated `Thread`, not a cooperative-pool thread.
private final class NegotiatedRate: Sendable {
    private let rate = Atomic<Int>(0)
    private let done = DispatchSemaphore(value: 0)

    func finish(_ value: Int) {
        rate.store(value, ordering: .releasing)
        done.signal()
    }

    func wait(timeout: DispatchTimeInterval) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }

    var value: Int { rate.load(ordering: .acquiring) }
}

// MARK: - Decode session

/// One queue's decode thread.
///
/// All `var` state is confined to that thread. Other threads reach the session only through `requestStop()`,
/// `wake()`, and the core's locked state (seek requests), hence `@unchecked Sendable`.
private final class DecodeSession: @unchecked Sendable {
    private static let blockFrames = 4096

    private enum Entry {
        case start, next, seek
    }

    private enum Step {
        case enter(index: Int, frame: Int64, entry: Entry)
        case play
        case advance
        case finishQueue
        case ended
        case seek
        case stop
    }

    private enum Reconfiguration {
        case configured
        case interrupted(Step)
        case failed(String)
    }

    private struct Marker {
        var at: Int64
        var event: PipelineEvent
    }

    private let core: PipelineCore
    private let items: [PlaybackItem]
    private let startIndex: Int
    private let startFrame: Int64
    private let stopRequested = Atomic<Bool>(false)
    private let wakeup = DispatchSemaphore(value: 0)

    // Decode-thread state.
    private var decoder: PCMDecoding?
    /// The item `decoder` reads.
    private var index = -1
    private var format: AudioFormat?
    private var plan: OutputPlan?
    private var hardwareRate: Int?
    private var source: RenderSource?
    private var outputRunning = false
    /// The absolute rendered-frame index the next frame written to the ring will have.
    private var written: Int64 = 0
    /// Events waiting for `renderedFrames` to reach their frame, in order.
    private var markers: [Marker] = []
    /// Events for the next boundary (the end or failure of what came before), placed once the boundary is known.
    private var boundaryEvents: [PipelineEvent] = []
    private var dither: TPDFDither
    private var converter: SampleRateConverter?
    /// `written` when `converter` was created, and the source frames fed to it since.
    private var converterBase: Int64 = 0
    private var converterInput: Int64 = 0
    private var samples = UnsafeMutableBufferPointer<Int32>(start: nil, count: 0)
    private var words = UnsafeMutableBufferPointer<UInt32>(start: nil, count: 0)
    private var resampled: [Float] = []

    init(core: PipelineCore, items: [PlaybackItem], startIndex: Int, startFrame: Int64) {
        self.core = core
        self.items = items
        self.startIndex = startIndex
        self.startFrame = startFrame
        dither = TPDFDither(seed: core.ditherSeed)
    }

    deinit {
        samples.deallocate()
        words.deallocate()
    }

    func launch() {
        let thread = Thread { [self] in run() }
        thread.name = "pointFlac.decode"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func requestStop() {
        stopRequested.store(true, ordering: .releasing)
        wakeup.signal()
    }

    func wake() {
        wakeup.signal()
    }

    private func run() {
        var step = Step.enter(index: startIndex, frame: startFrame, entry: .start)
        while true {
            switch step {
            case .enter(let index, let frame, let entry): step = enter(index: index, frame: frame, entry: entry)
            case .play: step = play()
            case .advance: step = .enter(index: index + 1, frame: 0, entry: .next)
            case .finishQueue: step = finishQueue()
            case .ended: step = waitAfterEnd()
            case .seek: step = performSeek()
            case .stop: return
            }
        }
    }

    // MARK: Items and boundaries

    /// Makes item `first` (or the first openable item after it) current at `frame`: joins it gaplessly when its plan
    /// matches, otherwise drains and reconfigures the output first.
    private func enter(index first: Int, frame: Int64, entry: Entry) -> Step {
        guard let (next, target, frame, entry) = open(from: first, frame: frame, entry: entry) else {
            return .finishQueue
        }
        let nextFormat = next.format
        var boundary = written
        if isCompatible(nextFormat) {
            if entry == .next, converter != nil { boundary = converterBoundary }
            placeBoundaryEvents(at: boundary)
        } else {
            if let step = flushConverter() { return step }
            boundary = written
            placeBoundaryEvents(at: boundary)
            if let step = drain() { return step }
            switch reconfigure(for: nextFormat) {
            case .configured: break
            case .interrupted(let step): return step
            case .failed(let message):
                boundaryEvents.append(.itemFailed(target, message))
                return .enter(index: target + 1, frame: 0, entry: .next)
            }
        }
        guard let plan, let source else { return .stop }
        if let rate = plan.resample, converter == nil {
            do {
                converter = try SampleRateConverter(
                    inputRate: rate.from, outputRate: rate.to, channels: nextFormat.channels)
            } catch {
                boundaryEvents.append(.itemFailed(target, "resampler unavailable: \(error)"))
                return .enter(index: target + 1, frame: 0, entry: .next)
            }
            converterBase = written
            converterInput = 0
        }
        if entry != .seek {
            markers.append(Marker(at: boundary, event: .trackStarted(target)))
        }
        decoder = next
        index = target
        format = nextFormat
        dither = TPDFDither(seed: core.ditherSeed)
        reserveBuffers(channels: nextFormat.channels)
        let segment = Timeline.Segment(
            index: target, renderedStart: boundary, sourceStart: frame, rate: plan.resample,
            totalFrames: next.totalFrames)
        let rendered = source.renderedFrames
        _ = core.withShared(for: self) { s in
            s.timeline.append(segment, rendered: rendered)
            if s.requestedSeek == nil { s.timeline.pendingFrame = nil }
        }
        return .play
    }

    /// Opens `first`, or the first item after it that opens, positioned at `frame` (clamped to the item). A seek
    /// within the current item reuses its decoder. Each failure becomes an `.itemFailed` at the coming boundary, and
    /// the next item is tried from its start. Nil when the queue runs out.
    private func open(
        from first: Int, frame: Int64, entry: Entry
    ) -> (decoder: PCMDecoding, index: Int, frame: Int64, entry: Entry)? {
        var target = first
        var frame = frame
        var entry = entry
        while target < items.count {
            do {
                let candidate: PCMDecoding
                if entry == .seek, target == index, let decoder {
                    candidate = decoder
                } else {
                    candidate = try core.makeDecoder(items[target])
                }
                if frame != 0 || entry == .seek {
                    let total = candidate.totalFrames
                    frame = max(0, total > 0 ? min(frame, total) : frame)
                    try candidate.seek(toFrame: frame)
                }
                return (candidate, target, frame, entry)
            } catch {
                boundaryEvents.append(.itemFailed(target, String(describing: error)))
                target += 1
                frame = 0
                entry = .next
            }
        }
        return nil
    }

    /// Whether an item of format `next` can continue into the running output: the same plan at the current hardware
    /// rate, and the same channel count.
    private func isCompatible(_ next: AudioFormat) -> Bool {
        guard outputRunning, let plan, let hardwareRate, let format, format.channels == next.channels else {
            return false
        }
        let capabilities = core.capabilities
        return OutputFormatPolicy.plan(source: next, hardwareRate: hardwareRate, capabilities: capabilities) == plan
    }

    /// Where the current resampled stream crosses into the next item: the converter's output frame for the input fed
    /// so far, rather than what it has emitted yet (its filter holds a little back).
    private var converterBoundary: Int64 {
        guard let rate = plan?.resample else { return written }
        return converterBase + Int64((Double(converterInput) * Double(rate.to) / Double(rate.from)).rounded())
    }

    private func placeBoundaryEvents(at frame: Int64) {
        markers += boundaryEvents.map { Marker(at: frame, event: $0) }
        boundaryEvents.removeAll()
    }

    private func finishQueue() -> Step {
        if let step = flushConverter() { return step }
        placeBoundaryEvents(at: written)
        markers.append(Marker(at: written, event: .queueEnded))
        _ = core.withShared(for: self) { s in
            if s.requestedSeek == nil { s.timeline.pendingFrame = nil }
        }
        return .ended
    }

    /// After the queue: emits the remaining events as they are rendered, then sleeps until a seek or stop.
    private func waitAfterEnd() -> Step {
        while true {
            if let step = interruption() { return step }
            emitDueMarkers()
            if markers.isEmpty {
                wakeup.wait()
            } else {
                pause(forFrames: markers[0].at - (source?.renderedFrames ?? 0))
            }
        }
    }

    // MARK: Output

    /// Waits until everything written has been rendered.
    private func drain() -> Step? {
        guard outputRunning, let source else { return nil }
        while source.renderedFrames < written {
            if let step = interruption() { return step }
            emitDueMarkers()
            pause(forFrames: written - source.renderedFrames)
        }
        emitDueMarkers()
        return nil
    }

    /// Stop, negotiate, re-plan, configure, start, `.planChanged`. The ring must be drained. The new source starts
    /// counting at `written` (all of it rendered), so markers stay valid.
    private func reconfigure(for next: AudioFormat) -> Reconfiguration {
        guard core.withOutput(for: self, { $0.stop() }) != nil else { return .interrupted(.stop) }
        outputRunning = false
        plan = nil
        converter = nil
        guard let rate = negotiate(next.sampleRate) else { return .interrupted(.stop) }
        hardwareRate = rate
        let newPlan = OutputFormatPolicy.plan(source: next, hardwareRate: rate, capabilities: core.capabilities)
        let channels = next.channels
        let rendered = written
        do {
            let configured = try core.withOutput(for: self) { output -> Bool in
                let fresh = core.shared.withLock { s in
                    let fresh = RenderSource(
                        channels: channels, capacityFrames: max(newPlan.clientSampleRate / 2, 1),
                        renderedFrames: rendered, inheritingHoldsFrom: s.source)
                    s.source = fresh
                    return fresh
                }
                source = fresh
                output.source = fresh
                try output.configure(newPlan, channels: channels)
                try output.start()
                return true
            }
            guard configured != nil else { return .interrupted(.stop) }
        } catch {
            return .failed("output rejected \(newPlan): \(error)")
        }
        plan = newPlan
        outputRunning = true
        core.emit([.planChanged(newPlan)], for: self)
        return .configured
    }

    /// Runs `negotiateRate` in a task and blocks this thread for the answer. Nil if the session stops meanwhile.
    private func negotiate(_ sampleRate: Int) -> Int? {
        let result = NegotiatedRate()
        let negotiateRate = core.negotiateRate
        Task.detached(priority: .userInitiated) {
            result.finish(await negotiateRate(sampleRate))
        }
        while !result.wait(timeout: .milliseconds(5)) {
            if stopRequested.load(ordering: .acquiring) { return nil }
        }
        let rate = result.value
        return rate > 0 ? rate : sampleRate
    }

    // MARK: Decoding

    private func play() -> Step {
        guard let decoder, let format, let plan else { return .advance }
        let channels = format.channels
        while true {
            if let step = interruption() { return step }
            emitDueMarkers()
            let frames: Int
            do {
                frames = try decoder.read(into: samples, maxFrames: Self.blockFrames)
            } catch {
                boundaryEvents.append(.itemFailed(index, String(describing: error)))
                return .advance
            }
            guard frames > 0 else {
                boundaryEvents.append(.trackEnded(index))
                return .advance
            }
            let count = frames * channels
            Self.convert(samples, count: count, bits: format.bitsPerSample, plan: plan, dither: &dither, into: words)
            let interrupted: Step?
            if let converter {
                resampled.removeAll(keepingCapacity: true)
                words.withMemoryRebound(to: Float.self) { floats in
                    let block = UnsafeBufferPointer(rebasing: floats[0..<count])
                    _ = converter.process(block, frames: frames, into: &resampled)
                }
                converterInput += Int64(frames)
                interrupted = writeResampled()
            } else {
                interrupted = write(UnsafeBufferPointer(rebasing: words[0..<count]))
            }
            if let interrupted { return interrupted }
        }
    }

    /// Converts `count` native-range samples of a `bits`-deep source into the client format, as 32-bit words:
    /// - Int32: `v << (32 − b)`.
    /// - Float32: `v / 2^(b−1)`, done as a multiply by the exact reciprocal power of two, which gives the same bits.
    ///   Exact for b ≤ 24.
    /// - Float32 reduced to 24 bits: shifted to full 32-bit range, TPDF-dithered in place to multiples of 256, then
    ///   divided by 2^31. Also exact, as 24 significant bits fit a Float32.
    private static func convert(
        _ samples: UnsafeMutableBufferPointer<Int32>, count: Int, bits: Int, plan: OutputPlan,
        dither: inout TPDFDither, into words: UnsafeMutableBufferPointer<UInt32>
    ) {
        let shift = 32 - bits
        switch plan.client {
        case .int32:
            for i in 0..<count {
                words[i] = UInt32(bitPattern: samples[i] << shift)
            }
        case .float32 where plan.reduceTo24:
            for i in 0..<count {
                samples[i] <<= shift
            }
            dither.reduce32To24(UnsafeMutableBufferPointer(rebasing: samples[0..<count]))
            let scale: Float = 0x1p-31
            for i in 0..<count {
                words[i] = (Float(samples[i]) * scale).bitPattern
            }
        case .float32:
            let scale = Float(sign: .plus, exponent: 1 - bits, significand: 1)
            for i in 0..<count {
                words[i] = (Float(samples[i]) * scale).bitPattern
            }
        }
    }

    private func reserveBuffers(channels: Int) {
        let count = Self.blockFrames * channels
        guard samples.count != count else { return }
        samples.deallocate()
        words.deallocate()
        samples = .allocate(capacity: count)
        samples.initialize(repeating: 0)
        words = .allocate(capacity: count)
        words.initialize(repeating: 0)
    }

    /// Drains the resampler's tail into the ring and retires it (a converter is never fed after `flush`).
    private func flushConverter() -> Step? {
        guard let converter else { return nil }
        self.converter = nil
        resampled.removeAll(keepingCapacity: true)
        _ = converter.flush(into: &resampled)
        return writeResampled()
    }

    private func writeResampled() -> Step? {
        resampled.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UInt32.self) { write($0) }
        }
    }

    /// Writes all of `data` to the ring, waiting for room. If a seek or stop arrives meanwhile, returns that step; the
    /// rest of `data` is then stale and dropped.
    private func write(_ data: UnsafeBufferPointer<UInt32>) -> Step? {
        guard let source else { return nil }
        var offset = 0
        while true {
            let n = source.write(UnsafeBufferPointer(rebasing: data[offset...]))
            offset += n
            written += Int64(n / source.channels)
            if offset >= data.count { return nil }
            if let step = interruption() { return step }
            emitDueMarkers()
            pause(forFrames: Int64((data.count - offset) / source.channels - source.writableFrames))
        }
    }

    // MARK: Seeking, events, waiting

    private func interruption() -> Step? {
        if stopRequested.load(ordering: .acquiring) { return .stop }
        guard let seekPending = core.withShared(for: self, { $0.requestedSeek != nil }) else { return .stop }
        return seekPending ? .seek : nil
    }

    /// Flushes the ring by handshake with the render thread (or outright while the output is stopped), then takes
    /// the newest request with its hold ticket, releases the holds, and re-enters the item being rendered.
    private func performSeek() -> Step {
        if let source {
            if outputRunning {
                let generation = source.requestFlush()
                while !source.isFlushAcknowledged(generation) {
                    if stopRequested.load(ordering: .acquiring) { return .stop }
                    emitDueMarkers()
                    _ = wakeup.wait(timeout: .now() + .milliseconds(1))
                }
            } else {
                source.flushWhileStopped()
            }
            // Nothing is buffered now and nothing new is written yet, so the rendered count is frozen.
            written = source.renderedFrames
        }
        // Read together under the lock `seek(toFrame:)` holds, so the ticket covers exactly the requests taken.
        let taken = core.withShared(for: self) { s -> (target: Int64, ticket: UInt64)? in
            guard let target = s.requestedSeek else { return nil }
            s.requestedSeek = nil
            return (target, s.source?.seekHoldTicket ?? 0)
        }
        guard let taken else { return .stop }
        guard let (target, ticket) = taken else {
            assertionFailure("only the decode thread takes seek requests")
            return .play
        }
        source?.releaseSeekHolds(through: ticket)
        emitDueMarkers()
        markers.removeAll()
        boundaryEvents.removeAll()
        converter = nil
        let truncatedAt = written
        guard let rendering = core.withShared(for: self, { $0.timeline.truncate(after: truncatedAt) }) else {
            return .stop
        }
        // No segment means nothing ever played: every item failed and the queue has ended.
        guard let playing = rendering else { return .ended }
        return .enter(index: playing, frame: target, entry: .seek)
    }

    private func emitDueMarkers() {
        guard let first = markers.first else { return }
        let rendered = source?.renderedFrames ?? 0
        guard first.at <= rendered else { return }
        let due = markers.prefix { $0.at <= rendered }.map(\.event)
        markers.removeFirst(due.count)
        core.emit(due, for: self)
    }

    /// Sleeps until about `frames` more frames have been rendered or the next marker is due, within 1…8 ms. A seek or
    /// stop wakes it early.
    private func pause(forFrames frames: Int64) {
        var frames = frames
        if let next = markers.first {
            frames = min(frames, next.at - (source?.renderedFrames ?? 0))
        }
        let rate = Double(plan?.clientSampleRate ?? 48_000)
        let microseconds = min(max(Double(frames) / rate * 1_000_000, 1_000), 8_000)
        _ = wakeup.wait(timeout: .now() + .microseconds(Int(microseconds)))
    }
}
