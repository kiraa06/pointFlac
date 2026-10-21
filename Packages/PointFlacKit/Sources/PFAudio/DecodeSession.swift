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
        /// The current item has reached the start of its overlap with the next (`Prepared.overlap`).
        case crossfade
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
        /// For the end of an item that fades out under the next: the rendered frame their overlap began at. Once that
        /// has rendered, the listener has heard the item go, so a seek fires the event at once (the seek cuts the item
        /// off) rather than dropping it with the markers it makes stale.
        var overlapStart: Int64?
    }

    /// The next item, opened while the current one still plays, to see whether the two overlap (`prepareNext`). The
    /// overlap takes its decoder, or the join does when they do not overlap.
    private struct Prepared {
        var index: Int
        var decoder: PCMDecoding
        /// Where the overlap begins, in the current item's source frames, and its length; nil for a plain join.
        var overlap: (start: Int64, frames: Int)?
    }

    /// A crossfade under way: the current item (`decoder`) fades out while item `index` fades in, over `frames` source
    /// frames. A class, so the mixing loop can update it in place and leave it as it stands at any interruption.
    private final class Overlap {
        let index: Int
        let decoder: PCMDecoding
        let format: AudioFormat
        let frames: Int
        /// The incoming item's ReplayGain (linear), taken as it was entered at the overlap's start, and its dither.
        let gain: Double
        var dither: TPDFDither
        /// The rendered frame the overlap begins at: the incoming item's `trackStarted` and the start of its segment.
        let renderedStart: Int64
        /// Overlap frames mixed so far.
        var done = 0
        /// The incoming item's next source frame.
        var incomingFrame: Int64 = 0
        /// Set once an item has run out (its end) or failed within the overlap; it is silent from there.
        var outgoingEnd: PipelineEvent?
        var incomingEnd: PipelineEvent?

        init(
            index: Int, decoder: PCMDecoding, frames: Int, gain: Double, dither: TPDFDither, renderedStart: Int64
        ) {
            self.index = index
            self.decoder = decoder
            format = decoder.format
            self.frames = frames
            self.gain = gain
            self.dither = dither
            self.renderedStart = renderedStart
        }
    }

    private let core: PipelineCore
    private let startIndex: Int
    private let startFrame: Int64
    private let stopRequested = Atomic<Bool>(false)
    private let wakeup = DispatchSemaphore(value: 0)

    // Decode-thread state.
    /// The queue: the items `start` gave, then the ones `append` added, taken from the shared state as they are needed.
    private var items: [PlaybackItem]
    /// Where each appended batch begins: the boundaries Between albums overlaps.
    private var batchStarts: Set<Int>
    private var decoder: PCMDecoding?
    /// The item `decoder` reads.
    private var index = -1
    /// The source frame `decoder` reads next.
    private var sourceFrame: Int64 = 0
    /// Whether the current item's end has been looked at for an overlap with the next (once per entry).
    private var endConsidered = false
    private var prepared: Prepared?
    private var overlap: Overlap?
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
    /// A seek's fade-in (every seek's but a scrub's hand-over, `PlaybackPipeline.seek(toFrame:)`): its length in
    /// source frames, and the frames of it still to write. 0 left is no fade.
    private var fadeInFrames = 0
    private var fadeInLeft = 0
    /// The seek being entered fades in.
    private var enteringFadeIn = false
    private var converter: SampleRateConverter?
    /// `written` when `converter` was created, and the source frames fed to it since.
    private var converterBase: Int64 = 0
    private var converterInput: Int64 = 0
    private var samples = UnsafeMutableBufferPointer<Int32>(start: nil, count: 0)
    private var words = UnsafeMutableBufferPointer<UInt32>(start: nil, count: 0)
    /// The incoming item's block during an overlap, decoded and converted beside the outgoing one's. Allocated with
    /// `samples` and `words`, per session, never per block.
    private var incomingSamples = UnsafeMutableBufferPointer<Int32>(start: nil, count: 0)
    private var incomingWords = UnsafeMutableBufferPointer<UInt32>(start: nil, count: 0)
    private var resampled: [Float] = []
    /// Signpost intervals waiting for the first real frame rendered past `mark`: the start's, and the latest seek's.
    private var firstFrames: [(interval: FirstFrameInterval, mark: Int64)]

    init(
        core: PipelineCore, items: [PlaybackItem], batchStarts: Set<Int>, startIndex: Int, startFrame: Int64,
        firstFrame: FirstFrameInterval
    ) {
        self.core = core
        self.items = items
        self.batchStarts = batchStarts
        self.startIndex = startIndex
        self.startFrame = startFrame
        dither = TPDFDither(seed: core.ditherSeed)
        // A fresh session renders from frame 0, so any real frame ends the start's interval.
        firstFrames = [(firstFrame, 0)]
    }

    deinit {
        samples.deallocate()
        words.deallocate()
        incomingSamples.deallocate()
        incomingWords.deallocate()
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
            case .crossfade: step = crossfade()
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
        let opened = open(from: first, frame: frame, entry: entry)
        // Whatever `open` did not take was opened for another boundary: stale now.
        prepared = nil
        guard let (next, target, frame, entry) = opened else {
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
        sourceFrame = frame
        endConsidered = false
        // A seek's discontinuity only: a start, a gapless join or an overlap's incoming item never fades.
        if entry == .seek, enteringFadeIn {
            fadeInFrames = RenderSource.fadeFrames(atRate: nextFormat.sampleRate)
            fadeInLeft = fadeInFrames
        } else {
            fadeInLeft = 0
        }
        enteringFadeIn = false
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
            let gainDb = Self.enteredGainDb(s.gainsDb[item.id] ?? item.gainDb, client: client)
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
    /// within the current item reuses its decoder, and an item already opened for its boundary (`prepared`) reuses
    /// that one. Each failure becomes an `.itemFailed` at the coming boundary, and the next item is tried from its
    /// start. Past the last item it takes what `append` has added since; nil when the queue runs out.
    ///
    /// An item v1 does not play (`ChannelPolicy`: more than two channels) fails here, on the decoder's own format, so
    /// the output is never configured for it and nothing of it reaches the ring.
    private func open(
        from first: Int, frame: Int64, entry: Entry
    ) -> (decoder: PCMDecoding, index: Int, frame: Int64, entry: Entry)? {
        var target = first
        var frame = frame
        var entry = entry
        while true {
            if target >= items.count { takeAppends() }
            guard target < items.count else { return nil }
            do {
                let candidate: PCMDecoding
                if entry == .seek, target == index, let decoder {
                    candidate = decoder
                } else if let prepared, prepared.index == target {
                    candidate = prepared.decoder
                    self.prepared = nil
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
    }

    /// Takes the items `append` has added since the last look into the queue, with where each batch begins.
    private func takeAppends() {
        _ = core.withShared(for: self) { takeAppends(from: &$0) }
    }

    /// `takeAppends` inside a critical section already held.
    private func takeAppends(from s: inout PipelineCore.Shared) {
        guard !s.appended.isEmpty else { return }
        items += s.appended
        batchStarts.formUnion(s.appendedStarts)
        s.appended.removeAll()
        s.appendedStarts.removeAll()
    }

    /// The gain, in dB, an item is entered at when `setGains` or its own gives it `set`: none for an Int32 client
    /// (passthrough carries the source's words untouched), or for a value that is not finite.
    private static func enteredGainDb(_ set: Double, client: OutputPlan.Client) -> Double {
        client == .int32 || !set.isFinite ? 0 : set
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
    private func appendMarker(_ event: PipelineEvent, at frame: Int64, overlapStart: Int64? = nil) {
        markers.append(Marker(at: max(frame, markers.last?.at ?? frame), event: event, overlapStart: overlapStart))
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
        // Appends that came since `open` last looked carry the queue on. With none it closes, in the same critical
        // section: an append from now on is refused, and the player plays it afresh once this queue has played out.
        let more = core.withShared(for: self) { s -> Bool in
            guard s.appended.isEmpty else { return true }
            s.queueClosed = true
            return false
        }
        guard let more else { return .stop }
        if more { return .enter(index: items.count, frame: 0, entry: .next) }
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
        let total = decoder.totalFrames
        while true {
            if let step = interruption() { return step }
            emitDueMarkers()
            var limit = Self.blockFrames
            // Within a crossfade of the end, the next item is opened to see whether the two overlap; until then, reads
            // stop short of that point, so it is looked at exactly there.
            if !endConsidered, let fade = crossfadeFrames(total: total, rate: format.sampleRate) {
                let remaining = total - sourceFrame
                if remaining <= Int64(fade) {
                    endConsidered = true
                    prepareNext(fade: fade, remaining: remaining, total: total)
                } else {
                    limit = min(limit, Int(remaining - Int64(fade)))
                }
            }
            if let start = prepared?.overlap?.start {
                if sourceFrame >= start { return .crossfade }
                limit = min(limit, Int(start - sourceFrame))
            }
            let frames: Int
            do {
                frames = try decoder.read(into: samples, maxFrames: limit)
            } catch {
                boundaryEvents.append(.itemFailed(index, String(describing: error)))
                return .advance
            }
            guard frames > 0 else {
                boundaryEvents.append(.trackEnded(index))
                return .advance
            }
            sourceFrame += Int64(frames)
            let count = frames * channels
            Self.convert(
                samples, count: count, bits: format.bitsPerSample, plan: plan, gain: gain, dither: &dither, into: words)
            if fadeInLeft > 0 { fadeIn(frames: frames, channels: channels, client: plan.client) }
            if let interrupted = writeWords(frames: frames, count: count) { return interrupted }
        }
    }

    /// Writes `count` converted words from `words` to the ring, through the resampler when the plan has one.
    private func writeWords(frames: Int, count: Int) -> Step? {
        guard let converter else { return write(UnsafeBufferPointer(rebasing: words[0..<count])) }
        resampled.removeAll(keepingCapacity: true)
        words.withMemoryRebound(to: Float.self) { floats in
            let block = UnsafeBufferPointer(rebasing: floats[0..<count])
            _ = converter.process(block, frames: frames, into: &resampled)
        }
        converterInput += Int64(frames)
        return writeResampled()
    }

    // MARK: Crossfade

    /// The crossfade's length in source frames at `rate` for the boundary after the current item, as the settings
    /// stand now; nil when that boundary cannot overlap: crossfade off, Between albums at a boundary `append` did not
    /// mark, no next item (yet), or a current item of unknown length. Takes any appends meanwhile.
    private func crossfadeFrames(total: Int64, rate: Int) -> Int? {
        guard total > 0 else { return nil }
        let settings = core.withShared(for: self) { s -> CrossfadeSettings in
            takeAppends(from: &s)
            return s.crossfade
        }
        guard let settings, index + 1 < items.count, overlaps(settings, into: index + 1) else { return nil }
        return PipelineCore.crossfadeFrames(settings, rate: rate)
    }

    /// Whether `settings` overlap the boundary into item `next`: Always every boundary, Between albums only those
    /// where an appended batch begins.
    private func overlaps(_ settings: CrossfadeSettings, into next: Int) -> Bool {
        switch settings.mode {
        case .off: false
        case .always: true
        case .betweenAlbums: batchStarts.contains(next)
        }
    }

    /// The current item has `remaining` of its `total` frames left, within a crossfade of `fade` frames of its end.
    /// Opens the next item (`prepared`) and, when it can continue the running output (the same plan and channel
    /// count, `isCompatible`), sets their overlap: `fade` frames, or fewer when the current item has fewer left (a seek
    /// near its end) or the next is shorter than two fades (it keeps half for its own fade out). The overlap begins
    /// that many frames before the current item's end. When the next item does not open, the join opens it again and
    /// reports why.
    private func prepareNext(fade: Int, remaining: Int64, total: Int64) {
        let next = index + 1
        guard next < items.count, let candidate = try? core.makeDecoder(items[next]) else { return }
        var ready = Prepared(index: next, decoder: candidate, overlap: nil)
        defer { prepared = ready }
        guard ChannelPolicy.isPlayable(candidate.format), isCompatible(candidate.format, gainDb: gainDb(of: next))
        else { return }
        var frames = Int(min(Int64(fade), remaining))
        if candidate.totalFrames > 0 { frames = min(frames, Int(candidate.totalFrames / 2)) }
        guard frames > 0 else { return }
        ready.overlap = (total - Int64(frames), frames)
    }

    /// The overlap's start: enters the next item there, then mixes the two (`mix`).
    ///
    /// The incoming item is entered as any item is (ruling R4-T12b): its gain is taken and its segment published in
    /// one critical section, with the outgoing segment marked as fading out until the overlap's predicted end, so
    /// `enteredGains` shows both and a switch can re-cue them. The same section checks the crossfade still applies
    /// (a switch to Pure or Off since `prepareNext` calls it off, and the boundary is then a join), so a switch either
    /// finds this overlap entered or keeps it from starting. Its `trackStarted` sits at the overlap's first frame.
    private func crossfade() -> Step {
        guard let ready = prepared, let frames = ready.overlap?.frames, let plan, let source else {
            prepared?.overlap = nil
            return .play
        }
        prepared = nil
        let next = ready.index
        let item = items[next]
        let client = plan.client
        let boundary = converter != nil ? converterBoundary : written
        let end = renderedFrame(afterFeeding: frames)
        let rendered = source.renderedFrames
        let segment = Timeline.Segment(
            index: next, renderedStart: boundary, sourceStart: 0, rate: plan.resample,
            totalFrames: ready.decoder.totalFrames, gainDb: 0)
        let entered = core.withShared(for: self) { s -> Double? in
            guard overlaps(s.crossfade, into: next) else { return nil }
            var segment = segment
            segment.gainDb = Self.enteredGainDb(s.gainsDb[item.id] ?? item.gainDb, client: client)
            s.timeline.append(segment, rendered: rendered, fadingOutUntil: end)
            return segment.gainDb
        }
        guard let entered else { return .stop }
        guard let gainDb = entered else {
            // Called off: the join takes the decoder.
            prepared = Prepared(index: next, decoder: ready.decoder, overlap: nil)
            return .play
        }
        placeBoundaryEvents(at: boundary)
        appendMarker(.trackStarted(next, ready.decoder.format, totalFrames: ready.decoder.totalFrames), at: boundary)
        overlap = Overlap(
            index: next, decoder: ready.decoder, frames: frames, gain: gainDb == 0 ? 1 : pow(10, gainDb / 20),
            dither: TPDFDither(seed: core.ditherSeed), renderedStart: boundary)
        return mix()
    }

    /// The rendered frame the stream reaches once `frames` more source frames are written: through the resampler,
    /// predicted from the ratio, as `converterBoundary` is.
    private func renderedFrame(afterFeeding frames: Int) -> Int64 {
        guard let rate = plan?.resample, converter != nil else { return written + Int64(frames) }
        let input = Double(converterInput + Int64(frames))
        return converterBase + Int64((input * Double(rate.to) / Double(rate.from)).rounded())
    }

    /// Mixes the overlap, a block at a time: each item read and converted at its own gain and with its own dither,
    /// then `cos(πt/2)·a + sin(πt/2)·b` (`PlaybackPipeline.crossfadeWeights`), written to the ring as one stream
    /// (through the one resampler, at the items' own rate, when the plan resamples). An item that runs out or fails
    /// within the overlap is silent from there, the other carrying on along its curve; if both have, the overlap ends
    /// early. A seek or stop returns its step at once, leaving the overlap as it stands for `performSeek`.
    private func mix() -> Step {
        guard let overlap, let decoder, let format, let plan else { return .play }
        let channels = format.channels
        while overlap.done < overlap.frames {
            if let step = interruption() { return step }
            emitDueMarkers()
            let n = min(Self.blockFrames, overlap.frames - overlap.done)
            var outgoing = 0
            if overlap.outgoingEnd == nil {
                let read = Self.read(decoder, into: samples, frames: n, channels: channels)
                outgoing = read.frames
                if let error = read.error {
                    overlap.outgoingEnd = .itemFailed(index, String(describing: error))
                } else if outgoing < n {
                    overlap.outgoingEnd = .trackEnded(index)
                }
            }
            var incoming = 0
            if overlap.incomingEnd == nil {
                let read = Self.read(overlap.decoder, into: incomingSamples, frames: n, channels: channels)
                incoming = read.frames
                if let error = read.error {
                    overlap.incomingEnd = .itemFailed(overlap.index, String(describing: error))
                } else if incoming < n {
                    overlap.incomingEnd = .trackEnded(overlap.index)
                }
            }
            guard outgoing > 0 || incoming > 0 else { break }
            let count = n * channels
            Self.convert(
                samples, count: outgoing * channels, bits: format.bitsPerSample, plan: plan, gain: gain,
                dither: &dither, into: words)
            Self.silence(words, from: outgoing * channels, to: count)
            Self.convert(
                incomingSamples, count: incoming * channels, bits: overlap.format.bitsPerSample, plan: plan,
                gain: overlap.gain, dither: &overlap.dither, into: incomingWords)
            Self.silence(incomingWords, from: incoming * channels, to: count)
            Self.mix(
                incomingWords, into: words, frames: n, channels: channels, from: overlap.done, of: overlap.frames,
                client: plan.client)
            // A seek that landed within a fade of the end overlaps at once: its fade-in is on what is heard, the mix.
            if fadeInLeft > 0 { fadeIn(frames: n, channels: channels, client: plan.client) }
            sourceFrame += Int64(outgoing)
            overlap.incomingFrame += Int64(incoming)
            overlap.done += n
            if let step = writeWords(frames: n, count: count) { return step }
        }
        return finishOverlap()
    }

    /// The overlap is written: the outgoing item's end (or failure) is placed at its last frame, its fade's end is
    /// fixed where the stream really got to, and the incoming item becomes the current one.
    private func finishOverlap() -> Step {
        guard let overlap else { return .play }
        self.overlap = nil
        let end = converter != nil ? converterBoundary : written
        appendMarker(overlap.outgoingEnd ?? .trackEnded(index), at: end, overlapStart: overlap.renderedStart)
        _ = core.withShared(for: self) { $0.timeline.endFade(at: end) }
        decoder = overlap.decoder
        index = overlap.index
        format = overlap.format
        gain = overlap.gain
        dither = overlap.dither
        sourceFrame = overlap.incomingFrame
        // A seek's fade-in still under way runs on into the incoming item: it is on the stream, not on an item.
        endConsidered = false
        if let ended = overlap.incomingEnd {
            boundaryEvents.append(ended)
            return .advance
        }
        return .play
    }

    private static func silence(_ words: UnsafeMutableBufferPointer<UInt32>, from start: Int, to end: Int) {
        guard start < end else { return }
        UnsafeMutableBufferPointer(rebasing: words[start..<end]).update(repeating: 0)
    }

    /// Reads up to `frames` frames into `buffer`, as many reads as it takes: fewer only at the end of the stream, or
    /// when a read fails, which returns its error with the frames read before it, so they still play.
    private static func read(
        _ decoder: PCMDecoding, into buffer: UnsafeMutableBufferPointer<Int32>, frames: Int, channels: Int
    ) -> (frames: Int, error: (any Error)?) {
        var done = 0
        while done < frames {
            let rest = UnsafeMutableBufferPointer(rebasing: buffer[(done * channels)...])
            do {
                let n = try decoder.read(into: rest, maxFrames: frames - done)
                guard n > 0 else { break }
                done += n
            } catch {
                return (done, error)
            }
        }
        return (done, nil)
    }

    /// Mixes `frames` frames of `incoming` into `words`, frames `start…` of an overlap `total` frames long, by
    /// `PlaybackPipeline.crossfadeWeights`. The products are summed in Double and rounded once: to Float32 for a
    /// Float32 client, to the nearest Int32, clipped, for an Int32 one.
    private static func mix(
        _ incoming: UnsafeMutableBufferPointer<UInt32>, into words: UnsafeMutableBufferPointer<UInt32>, frames: Int,
        channels: Int, from start: Int, of total: Int, client: OutputPlan.Client
    ) {
        for f in 0..<frames {
            let w = PlaybackPipeline.crossfadeWeights(frame: start + f, of: total)
            let base = f * channels
            switch client {
            case .float32:
                for i in base..<(base + channels) {
                    let x = Double(Float(bitPattern: words[i])) * w.outgoing
                    let y = Double(Float(bitPattern: incoming[i])) * w.incoming
                    words[i] = Float(x + y).bitPattern
                }
            case .int32:
                for i in base..<(base + channels) {
                    let x = Double(Int32(bitPattern: words[i])) * w.outgoing
                    let y = Double(Int32(bitPattern: incoming[i])) * w.incoming
                    words[i] = UInt32(bitPattern: Int32(clamping: Int64((x + y).rounded())))
                }
            }
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

    /// Ramps the start of a seek's audio up from silence, linearly over `fadeInFrames`, in the converted words:
    /// frame k of the ramp is scaled by k / `fadeInFrames`, a Float32 word in Float32, an Int32 one in Double, rounded
    /// half away from zero. Past the ramp, nothing is touched.
    private func fadeIn(frames: Int, channels: Int, client: OutputPlan.Client) {
        let n = min(frames, fadeInLeft)
        let done = fadeInFrames - fadeInLeft
        for f in 0..<n {
            let weight = Float(done + f) / Float(fadeInFrames)
            for c in 0..<channels {
                let i = f * channels + c
                switch client {
                case .float32:
                    words[i] = (Float(bitPattern: words[i]) * weight).bitPattern
                case .int32:
                    let x = Double(Int32(bitPattern: words[i])) * Double(weight)
                    words[i] = UInt32(bitPattern: Int32(x.rounded()))
                }
            }
        }
        fadeInLeft -= n
    }

    /// The block buffers, the overlap's incoming pair with them, for `channels`: reallocated only when the channel
    /// count changes, at an item's entry, so an overlap (whose items share the channel count) allocates nothing.
    private func reserveBuffers(channels: Int) {
        let count = Self.blockFrames * channels
        guard samples.count != count else { return }
        for buffer in [samples, incomingSamples] { buffer.deallocate() }
        for buffer in [words, incomingWords] { buffer.deallocate() }
        samples = .allocate(capacity: count)
        samples.initialize(repeating: 0)
        words = .allocate(capacity: count)
        words.initialize(repeating: 0)
        incomingSamples = .allocate(capacity: count)
        incomingSamples.initialize(repeating: 0)
        incomingWords = .allocate(capacity: count)
        incomingWords.initialize(repeating: 0)
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
        enteringFadeIn = request.fadeIn
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
        // A seek ends any overlap. One already heard (its start rendered) has cut the outgoing item off: its end
        // fires now, after the incoming item's `trackStarted`, whether its overlap is still being mixed or only its
        // end marker waits. The seek lands in the incoming item then, which is the one rendering; before that it lands
        // in the outgoing one, which overlaps afresh when its end comes round again.
        var cut = markers.filter { ($0.overlapStart ?? .max) <= written }.map(\.event)
        if let overlap, overlap.renderedStart <= written { cut.append(overlap.outgoingEnd ?? .trackEnded(index)) }
        if !cut.isEmpty { core.emit(cut, for: self) }
        let incoming = overlap.map { Prepared(index: $0.index, decoder: $0.decoder, overlap: nil) }
        overlap = nil
        prepared = nil
        markers.removeAll()
        boundaryEvents.removeAll()
        converter = nil
        let truncatedAt = written
        guard let rendering = core.withShared(for: self, { $0.timeline.truncate(after: truncatedAt) }) else {
            return .stop
        }
        // No segment means nothing ever played: every item failed and the queue has ended.
        guard let playing = rendering else { return .ended }
        // Seeking within the incoming item of an overlap still being mixed: `open` reuses its decoder.
        if let incoming, incoming.index == playing { prepared = incoming }
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
    /// The audio from `target` fades in: every seek's but a scrub's hand-over.
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
