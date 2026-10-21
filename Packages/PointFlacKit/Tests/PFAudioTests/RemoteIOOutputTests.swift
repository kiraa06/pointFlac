#if os(iOS)
    import AVFoundation
    import AudioToolbox
    import CoreAudio
    import Foundation
    import PFCore
    import PFDSP
    import PFFlac
    import PFTestSupport
    import Synchronization
    import Testing

    @testable import PFAudio

    // MARK: - Helpers

    /// The seed every pipeline here is built with, so the 32-bit expectation reproduces its TPDF dither exactly.
    private let ditherSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

    private func item(_ name: String) -> PlaybackItem {
        let f = Fixtures.named(name)
        return PlaybackItem(
            id: name, url: Fixtures.url(f),
            format: AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels),
            totalFrames: f.frames)
    }

    /// Activates the real session and returns it with the rate the hardware runs at now.
    private func activeSession() async throws -> (session: SystemAudioSession, rate: Int) {
        let session = SystemAudioSession()
        try await session.activate()
        return (session, Int(AVAudioSession.sharedInstance().sampleRate))
    }

    /// `name`'s 44.1 kHz sibling when the hardware runs at 44.1 kHz, so the pipeline never has to resample.
    private func fixture(_ name: String, sessionRate: Int) -> String {
        sessionRate == 44_100 ? name.replacingOccurrences(of: "48000", with: "44100") : name
    }

    private func clientPlan(_ client: OutputPlan.Client, _ rate: Int) -> OutputPlan {
        OutputPlan(client: client, clientSampleRate: rate, resample: nil, reduceTo24: false)
    }

    /// The bytes pointFlac must hand RemoteIO for a `bits`-deep source's native-range `raw` samples under `plan`,
    /// derived independently of the pipeline:
    /// - Int32: `v << (32 − b)`.
    /// - Float32 reduced to 24 bits: `TPDFDither(seed:)` over the whole sequence from frame 0, then `v / 2^31`.
    /// - Float32: `v / 2^(b−1)`.
    private func expectedBytes(_ raw: [Int32], bits: Int, plan: OutputPlan) -> Data {
        switch plan.client {
        case .int32:
            return raw.map { $0 << (32 - bits) }.withUnsafeBytes { Data($0) }
        case .float32 where plan.reduceTo24:
            var full = raw.map { $0 << (32 - bits) }
            var dither = TPDFDither(seed: ditherSeed)
            full.withUnsafeMutableBufferPointer { dither.reduce32To24($0) }
            return full.map { Float($0) / 0x1p31 }.withUnsafeBytes { Data($0) }
        case .float32:
            let scale = Float(1 << (bits - 1))
            return raw.map { Float($0) / scale }.withUnsafeBytes { Data($0) }
        }
    }

    /// nil when the captures are identical; otherwise how they differ, by 32-bit sample.
    private func mismatch(_ got: Data, _ want: Data) -> String? {
        guard got != want else { return nil }
        guard got.count == want.count else { return "byte count \(got.count) ≠ \(want.count)" }
        let a = [UInt8](got)
        let b = [UInt8](want)
        let byte = a.indices.first { a[$0] != b[$0] } ?? 0
        return "first difference in sample \(byte / 4) (byte \(byte))"
    }

    /// The unit's stream format on bus 0: the input scope is pointFlac's client side, the output scope the hardware.
    private func streamFormat(_ output: RemoteIOOutput, _ scope: AudioUnitScope) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(output.unit, kAudioUnitProperty_StreamFormat, scope, 0, &format, &size)
        return status == noErr ? format : nil
    }

    private func describe(_ format: AudioStreamBasicDescription?) -> String {
        guard let f = format else { return "unreadable" }
        let kind =
            f.mFormatFlags & kAudioFormatFlagIsFloat != 0
            ? "float" : f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 ? "sint" : "uint"
        let layout = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "non-interleaved" : "interleaved"
        return "\(Int(f.mSampleRate)) Hz \(f.mBitsPerChannel)-bit \(kind) \(f.mChannelsPerFrame) ch \(layout)"
    }

    /// Whether `format` is exactly the interleaved, packed 32-bit `client` format at `rate`, `channels` wide.
    private func isClientFormat(
        _ format: AudioStreamBasicDescription?, _ client: OutputPlan.Client, rate: Int, channels: Int
    ) -> Bool {
        guard let f = format else { return false }
        let kindFlag = client == .float32 ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        return f.mFormatID == kAudioFormatLinearPCM && f.mSampleRate == Double(rate)
            && f.mFormatFlags & kindFlag != 0 && f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && f.mBitsPerChannel == 32
            && f.mChannelsPerFrame == UInt32(channels) && f.mBytesPerFrame == UInt32(4 * channels)
    }

    private final class EventLog: Sendable {
        private let storage = Mutex<[PipelineEvent]>([])

        var events: [PipelineEvent] { storage.withLock { $0 } }

        func append(_ event: PipelineEvent) {
            storage.withLock { $0.append(event) }
        }
    }

    /// The pipeline calls `negotiateRate` from a detached task, which does not inherit the suite's executor
    /// preference, so the real session's blocking rate change is sent to `AudioHardwareQueue` here.
    private func makePipeline(
        _ output: RemoteIOOutput, session: SystemAudioSession, capabilities: OutputCapabilities
    ) -> PlaybackPipeline {
        PlaybackPipeline(
            output: output, capabilities: capabilities,
            negotiateRate: { rate in
                await withTaskExecutorPreference(AudioHardwareQueue.shared) { await session.requestSampleRate(rate) }
            },
            makeDecoder: { try FlacDecoder(url: $0.url) }, ditherSeed: ditherSeed)
    }

    /// Stands in for `SystemAudioSession.requestSampleRate`: a nonisolated async function, which runs on the task's
    /// preferred executor when it has one.
    private func isOnAudioHardwareQueue() async -> Bool {
        AudioHardwareQueue.isCurrent
    }

    /// Waits until `condition` holds or `timeout` passes, and returns whether it held. A hang guard, so `timeout` is
    /// scaled by `LatencyBudget` (×3 under CI).
    private func wait(upTo timeout: Duration, for condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + LatencyBudget.scaled(timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    /// Plays `name` through `output` on the real session and returns the pipeline's events once `.queueEnded` has
    /// fired, or nil on timeout. The pipeline is stopped before this returns, and the output's `stop()` waits out any
    /// render call still in flight, so the capture is complete by then.
    private func playToEnd(
        _ name: String, through output: RemoteIOOutput, session: SystemAudioSession, capabilities: OutputCapabilities
    ) async -> [PipelineEvent]? {
        let pipeline = makePipeline(output, session: session, capabilities: capabilities)
        let log = EventLog()
        let events = pipeline.events
        let collector = Task {
            for await event in events { log.append(event) }
        }
        defer { collector.cancel() }
        await pipeline.start([item(name)], at: 0, fromFrame: 0)
        let ended = await wait(upTo: .seconds(10)) { log.events.contains(.queueEnded) }
        pipeline.stop()
        return ended ? log.events : nil
    }

    private func firstPlan(_ events: [PipelineEvent]) -> OutputPlan? {
        for case .planChanged(let plan) in events { return plan }
        return nil
    }

    private func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f ms", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }

    /// One call of the real render callback on `bufferCount` stereo buffers of `frames` frames, pre-filled with 0xAA
    /// so untouched bytes would show, or with no data pointers at all. Returns every buffer's bytes, concatenated,
    /// and whether the call flagged them as silence.
    private func renderOnce(
        _ output: RemoteIOOutput, frames: Int, bufferCount: Int = 1, withData: Bool = true
    ) -> (bytes: [UInt8], silent: Bool) {
        let byteSize = frames * 2 * 4
        let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(list.unsafeMutablePointer) }
        var storage: [UnsafeMutableRawPointer] = []
        defer {
            for bytes in storage { bytes.deallocate() }
        }
        for i in 0..<bufferCount {
            var data: UnsafeMutableRawPointer?
            if withData {
                let bytes = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: 16)
                bytes.initializeMemory(as: UInt8.self, repeating: 0xAA, count: byteSize)
                storage.append(bytes)
                data = bytes
            }
            list[i] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(byteSize), mData: data)
        }
        var flags = AudioUnitRenderActionFlags()
        var timeStamp = AudioTimeStamp()
        let status = remoteIORender(
            output.renderRefCon, &flags, &timeStamp, 0, UInt32(frames), list.unsafeMutablePointer)
        #expect(status == noErr)
        let bytes = storage.flatMap { [UInt8](UnsafeRawBufferPointer(start: $0, count: byteSize)) }
        return (bytes, flags.contains(.unitRenderAction_OutputIsSilence))
    }

    /// A source holding `frames` stereo frames of distinct, non-zero words.
    private func filledSource(frames: Int) -> (source: RenderSource, bytes: [UInt8]) {
        let words = (0..<(frames * 2)).map { UInt32(0x0101_0101) &* UInt32($0 + 1) }
        let source = RenderSource(channels: 2, capacityFrames: 64, renderedFrames: 0, inheritingHoldsFrom: nil)
        #expect(words.withUnsafeBufferPointer { source.write($0) } == words.count)
        return (source, words.withUnsafeBytes { [UInt8]($0) })
    }

    // MARK: - Tests

    /// Spike S1 on the simulator: the real RemoteIO unit, the real audio session, the full pipeline. Captures are
    /// taken inside the render callback, so they prove what pointFlac hands the unit (and mute the speaker meanwhile).
    /// Serialized, and exclusive with other suites (`.audioHardware`): every test drives the one audio session and the
    /// output hardware.
    @Suite(.serialized, .audioOutputAvailable, .audioHardware) struct RemoteIOOutputTests {
        /// The suite's blocking AVAudioSession and AudioUnit calls run on `AudioHardwareQueue`, never on the
        /// cooperative pool, where on a 3-vCPU CI runner each one held a third of the pool for as long as it blocked.
        @Test func runsOnTheAudioHardwareQueue() async throws {
            #expect(AudioHardwareQueue.isCurrent, "test body")
            _ = try await activeSession()
            #expect(AudioHardwareQueue.isCurrent, "after activating the session")
            // As the pipeline calls `negotiateRate` (see `makePipeline`): from a detached task, which does not inherit
            // the suite's executor preference.
            let negotiation = await Task.detached {
                await withTaskExecutorPreference(AudioHardwareQueue.shared) { await isOnAudioHardwareQueue() }
            }.value
            #expect(negotiation, "a rate negotiation from the pipeline's detached task")
            #expect(await Task.detached { await isOnAudioHardwareQueue() }.value == false, "the check itself")
        }

        @Test func acceptsFloat32Client() async throws {
            let (_, rate) = try await activeSession()
            let output = try RemoteIOOutput()
            try output.configure(clientPlan(.float32, rate), channels: 2)
            let client = streamFormat(output, kAudioUnitScope_Input)
            let hardware = streamFormat(output, kAudioUnitScope_Output)
            #expect(isClientFormat(client, .float32, rate: rate, channels: 2), "client side: \(describe(client))")
            #expect(output.hardwareSideSampleRate == hardware.map { Int($0.mSampleRate) })
            #expect(output.hardwareSideChannels == hardware.map { Int($0.mChannelsPerFrame) })
            #expect(output.hardwareSideChannels ?? 0 > 0, "hardware side: \(describe(hardware))")
            #if !targetEnvironment(simulator)
                // Client rate == hardware rate, so RemoteIO has nothing to resample. The simulator's hardware side
                // stays at the Mac device's rate instead (`reportsHardwareSideRate`).
                #expect(output.hardwareSideSampleRate == rate, "hardware side: \(describe(hardware))")
            #endif
            print("S1: float32 accepted; client \(describe(client)); hardware \(describe(hardware))")
        }

        @Test func reportsInt32ClientSupport() async throws {
            let (_, rate) = try await activeSession()
            let output = try RemoteIOOutput()
            do {
                try output.configure(clientPlan(.int32, rate), channels: 2)
                let client = streamFormat(output, kAudioUnitScope_Input)
                let hardware = streamFormat(output, kAudioUnitScope_Output)
                #expect(isClientFormat(client, .int32, rate: rate, channels: 2), "client side: \(describe(client))")
                print("S1: int32 accepted; client \(describe(client)); hardware \(describe(hardware))")
            } catch AudioOutputError.formatRejected(let status) {
                print("S1: int32 rejected(\(status))")
            }
        }

        /// The rate on the unit's hardware side for each client rate the session gives. On a device the two must match:
        /// iOS never resamples silently. The simulator's hardware side stays at the Mac output device's rate whatever
        /// the session reports, so there the lines are the record of that S1 finding.
        @Test func reportsHardwareSideRate() async throws {
            let (session, _) = try await activeSession()
            for requested in [44_100, 96_000, 48_000] {
                let rate = await session.requestSampleRate(requested)
                let output = try RemoteIOOutput()
                try output.configure(clientPlan(.float32, rate), channels: 2)
                let hardware = try #require(output.hardwareSideSampleRate, "requested \(requested)")
                print("S1: hw-side \(hardware) for client \(rate)")
                #if !targetEnvironment(simulator)
                    #expect(hardware == rate, "requested \(requested): iOS resamples after the unit")
                #endif
            }
        }

        /// Default capabilities: Float32 for every depth, 32-bit sources TPDF-dithered to 24 bits first.
        @Test(arguments: ["s16-48000", "s24-48000", "s32-48000"])
        func capturedBytesMatchSource(_ requested: String) async throws {
            let (session, sessionRate) = try await activeSession()
            let name = fixture(requested, sessionRate: sessionRate)
            let f = Fixtures.named(name)
            let output = try RemoteIOOutput()
            let byteCount = Int(f.frames) * f.channels * 4
            // Twice the expected size, so extra frames would show up as a longer capture rather than be cut off.
            output.installCapture(byteCapacity: 2 * byteCount)

            let capabilities = OutputCapabilities.current
            let events = try #require(
                await playToEnd(name, through: output, session: session, capabilities: capabilities),
                "\(name): no queueEnded")
            let plan = try #require(firstPlan(events), "\(name): no planChanged in \(events)")
            let format = AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels)
            let wanted = OutputFormatPolicy.plan(source: format, hardwareRate: f.sampleRate, capabilities: capabilities)
            #expect(plan == wanted, "\(name): the hardware did not take \(f.sampleRate) Hz")
            #expect(plan.client == .float32 && plan.reduceTo24 == (f.bits > 24))
            #if !targetEnvironment(simulator)
                #expect(output.hardwareSideSampleRate == plan.clientSampleRate, "\(name): iOS resamples after the unit")
            #endif

            let captured = output.capturedBytes
            let expected = expectedBytes(Fixtures.rawSamples(f), bits: f.bits, plan: plan)
            #expect(expected.count == byteCount)
            #expect(mismatch(captured, expected) == nil, "\(name)")
            let hardwareSide = output.hardwareSideSampleRate.map(String.init) ?? "nil"
            print(
                "S1: capture \(name) client=\(plan.client) reduceTo24=\(plan.reduceTo24) bytes=\(captured.count) "
                    + "exact=\(captured == expected) hw-side=\(hardwareSide)")
        }

        /// Ruling 2: the Int32 client, when RemoteIO takes it, carries 32-bit samples exactly (b = 32, shift 0).
        /// When it refuses, `configure` must say so with `formatRejected`.
        @Test func int32PassthroughCaptureIsExact() async throws {
            let (session, sessionRate) = try await activeSession()
            let name = fixture("s32-48000", sessionRate: sessionRate)
            let f = Fixtures.named(name)
            let output = try RemoteIOOutput()
            let probe = Result { try output.configure(clientPlan(.int32, f.sampleRate), channels: f.channels) }
            if case .failure(let error) = probe {
                let rejected = if case AudioOutputError.formatRejected = error { true } else { false }
                #expect(rejected, "configure threw \(error), not formatRejected")
                print("S1: int32 passthrough \(name) not run: \(error)")
                return
            }
            let byteCount = Int(f.frames) * f.channels * 4
            output.installCapture(byteCapacity: 2 * byteCount)

            let events = try #require(
                await playToEnd(
                    name, through: output, session: session, capabilities: OutputCapabilities(int32Passthrough: true)),
                "\(name): no queueEnded")
            let plan = try #require(firstPlan(events), "\(name): no planChanged in \(events)")
            #expect(plan == clientPlan(.int32, f.sampleRate), "\(name): plan \(plan)")
            #if !targetEnvironment(simulator)
                #expect(output.hardwareSideSampleRate == plan.clientSampleRate, "\(name): iOS resamples after the unit")
            #endif

            let raw = Fixtures.rawSamples(f)
            let captured = output.capturedBytes
            let expected = raw.withUnsafeBytes { Data($0) }
            #expect(expected == expectedBytes(raw, bits: 32, plan: plan))
            #expect(mismatch(captured, expected) == nil, "\(name)")
            print("S1: int32 passthrough \(name) bytes=\(captured.count) exact=\(captured == expected)")
        }

        /// Ruling 7: the output's own latency (start → first real frames) and the spec budget end to end
        /// (`PlaybackPipeline.start` → first real frame rendered), both under 150 ms.
        @Test func firstRenderUnder150ms() async throws {
            let (session, sessionRate) = try await activeSession()
            let name = fixture("s24-48000", sessionRate: sessionRate)
            let f = Fixtures.named(name)
            let output = try RemoteIOOutput()
            output.installCapture(byteCapacity: 2 * Int(f.frames) * f.channels * 4)
            let pipeline = makePipeline(output, session: session, capabilities: .current)
            defer { pipeline.stop() }

            let requestedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            await pipeline.start([item(name)], at: 0, fromFrame: 0)
            #expect(await wait(upTo: .seconds(5)) { output.firstRenderLatency != nil }, "no real frame rendered")
            let latency = try #require(output.firstRenderLatency)
            let renderedAt = try #require(output.firstRealRenderUptimeNanos)
            let endToEnd = Duration.nanoseconds(Int64(renderedAt) - Int64(requestedAt))
            let budget = LatencyBudget.describe(.milliseconds(150))
            print("S1: firstRenderLatency=\(milliseconds(latency)) endToEnd=\(milliseconds(endToEnd)) \(budget)")
            #expect(
                latency < LatencyBudget.scaled(.milliseconds(150)), "first render \(milliseconds(latency)), \(budget)")
            #expect(
                endToEnd < LatencyBudget.scaled(.milliseconds(150)), "end to end \(milliseconds(endToEnd)), \(budget)")
        }

        /// Rulings 3, 5 and 6 at the callback itself, called directly on a stopped unit with rendering switched on by
        /// hand: with no source it plays flagged silence; without a capture the rendered audio reaches the unit; with
        /// one, only the real-frame prefix is captured, within its capacity, and the unit gets flagged silence.
        @Test func renderCallbackCapturesRealPrefixAndMutes() throws {
            let frames = 16
            let zeros = [UInt8](repeating: 0, count: frames * 2 * 4)

            let plain = try RemoteIOOutput()
            plain.renderingEnabled = true
            let idle = renderOnce(plain, frames: frames)
            #expect(idle.bytes == zeros && idle.silent, "no source")
            let (first, wordBytes) = filledSource(frames: 10)
            plain.source = first
            let playing = renderOnce(plain, frames: frames)
            #expect(playing.bytes == wordBytes + zeros.dropFirst(wordBytes.count) && !playing.silent, "no capture")
            let underrun = renderOnce(plain, frames: frames)
            #expect(underrun.bytes == zeros && underrun.silent, "empty ring")

            let capturing = try RemoteIOOutput()
            capturing.installCapture(byteCapacity: 4096)
            capturing.renderingEnabled = true
            let (source, _) = filledSource(frames: 10)
            capturing.source = source
            let muted = renderOnce(capturing, frames: frames)
            #expect(muted.bytes == zeros && muted.silent, "capture mode reaches the unit as silence")
            #expect(renderOnce(capturing, frames: frames).silent)
            #expect([UInt8](capturing.capturedBytes) == wordBytes, "real frames only, no underrun silence")
            #expect(source.renderedFrames == 10)

            let small = try RemoteIOOutput()
            small.installCapture(byteCapacity: 12)
            small.renderingEnabled = true
            small.source = filledSource(frames: 10).source
            _ = renderOnce(small, frames: frames)
            #expect([UInt8](small.capturedBytes) == Array(wordBytes.prefix(12)), "bounded by its capacity")
        }

        /// Review M-1: with the Sound chain at work, a call with no real frames can carry the chain's tail (its
        /// look-ahead ringing out into the gap), so it is not flagged as silence. With the runner in Pure it still is.
        @Test func renderCallbackLetsTheChainsTailThrough() throws {
            let frames = 16
            let calls = 8
            var flat = SoundSettings()
            flat.pure = false
            let chain = SoundChain(flat, sampleRate: 48_000, channels: 2)
            let latency = chain.latencyFrames
            #expect(latency + 10 <= frames * calls)
            let runner = ChainRunner()
            runner.reset(to: chain)
            let output = try RemoteIOOutput()
            output.renderingEnabled = true
            let words = (0..<20).map { UInt32(0x0101_0101) &* UInt32($0 + 1) }
            let source = RenderSource(
                channels: 2, capacityFrames: 64, renderedFrames: 0, inheritingHoldsFrom: nil, sound: runner)
            #expect(words.withUnsafeBufferPointer { source.write($0) } == words.count)
            output.source = source
            var played: [UInt8] = []
            for call in 0..<calls {
                let block = renderOnce(output, frames: frames)
                #expect(!block.silent, "call \(call): the chain is at work")
                played += block.bytes
            }
            // The ten frames, bit for bit (the chain's limiter is transparent below its ceiling), a latency late.
            let tail = Array(played[(latency * 8)..<((latency + 10) * 8)])
            #expect(tail == words.withUnsafeBytes { [UInt8]($0) }, "the tail reached the unit")
            #expect(source.renderedFrames == 10)

            // Pure: an empty ring is flagged silence again.
            runner.reset(to: nil)
            #expect(renderOnce(output, frames: frames).silent, "Pure, empty ring")
        }

        /// Every path on which the callback cannot or must not render: flagged silence in every buffer it was given,
        /// and the source and the capture left untouched.
        @Test func renderCallbackIsSilentWhenItCannotRender() throws {
            let frames = 16
            let zeros = [UInt8](repeating: 0, count: frames * 2 * 4)
            let output = try RemoteIOOutput()
            output.installCapture(byteCapacity: 4096)

            // Capture installed but no source: nothing to capture.
            output.renderingEnabled = true
            let sourceless = renderOnce(output, frames: frames)
            #expect(sourceless.bytes == zeros && sourceless.silent, "capture without a source")

            let (source, wordBytes) = filledSource(frames: 10)
            output.renderingEnabled = false
            output.source = source
            // Stopped: as a stopped unit's late callback would see it. A fresh unit starts disabled.
            let disabled = renderOnce(output, frames: frames)
            #expect(disabled.bytes == zeros && disabled.silent, "rendering disabled")
            #expect(try RemoteIOOutput().renderingEnabled == false)

            output.renderingEnabled = true
            let twoBuffers = renderOnce(output, frames: frames, bufferCount: 2)
            #expect(twoBuffers.bytes == zeros + zeros && twoBuffers.silent, "mNumberBuffers != 1")
            let noData = renderOnce(output, frames: frames, withData: false)
            #expect(noData.bytes.isEmpty && noData.silent, "nil mData")
            #expect(source.renderedFrames == 0, "the source was rendered from")
            #expect(output.capturedBytes.isEmpty, "something was captured")

            // The same source still renders once the callback can.
            #expect(renderOnce(output, frames: frames).silent)
            #expect([UInt8](output.capturedBytes) == wordBytes)
        }
    }
#endif
