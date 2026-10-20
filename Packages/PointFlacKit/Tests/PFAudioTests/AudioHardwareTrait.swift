#if os(iOS)
    import AVFoundation
    import PFCore
    import Testing

    @testable import PFAudio

    /// Runs a suite while it holds the one process-wide lock on the real audio session and output hardware.
    ///
    /// `AVAudioSession` is a process singleton, and suites run in parallel. Without the lock one suite's rate request
    /// lands in the middle of another's negotiation or capture: `RemoteIOOutputTests` was seen reading the rate that
    /// `SystemAudioSessionTests` had just set. `.serialized` only orders the tests within one suite, so every suite that
    /// drives the real session also takes this trait.
    struct AudioHardwareTrait: SuiteTrait, TestScoping {
        func provideScope(
            for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
        ) async throws {
            await AudioHardwareLock.shared.acquire()
            do {
                try await function()
            } catch {
                await AudioHardwareLock.shared.release()
                throw error
            }
            await AudioHardwareLock.shared.release()
        }
    }

    extension Trait where Self == AudioHardwareTrait {
        /// Exclusive use of the real audio session and output hardware for the whole suite.
        static var audioHardware: Self { Self() }
    }

    extension Trait where Self == ConditionTrait {
        /// Runs only where `AudioHardwareAvailability` finds working audio output; otherwise skipped with a reason.
        static var audioOutputAvailable: Self {
            .enabled("no usable audio output on this machine") { await AudioHardwareAvailability.isAvailable() }
        }
    }

    /// Whether this machine can run real audio output: a RemoteIO unit can be created, initialised and started, then
    /// stopped, with the speaker muted. Probed once, under `AudioHardwareLock`, so it cannot interleave with a suite
    /// that already holds the hardware. Hosted CI runners may have no output device; the suites that need one skip
    /// there instead of failing. Anywhere with a device, including a developer's Mac, the suites run.
    enum AudioHardwareAvailability {
        private static let probe = Task<String?, Never> {
            await AudioHardwareLock.shared.acquire()
            let reason = await run()
            await AudioHardwareLock.shared.release()
            if let reason { print("audio hardware unavailable, skipping hardware suites: \(reason)") }
            return reason
        }

        /// Nil when audio output works, else why not.
        private static func run() async -> String? {
            do {
                let session = SystemAudioSession()
                try await session.activate()
                let rate = Int(AVAudioSession.sharedInstance().sampleRate)
                let output = try RemoteIOOutput()
                #if DEBUG
                    output.installCapture(byteCapacity: 4096)  // mutes the speaker
                #endif
                let plan = OutputPlan(client: .float32, clientSampleRate: rate, resample: nil, reduceTo24: false)
                try output.configure(plan, channels: 2)
                try output.start()
                output.stop()
                return nil
            } catch {
                return "\(error)"
            }
        }

        static func isAvailable() async -> Bool {
            await probe.value == nil
        }
    }

    /// A first-come, first-served async lock.
    actor AudioHardwareLock {
        static let shared = AudioHardwareLock()
        private var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard held else {
                held = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Hands the lock straight to the longest waiter, if any.
        func release() {
            if waiters.isEmpty {
                held = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }
#endif
