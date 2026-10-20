#if os(iOS)
    import AVFoundation
    import AudioToolbox
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

    private func makePipeline(
        _ output: RemoteIOOutput, session: SystemAudioSession, capabilities: OutputCapabilities
    ) -> PlaybackPipeline {
        PlaybackPipeline(
            output: output, capabilities: capabilities, negotiateRate: { await session.requestSampleRate($0) },
            makeDecoder: { try FlacDecoder(url: $0.url) }, ditherSeed: ditherSeed)
    }

    /// Waits until `condition` holds or `timeout` passes, and returns whether it held.
    private func wait(upTo timeout: Duration, for condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
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

    /// One call of the real render callback on a buffer pre-filled with 0xAA, so untouched bytes would show. Returns
    /// the bytes the unit would get and whether the call flagged them as silence.
    private func renderOnce(_ output: RemoteIOOutput, frames: Int) -> (bytes: [UInt8], silent: Bool) {
        let byteSize = frames * 2 * 4
        let data = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: 16)
        defer { data.deallocate() }
        data.initializeMemory(as: UInt8.self, repeating: 0xAA, count: byteSize)
        var list = AudioBufferList(
            mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(byteSize), mData: data))
        var flags = AudioUnitRenderActionFlags()
        var timeStamp = AudioTimeStamp()
        let status = remoteIORender(output.renderRefCon, &flags, &timeStamp, 0, UInt32(frames), &list)
        #expect(status == noErr)
        let bytes = [UInt8](UnsafeRawBufferPointer(start: data, count: byteSize))
        return (bytes, flags.contains(.unitRenderAction_OutputIsSilence))
    }

    // MARK: - Tests

    /// Spike S1 on the simulator: the real RemoteIO unit, the real audio session, the full pipeline. Captures are
    /// taken inside the render callback, so they prove what pointFlac hands the unit (and mute the speaker meanwhile).
    /// Serialized, and exclusive with other suites (`.audioHardware`): every test drives the one audio session and the
    /// output hardware.
    @Suite(.serialized, .audioHardware) struct RemoteIOOutputTests {
        @Test func acceptsFloat32Client() async throws {
            let (_, rate) = try await activeSession()
            let output = try RemoteIOOutput()
            try output.configure(clientPlan(.float32, rate), channels: 2)
            let client = streamFormat(output, kAudioUnitScope_Input)
            let hardware = streamFormat(output, kAudioUnitScope_Output)
            #expect(isClientFormat(client, .float32, rate: rate, channels: 2), "client side: \(describe(client))")
            #if targetEnvironment(simulator)
                // The simulator's hardware side is the Mac's output device (48 kHz Float32 here) whatever rate the
                // session reports, so it resamples anything else itself (an S1 finding, in the spike doc).
            #else
                // Client rate == hardware rate, so RemoteIO has nothing to resample.
                #expect(hardware?.mSampleRate == Double(rate), "hardware side: \(describe(hardware))")
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

            let captured = output.capturedBytes
            let expected = expectedBytes(Fixtures.rawSamples(f), bits: f.bits, plan: plan)
            #expect(expected.count == byteCount)
            #expect(mismatch(captured, expected) == nil, "\(name)")
            print(
                "S1: capture \(name) client=\(plan.client) reduceTo24=\(plan.reduceTo24) bytes=\(captured.count) "
                    + "exact=\(captured == expected)")
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
            print("S1: firstRenderLatency=\(milliseconds(latency)) endToEnd=\(milliseconds(endToEnd))")
            #expect(latency < .milliseconds(150))
            #expect(endToEnd < .milliseconds(150))
        }

        /// Rulings 3, 5 and 6 at the callback itself, called directly while the unit is stopped: with no source it
        /// plays flagged silence; without a capture the rendered audio reaches the unit; with one, only the real-frame
        /// prefix is captured, within its capacity, and the unit gets flagged silence.
        @Test func renderCallbackCapturesRealPrefixAndMutes() throws {
            let frames = 16
            let realFrames = 10
            let words = (0..<(realFrames * 2)).map { UInt32(0x0101_0101) &* UInt32($0 + 1) }
            let wordBytes = words.withUnsafeBytes { [UInt8]($0) }
            let zeros = [UInt8](repeating: 0, count: frames * 2 * 4)
            func filledSource() -> RenderSource {
                let source = RenderSource(channels: 2, capacityFrames: 64, renderedFrames: 0, inheritingHoldsFrom: nil)
                #expect(words.withUnsafeBufferPointer { source.write($0) } == words.count)
                return source
            }

            let plain = try RemoteIOOutput()
            let idle = renderOnce(plain, frames: frames)
            #expect(idle.bytes == zeros && idle.silent, "no source")
            plain.source = filledSource()
            let playing = renderOnce(plain, frames: frames)
            #expect(playing.bytes == wordBytes + zeros.dropFirst(wordBytes.count) && !playing.silent, "no capture")
            let underrun = renderOnce(plain, frames: frames)
            #expect(underrun.bytes == zeros && underrun.silent, "empty ring")

            let capturing = try RemoteIOOutput()
            capturing.installCapture(byteCapacity: 4096)
            let source = filledSource()
            capturing.source = source
            let muted = renderOnce(capturing, frames: frames)
            #expect(muted.bytes == zeros && muted.silent, "capture mode reaches the unit as silence")
            #expect(renderOnce(capturing, frames: frames).silent)
            #expect([UInt8](capturing.capturedBytes) == wordBytes, "real frames only, no underrun silence")
            #expect(source.renderedFrames == Int64(realFrames))

            let small = try RemoteIOOutput()
            small.installCapture(byteCapacity: 12)
            small.source = filledSource()
            _ = renderOnce(small, frames: frames)
            #expect([UInt8](small.capturedBytes) == Array(wordBytes.prefix(12)), "bounded by its capacity")
        }
    }
#endif
