import Dispatch
import Foundation
import PFCore
import PFDSP
import Synchronization

/// One queue's decode thread.
///
/// All `var` state is confined to that thread. Other threads reach the session only through `requestStop()`,
/// `wake()`, and the core's locked state (seek requests), hence `@unchecked Sendable`.
final class DecodeSession: @unchecked Sendable {
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
    /// Signpost intervals waiting for the first real frame rendered past `mark`: the start's, and the latest seek's.
    private var firstFrames: [(interval: FirstFrameInterval, mark: Int64)]

    init(
        core: PipelineCore, items: [PlaybackItem], startIndex: Int, startFrame: Int64, firstFrame: FirstFrameInterval
    ) {
        self.core = core
        self.items = items
        self.startIndex = startIndex
        self.startFrame = startFrame
        dither = TPDFDither(seed: core.ditherSeed)
        // A fresh session renders from frame 0, so any real frame ends the start's interval.
        firstFrames = [(firstFrame, 0)]
    }

    deinit {
        samples.deallocate()
        words.deallocate()
    }

    func launch() {
        core.liveDecodeThreads.add(1, ordering: .relaxed)
        let thread = Thread { [self] in
            run()
            core.liveDecodeThreads.subtract(1, ordering: .releasing)
        }
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
            case .stop:
                for watch in firstFrames { watch.interval.end(.abandoned) }
                firstFrames.removeAll()
                return
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
            // The output stops once this is rendered: the silence until then is the gap, not an underrun.
            source?.markEndOfStream()
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
            appendMarker(.trackStarted(target, nextFormat, totalFrames: next.totalFrames), at: boundary)
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
    ///
    /// An item v1 does not play (`ChannelPolicy`: more than two channels) fails here, on the decoder's own format, so
    /// the output is never configured for it and nothing of it reaches the ring.
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
                guard ChannelPolicy.isPlayable(candidate.format) else {
                    throw Unplayable(description: ChannelPolicy.unsupportedMessage)
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
        for event in boundaryEvents { appendMarker(event, at: frame) }
        boundaryEvents.removeAll()
    }

    /// Queues `event` for when `frame` has been rendered. Frames never decrease along the queue: `emitDueMarkers`
    /// only looks at its head, so a marker placed behind a later one would wait for that one.
    private func appendMarker(_ event: PipelineEvent, at frame: Int64) {
        markers.append(Marker(at: max(frame, markers.last?.at ?? frame), event: event))
    }

    /// Once the resampler's tail is written, its true output length is known. A gapless join predicted from the
    /// ratio (`converterBoundary`) can lie a frame past it (AVAudioConverter rounds its total down), and a marker or
    /// segment there would never be reached if nothing follows. Pulls them back to the end of the stream.
    private func clampBoundariesToWritten() {
        let end = written
        for i in markers.indices where markers[i].at > end {
            markers[i].at = end
        }
        _ = core.withShared(for: self) { $0.timeline.clampStarts(to: end) }
    }

    private func finishQueue() -> Step {
        if let step = flushConverter() { return step }
        source?.markEndOfStream()
        placeBoundaryEvents(at: written)
        appendMarker(.queueEnded, at: written)
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
    ///
    /// A rate ≤ 0 from `negotiateRate` means the session has no usable output rate. That fails the item: assuming the
    /// source rate instead would break "client rate == hardware rate" and let iOS resample silently.
    private func reconfigure(for next: AudioFormat) -> Reconfiguration {
        // Everything before this boundary is rendered; its events (an earlier item's failure) precede `.planChanged`.
        emitDueMarkers()
        guard core.withOutput(for: self, { $0.stop() }) != nil else { return .interrupted(.stop) }
        outputRunning = false
        plan = nil
        converter = nil
        guard let rate = negotiate(next.sampleRate) else { return .interrupted(.stop) }
        guard rate > 0 else { return .failed("Output rate unavailable") }
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

    /// Runs `negotiateRate` in a task and blocks this thread for the answer, unchecked. Nil if the session stops
    /// meanwhile: the task is then cancelled and its answer, whenever it comes, is ignored.
    private func negotiate(_ sampleRate: Int) -> Int? {
        let result = NegotiatedRate()
        let negotiateRate = core.negotiateRate
        let task = Task.detached(priority: .userInitiated) {
            result.finish(await negotiateRate(sampleRate))
        }
        while !result.wait(timeout: .milliseconds(5)) {
            if stopRequested.load(ordering: .acquiring) {
                task.cancel()
                return nil
            }
        }
        return result.value
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
        if let step = writeResampled() { return step }
        clampBoundariesToWritten()
        return nil
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
        let taken = core.withShared(for: self) { s -> SeekRequest? in
            guard let target = s.requestedSeek else { return nil }
            s.requestedSeek = nil
            return SeekRequest(target: target, ticket: s.source?.seekHoldTicket ?? 0, interval: s.seekInterval.take())
        }
        guard let taken else { return .stop }
        guard let request = taken else {
            assertionFailure("only the decode thread takes seek requests")
            return .play
        }
        let (target, ticket) = (request.target, request.ticket)
        // Nothing renders from the ring now until the new position's audio, so the next real frame past `written` is
        // the first one at the target. An earlier seek still waiting for its frame is superseded.
        firstFrames.removeAll { watch in
            guard watch.interval.kind == .seek else { return false }
            watch.interval.end(.abandoned)
            return true
        }
        if let interval = request.interval { firstFrames.append((interval, written)) }
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
        let rendered = source?.renderedFrames ?? 0
        endFirstFrameIntervals(rendered: rendered)
        guard let first = markers.first, first.at <= rendered else { return }
        let due = markers.prefix { $0.at <= rendered }.map(\.event)
        markers.removeFirst(due.count)
        core.emit(due, for: self)
    }

    /// Ends every first-frame interval whose mark `rendered` has passed. Here on the decode thread, never in the render
    /// callback, which must not signpost (see `Telemetry`).
    private func endFirstFrameIntervals(rendered: Int64) {
        guard !firstFrames.isEmpty else { return }
        firstFrames.removeAll { watch in
            guard rendered > watch.mark else { return false }
            watch.interval.end(.rendered)
            return true
        }
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

/// A seek request as the decode thread takes it, with the hold ticket read under the same lock.
private struct SeekRequest: Sendable {
    var target: Int64
    var ticket: UInt64
    var interval: FirstFrameInterval?
}

/// An item the pipeline refuses to play. Its description is the `.itemFailed` message, word for word.
private struct Unplayable: Error, CustomStringConvertible {
    var description: String
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
