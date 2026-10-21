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
    /// The current item's ReplayGain, linear: exactly 1 for a gain of 0 dB, which then multiplies nothing.
    private var gain = 1.0
    /// The re-cue's fade-in (`PlaybackPipeline.recue`): its length in source frames, and the frames of it still to
    /// write. 0 left is no fade.
    private var fadeInFrames = 0
    private var fadeInLeft = 0
    /// The seek being entered is a re-cue's: its audio fades in.
    private var enteringRecue = false
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
        // The gain as it stands now chooses the plan only (a gain needs Float32). The gain the item plays at is taken
        // again when it is entered, below, after any drain and reconfigure.
        let planGainDb = gainDb(of: target)
        var boundary = written
        if isCompatible(nextFormat, gainDb: planGainDb) {
            if entry == .next, converter != nil { boundary = converterBoundary }
            placeBoundaryEvents(at: boundary)
        } else {
            if let step = flushConverter() { return step }
            boundary = written
            placeBoundaryEvents(at: boundary)
            // The output stops once this is rendered: the silence until then is the gap, not an underrun.
            source?.markEndOfStream()
            if let step = drain() { return step }
            switch reconfigure(for: nextFormat, gainDb: planGainDb) {
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
        // Only into a Float32 client: an Int32 one carries the source's words untouched.
        if entry == .seek, enteringRecue, plan.client == .float32 {
            fadeInFrames = max(1, Int((RenderSource.crossfadeSeconds * Double(nextFormat.sampleRate)).rounded()))
            fadeInLeft = fadeInFrames
        } else {
            fadeInLeft = 0
        }
        enteringRecue = false
        dither = TPDFDither(seed: core.ditherSeed)
        reserveBuffers(channels: nextFormat.channels)
        // The item is entered here: its gain is taken and its segment published in one critical section, the lock
        // `setGains` takes (ruling R4-T12b). A `setGains` before it gives this item the new gain; one after it finds
        // the segment in `enteredGains`, so a switch can re-cue it. Nothing of the item is decoded before this, so no
        // audio is ever heard at a gain `enteredGains` did not show. Across a drain and reconfigure (a plan change) the
        // gain read for the plan may be stale by now; a Float32 plan takes any gain. An Int32 one (passthrough, with a
        // gain of 0 when planned) takes none: the item then plays at 0 dB, as its segment says, and a gain set
        // meanwhile reaches it at the next seek or re-cue.
        let item = items[target]
        let client = plan.client
        let rendered = source.renderedFrames
        let start = Timeline.Segment(
            index: target, renderedStart: boundary, sourceStart: frame, rate: plan.resample,
            totalFrames: next.totalFrames, gainDb: 0)
        let enteredGainDb = core.withShared(for: self) { s -> Double in
            let set = s.gainsDb[item.id] ?? item.gainDb
            let gainDb = client == .int32 || !set.isFinite ? 0 : set
            var segment = start
            segment.gainDb = gainDb
            s.timeline.append(segment, rendered: rendered)
            if s.requestedSeek == nil { s.timeline.pendingFrame = nil }
            return gainDb
        }
        guard let enteredGainDb else { return .stop }
        gain = enteredGainDb == 0 ? 1 : pow(10, enteredGainDb / 20)
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

    /// The ReplayGain item `index` would play at now, in dB: what `setGains` last gave its ID, else its own. A value
    /// that is not finite is no gain. For choosing a plan; the item's own gain is taken as it is entered.
    private func gainDb(of index: Int) -> Double {
        let item = items[index]
        let set = core.withShared(for: self) { $0.gainsDb[item.id] } ?? nil
        let gainDb = set ?? item.gainDb
        return gainDb.isFinite ? gainDb : 0
    }

    /// Whether an item of format `next`, at a ReplayGain of `gainDb`, can continue into the running output: the same
    /// plan at the current hardware rate, and the same channel count. Its gain itself needs no plan of its own, only
    /// the Float32 client a gain asks for.
    private func isCompatible(_ next: AudioFormat, gainDb: Double) -> Bool {
        guard outputRunning, let plan, let hardwareRate, let format, format.channels == next.channels else {
            return false
        }
        let capabilities = core.capabilities
        return OutputFormatPolicy.plan(
            source: next, hardwareRate: hardwareRate, capabilities: capabilities, gainDb: gainDb) == plan
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

    /// Stop, negotiate, re-plan, configure, compile the Sound chain for the new format, start, `.planChanged`. The ring
    /// must be drained. The new source starts counting at `written` (all of it rendered), so markers stay valid.
    ///
    /// A rate ≤ 0 from `negotiateRate` means the session has no usable output rate. That fails the item: assuming the
    /// source rate instead would break "client rate == hardware rate" and let iOS resample silently.
    private func reconfigure(for next: AudioFormat, gainDb: Double) -> Reconfiguration {
        // Everything before this boundary is rendered; its events (an earlier item's failure) precede `.planChanged`.
        emitDueMarkers()
        guard core.withOutput(for: self, { $0.stop() }) != nil else { return .interrupted(.stop) }
        outputRunning = false
        plan = nil
        converter = nil
        guard let rate = negotiate(next.sampleRate) else { return .interrupted(.stop) }
        guard rate > 0 else { return .failed("Output rate unavailable") }
        hardwareRate = rate
        let newPlan = OutputFormatPolicy.plan(
            source: next, hardwareRate: rate, capabilities: core.capabilities, gainDb: gainDb)
        let channels = next.channels
        let rendered = written
        do {
            let configured = try core.withOutput(for: self) { output -> Bool in
                let fresh = core.shared.withLock { s in
                    let fresh = RenderSource(
                        channels: channels, capacityFrames: max(newPlan.clientSampleRate / 2, 1),
                        renderedFrames: rendered, inheritingHoldsFrom: s.source,
                        clientRate: newPlan.clientSampleRate, floatClient: newPlan.client == .float32,
                        scrub: core.scrubTap, sound: core.soundRunner)
                    s.source = fresh
                    return fresh
                }
                source = fresh
                output.source = fresh
                try output.configure(newPlan, channels: channels)
                // While the output is stopped: the chain for the new rate and channels, from rest, before any of the
                // new format renders.
                core.configureSound(sampleRate: newPlan.clientSampleRate, channels: channels)
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
            Self.convert(
                samples, count: count, bits: format.bitsPerSample, plan: plan, gain: gain, dither: &dither, into: words)
            if fadeInLeft > 0 { fadeIn(frames: frames, channels: channels) }
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
    ///
    /// `gain` (linear) is the item's ReplayGain, folded into the scale. At exactly 1 (0 dB) the Float32 loops above
    /// run untouched, so the bits are too. Any other gain takes the product in Double, from the integer sample and
    /// the scale times the gain, and rounds it to Float32 at the end: within about half an ulp of the exact gained
    /// value, where a Float32 scale would round twice. On the reduced path it applies after the dither, which keeps
    /// to the 24-bit grid of the source. It never reaches an Int32 client: a gain puts a 32-bit source on Float32
    /// (`OutputFormatPolicy.plan(source:hardwareRate:capabilities:gainDb:)`).
    private static func convert(
        _ samples: UnsafeMutableBufferPointer<Int32>, count: Int, bits: Int, plan: OutputPlan, gain: Double,
        dither: inout TPDFDither, into words: UnsafeMutableBufferPointer<UInt32>
    ) {
        let shift = 32 - bits
        switch plan.client {
        case .int32:
            assert(gain == 1, "a ReplayGain never plays through an Int32 client")
            for i in 0..<count {
                words[i] = UInt32(bitPattern: samples[i] << shift)
            }
        case .float32 where plan.reduceTo24:
            for i in 0..<count {
                samples[i] <<= shift
            }
            dither.reduce32To24(UnsafeMutableBufferPointer(rebasing: samples[0..<count]))
            if gain == 1 {
                let scale: Float = 0x1p-31
                for i in 0..<count {
                    words[i] = (Float(samples[i]) * scale).bitPattern
                }
            } else {
                let scale = 0x1p-31 * gain
                for i in 0..<count {
                    words[i] = Float(Double(samples[i]) * scale).bitPattern
                }
            }
        case .float32:
            if gain == 1 {
                let scale = Float(sign: .plus, exponent: 1 - bits, significand: 1)
                for i in 0..<count {
                    words[i] = (Float(samples[i]) * scale).bitPattern
                }
            } else {
                let scale = Double(sign: .plus, exponent: 1 - bits, significand: 1) * gain
                for i in 0..<count {
                    words[i] = Float(Double(samples[i]) * scale).bitPattern
                }
            }
        }
    }

    /// Ramps the start of a re-cue's audio up from silence, linearly over `fadeInFrames`, in the converted Float32
    /// words: frame k of the ramp is scaled by k / `fadeInFrames`. Past the ramp, nothing is touched.
    private func fadeIn(frames: Int, channels: Int) {
        let n = min(frames, fadeInLeft)
        let done = fadeInFrames - fadeInLeft
        for f in 0..<n {
            let weight = Float(done + f) / Float(fadeInFrames)
            for c in 0..<channels {
                let i = f * channels + c
                words[i] = (Float(bitPattern: words[i]) * weight).bitPattern
            }
        }
        fadeInLeft -= n
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
            let fadeIn = s.seekFadesIn
            s.seekFadesIn = false
            return SeekRequest(
                target: target, ticket: s.source?.seekHoldTicket ?? 0, interval: s.seekInterval.take(), fadeIn: fadeIn)
        }
        guard let taken else { return .stop }
        guard let request = taken else {
            assertionFailure("only the decode thread takes seek requests")
            return .play
        }
        let (target, ticket) = (request.target, request.ticket)
        enteringRecue = request.fadeIn
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
    /// A re-cue's: the audio from `target` fades in.
    var fadeIn: Bool
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
