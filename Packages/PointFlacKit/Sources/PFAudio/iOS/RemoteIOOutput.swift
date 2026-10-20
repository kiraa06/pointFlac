#if os(iOS)
    import AudioToolbox
    import Darwin
    import Foundation
    import PFCore
    import Synchronization

    /// pointFlac's iOS output: a RemoteIO unit pulling client-format audio from a `RenderSource` (spike S1).
    ///
    /// RemoteIO rather than AVAudioEngine: the engine's main mixer is Float32-only, so a 32-bit source could never
    /// reach the output as Int32. RemoteIO takes whichever client format pointFlac sets on its input scope, Float32 or
    /// signed Int32, and since the pipeline keeps the client rate equal to the hardware rate it has nothing to
    /// resample.
    ///
    /// ## Real-time safety
    /// The render callback is a `@convention(c)` function whose `inRefCon` is the output's `RenderContext`, unretained.
    /// Everything it touches is an atomic, preallocated memory or `RenderSource.render`, and it reaches the context,
    /// the source and the capture through unretained pointers. So it never allocates, locks, logs or causes
    /// retain/release traffic.
    ///
    /// ## Stopping, and swapping what the callback reads
    /// Each callback raises the context's in-flight count for its whole run, then checks the context's `enabled` flag
    /// before touching anything else. `stop()` clears that flag, calls `AudioOutputUnitStop`, and waits, bounded and
    /// with short sleeps, for the in-flight count to reach zero. When it returns:
    /// - no render call is in flight;
    /// - any callback that starts later outputs flagged silence and touches neither the source, the capture nor the
    ///   latency timestamps. That covers a callback the unit delivers after `AudioOutputUnitStop` returns, which is not
    ///   documented either way.
    ///
    /// So while stopped the pipeline may flush, replace or drop the source, and `start()` may reset its timestamps,
    /// without racing the render thread. Neither guarantee relies on `AudioOutputUnitStop` being synchronous. Setting
    /// `source` publishes the new pointer and waits the same way before releasing the old source, so a callback is
    /// never left holding a freed one. The waits are bounded at 2 s; past that, see `retire`.
    ///
    /// The owner serialises `configure`, `start`, `stop` and `source` (and, in DEBUG, `installCapture`), as the
    /// `AudioOutput` contract says. `firstRenderLatency` and, in DEBUG, `capturedBytes` read atomics, so they may be
    /// read while the unit runs.
    public final class RemoteIOOutput: AudioOutput {
        /// The RemoteIO instance. Internal so tests can read its stream formats back.
        let unit: AudioUnit
        private let context: RenderContext
        private var running = false
        /// The sample rate on the unit's hardware side (output scope, bus 0), read at the end of the last successful
        /// `configure`. On a device it should equal the plan's client rate; when it does not, iOS resamples after the
        /// unit, which pointFlac must never allow silently. On the simulator it is the Mac output device's rate,
        /// whatever the session reports (spike S1). Nil before a successful `configure`, or if the unit does not say.
        public private(set) var hardwareSideSampleRate: Int?
        /// The strong reference behind the context's unretained `source`.
        private var renderSource: RenderSource?
        #if DEBUG
            /// The strong reference behind the context's unretained `capture`.
            private var captureBuffer: CaptureBuffer?
        #endif

        /// Creates the RemoteIO unit and installs the render callback. The unit is initialised by `configure`.
        ///
        /// - Throws: `AudioOutputError.unitUnavailable` with the system's status, or with `kAudio_UnimplementedError`
        ///   if there is no RemoteIO component at all.
        public init() throws {
            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_RemoteIO,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw AudioOutputError.unitUnavailable(kAudio_UnimplementedError)
            }
            var instance: AudioComponentInstance?
            let created = AudioComponentInstanceNew(component, &instance)
            guard created == noErr, let instance else { throw AudioOutputError.unitUnavailable(created) }
            let context = RenderContext()
            var callback = AURenderCallbackStruct(
                inputProc: remoteIORender, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            let installed = AudioUnitSetProperty(
                instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard installed == noErr else {
                AudioComponentInstanceDispose(instance)
                throw AudioOutputError.unitUnavailable(installed)
            }
            unit = instance
            self.context = context
        }

        deinit {
            context.enabled.store(false, ordering: .sequentiallyConsistent)
            AudioOutputUnitStop(unit)
            // Like `retire`: should a render call still be in flight, leak everything it can read unretained (the
            // context, the source and the capture) rather than free it under it.
            if !waitForRenderCalls() {
                _ = Unmanaged.passRetained(context)
                if let renderSource {
                    _ = Unmanaged.passRetained(renderSource)
                }
                #if DEBUG
                    if let captureBuffer {
                        _ = Unmanaged.passRetained(captureBuffer)
                    }
                #endif
            }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }

        /// Set only while stopped (the `AudioOutput` contract). The callback sees the new value from its next call. The
        /// old source is released only once no render call that may still be using it is in flight.
        public var source: RenderSource? {
            get { renderSource }
            set {
                assert(!running, "RemoteIOOutput.source set while started")
                let old = renderSource
                renderSource = newValue
                context.source.store(newValue.map { .passUnretained($0) }, ordering: .sequentiallyConsistent)
                retire(old)
            }
        }

        /// Sets the client format, the side pointFlac renders into (input scope, bus 0): interleaved, packed,
        /// native-endian Float32 or signed Int32, 32 bits per sample, `channels` wide, at `plan.clientSampleRate`.
        /// Then initialises the unit with it.
        ///
        /// Called while stopped; a running unit is stopped first.
        ///
        /// - Throws: `AudioOutputError.formatRejected` with the unit's status if it refuses the format, or refuses to
        ///   initialise with it.
        public func configure(_ plan: OutputPlan, channels: Int) throws {
            precondition(channels > 0, "RemoteIOOutput needs at least one channel")
            stop()
            hardwareSideSampleRate = nil
            // Harmless before the first `configure`. The stream format can only change on an uninitialised unit.
            AudioUnitUninitialize(unit)
            let bytesPerFrame = UInt32(channels * MemoryLayout<UInt32>.size)
            let kind = plan.client == .float32 ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
            var format = AudioStreamBasicDescription(
                mSampleRate: Double(plan.clientSampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kind | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            let set = AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            guard set == noErr else { throw AudioOutputError.formatRejected(set) }
            let initialised = AudioUnitInitialize(unit)
            guard initialised == noErr else { throw AudioOutputError.formatRejected(initialised) }
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let read = AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hardware, &size)
            if read == noErr, hardware.mSampleRate > 0 {
                hardwareSideSampleRate = Int(hardware.mSampleRate.rounded())
            }
        }

        /// Starts the unit. `firstRenderLatency` is measured afresh from here.
        ///
        /// - Throws: `AudioOutputError.startFailed` with the unit's status.
        public func start() throws {
            guard !running else { return }
            // Rendering is disabled until the store below, so no callback writes these meanwhile.
            context.firstRealAt.store(0, ordering: .relaxed)
            context.startedAt.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
            context.enabled.store(true, ordering: .sequentiallyConsistent)
            let status = AudioOutputUnitStart(unit)
            guard status == noErr else {
                stop()
                throw AudioOutputError.startFailed(status)
            }
            running = true
        }

        /// Stops the unit. Returns only once no render call is in flight, and from then on any callback outputs flagged
        /// silence without touching the source (see the class notes).
        public func stop() {
            context.enabled.store(false, ordering: .sequentiallyConsistent)
            if running {
                AudioOutputUnitStop(unit)
                running = false
            }
            waitForRenderCalls()
        }

        /// From the latest `start()` to the first render callback after it that delivered real frames rather than
        /// underrun silence. Nil until such a callback has run.
        public var firstRenderLatency: Duration? {
            guard let first = firstRealRenderUptimeNanos else { return nil }
            let started = context.startedAt.load(ordering: .acquiring)
            return .nanoseconds(Int64(first) - Int64(started))
        }

        /// `CLOCK_UPTIME_RAW` nanoseconds at that first real-frame callback, for end-to-end measurements.
        var firstRealRenderUptimeNanos: UInt64? {
            let first = context.firstRealAt.load(ordering: .acquiring)
            return first == 0 ? nil : first
        }

        /// The `inRefCon` the unit passes to `remoteIORender`. Internal so tests can call the callback directly while
        /// the unit is stopped, which makes them its only caller.
        var renderRefCon: UnsafeMutableRawPointer {
            Unmanaged.passUnretained(context).toOpaque()
        }

        /// Whether the callback renders: `start()` sets it and `stop()` clears it. Internal so tests can call the
        /// callback directly on a stopped unit, both ways.
        var renderingEnabled: Bool {
            get { context.enabled.load(ordering: .sequentiallyConsistent) }
            set { context.enabled.store(newValue, ordering: .sequentiallyConsistent) }
        }

        #if DEBUG
            /// Debug and tests only. From now on the render callback copies the real frames it renders into a buffer
            /// of `byteCapacity` bytes allocated here, and drops what no longer fits. Only the real-frame prefix that
            /// `RenderSource.render` reports is copied, never underrun or hold silence, so a capture does not depend on
            /// timing. Replaces any earlier capture. Call while stopped, as for `source`.
            ///
            /// Capture mode **mutes the output**: after copying, the callback zeroes the buffer it hands back to
            /// RemoteIO and flags it as silence, so test runs do not play full-scale test signals through the
            /// speakers. Verification is unaffected: the copy is taken before the unit, of exactly what pointFlac
            /// handed it.
            func installCapture(byteCapacity: Int) {
                assert(!running, "RemoteIOOutput.installCapture while started")
                let buffer = CaptureBuffer(byteCapacity: byteCapacity)
                let old = captureBuffer
                captureBuffer = buffer
                context.capture.store(.passUnretained(buffer), ordering: .sequentiallyConsistent)
                retire(old)
            }

            /// The bytes captured since `installCapture`, in render order. Empty without a capture.
            var capturedBytes: Data {
                captureBuffer?.bytes ?? Data()
            }
        #endif

        /// Releases `object`, which the callback may have been reading unretained, once no render call is in flight.
        /// Should one stay in flight past the bound, `object` is leaked instead: a leak is survivable, a use-after-free
        /// on the render thread is not.
        private func retire(_ object: AnyObject?) {
            guard let object, !waitForRenderCalls() else { return }
            _ = Unmanaged.passRetained(object)
        }

        /// Waits, with short sleeps, until no render call is in flight. Returns false if one is still running after
        /// two seconds; a render call takes well under a millisecond, so that means something is badly wrong.
        ///
        /// Why a callback cannot slip past: the count, `enabled` and the published pointers are all sequentially
        /// consistent, and a callback raises the count before it reads any of them. So once `enabled` is cleared or a
        /// new pointer is stored, a callback that saw the old value is still counted until it returns. A callback that
        /// starts after that sees the new value.
        @discardableResult
        private func waitForRenderCalls() -> Bool {
            let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 2_000_000_000
            while context.inFlight.load(ordering: .sequentiallyConsistent) != 0 {
                guard clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline else {
                    assertionFailure("RemoteIOOutput: a render call is still in flight after 2 s")
                    return false
                }
                usleep(100)
            }
            return true
        }
    }

    // MARK: - Render path

    /// What the render callback reaches through `inRefCon`. Shared with `RemoteIOOutput`, which updates it from its own
    /// thread, so every field is an atomic.
    private final class RenderContext {
        /// Render calls running right now: raised on entry, lowered on return.
        let inFlight = Atomic<Int>(0)
        /// Set by `start()`, cleared by `stop()`. While clear, a callback outputs flagged silence and touches nothing
        /// else.
        let enabled = Atomic<Bool>(false)
        /// The source to render from, unretained (`RemoteIOOutput.source` holds it). Nil plays silence.
        let source = Atomic<Unmanaged<RenderSource>?>(nil)
        /// `CLOCK_UPTIME_RAW` nanoseconds at the latest `start()`.
        let startedAt = Atomic<UInt64>(0)
        /// The same clock at the first callback since then that delivered real frames; 0 until one has. Written only
        /// by the callback, and by `start()` while rendering is disabled.
        let firstRealAt = Atomic<UInt64>(0)
        #if DEBUG
            /// The capture, unretained (`RemoteIOOutput` holds it). Nil: no capture, and the audio reaches the unit.
            let capture = Atomic<Unmanaged<CaptureBuffer>?>(nil)
        #endif

        /// One render call. Real-time safe: atomics, `memset`, `memcpy` and `RenderSource.render` only.
        func render(
            _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, frames: Int,
            _ ioData: UnsafeMutablePointer<AudioBufferList>?
        ) {
            inFlight.wrappingAdd(1, ordering: .sequentiallyConsistent)
            defer { inFlight.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
            guard let ioData else { return }
            let buffers = Self.buffers(of: ioData)
            let bufferCount = Int(ioData.pointee.mNumberBuffers)
            // Stopped (or stopping): silence, without reading the source, the capture or the timestamps.
            guard enabled.load(ordering: .sequentiallyConsistent) else {
                Self.silence(buffers, count: bufferCount, flags)
                return
            }
            // The client format is interleaved, so there is exactly one buffer.
            guard bufferCount == 1, let data = buffers[0].mData,
                let current = source.load(ordering: .sequentiallyConsistent)
            else {
                Self.silence(buffers, count: bufferCount, flags)
                return
            }
            let byteSize = Int(buffers[0].mDataByteSize)
            let realBytes = current._withUnsafeGuaranteedRef { rendering in
                let bytesPerFrame = rendering.channels * MemoryLayout<UInt32>.size
                let fit = min(frames, byteSize / bytesPerFrame)
                let real = rendering.render(into: data, frames: fit)
                // `render` zero-filled its `fit` frames after the real ones; clear anything the buffer has beyond.
                let used = fit * bytesPerFrame
                if used < byteSize {
                    memset(data + used, 0, byteSize - used)
                }
                return real * bytesPerFrame
            }
            if realBytes > 0, firstRealAt.load(ordering: .relaxed) == 0 {
                firstRealAt.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .releasing)
            }
            #if DEBUG
                if let activeCapture = capture.load(ordering: .sequentiallyConsistent) {
                    activeCapture._withUnsafeGuaranteedRef { $0.append(data, byteCount: realBytes) }
                    // Muted: the capture already holds what pointFlac handed the unit.
                    Self.silence(buffers, count: bufferCount, flags)
                    return
                }
            #endif
            if realBytes == 0 {
                flags.pointee.insert(.unitRenderAction_OutputIsSilence)
            }
        }

        /// The list's `mBuffers` flexible array: one past the list, whose struct holds the first buffer, less one
        /// buffer. This is how `UnsafeMutableAudioBufferListPointer` finds it too, but that type lives in a resilient
        /// overlay, so using it on this thread meant runtime calls (its type metadata accessor, `count`, a subscript
        /// coroutine) and a dynamically sized stack slot. Plain pointer arithmetic needs none of them.
        private static func buffers(
            of list: UnsafeMutablePointer<AudioBufferList>
        ) -> UnsafeMutablePointer<AudioBuffer> {
            UnsafeMutableRawPointer(list + 1).assumingMemoryBound(to: AudioBuffer.self) - 1
        }

        /// Zeroes all `count` buffers and tells the unit the output is silent.
        private static func silence(
            _ buffers: UnsafeMutablePointer<AudioBuffer>, count: Int,
            _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>
        ) {
            for i in 0..<count {
                if let data = buffers[i].mData {
                    memset(data, 0, Int(buffers[i].mDataByteSize))
                }
            }
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
        }
    }

    /// RemoteIO's render callback, on its real-time thread. `inRefCon` is the output's `RenderContext`, unretained:
    /// `RemoteIOOutput` owns the context and disposes of the unit before releasing it. Internal for tests, which call
    /// it with `RemoteIOOutput.renderRefCon` while the unit is stopped.
    func remoteIORender(
        _ inRefCon: UnsafeMutableRawPointer, _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ inBusNumber: UInt32, _ inNumberFrames: UInt32,
        _ ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        Unmanaged<RenderContext>.fromOpaque(inRefCon)._withUnsafeGuaranteedRef {
            $0.render(ioActionFlags, frames: Int(inNumberFrames), ioData)
        }
        return noErr
    }

    #if DEBUG
        /// Preallocated memory the render callback copies into; see `RemoteIOOutput.installCapture(byteCapacity:)`.
        private final class CaptureBuffer {
            private let base: UnsafeMutableRawPointer
            private let capacity: Int
            /// Bytes captured so far. Advanced only by the render callback.
            private let filled = Atomic<Int>(0)

            init(byteCapacity: Int) {
                capacity = max(byteCapacity, 0)
                base = .allocate(byteCount: max(byteCapacity, 1), alignment: 16)
            }

            deinit {
                base.deallocate()
            }

            /// Render thread: a bounds-checked copy of as much of `bytes` as still fits. The rest is dropped.
            func append(_ bytes: UnsafeRawPointer, byteCount: Int) {
                let used = filled.load(ordering: .relaxed)
                let count = min(byteCount, capacity - used)
                guard count > 0 else { return }
                memcpy(base + used, bytes, count)
                filled.store(used + count, ordering: .releasing)
            }

            var bytes: Data {
                Data(bytes: base, count: filled.load(ordering: .acquiring))
            }
        }
    #endif
#endif
