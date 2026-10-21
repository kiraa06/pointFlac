#if os(iOS)
    import AVFoundation
    import Dispatch
    import PFCore
    import Testing

    @testable import PFAudio

    /// Runs a suite while it holds the one process-wide lock on the real audio session and output hardware, with
    /// `AudioHardwareQueue` as its task executor.
    ///
    /// `AVAudioSession` is a process singleton, and suites run in parallel. Without the lock one suite's rate request
    /// lands in the middle of another's negotiation or capture: `RemoteIOOutputTests` was seen reading the rate that
    /// `SystemAudioSessionTests` had just set. `.serialized` only orders the tests within one suite, so every suite that
    /// drives the real session also takes this trait.
    ///
    /// The executor preference moves the suite's nonisolated async code off the cooperative pool and onto the queue:
    /// the test bodies, the blocking `AVAudioSession` calls inside `SystemAudioSession`'s async methods, and the
    /// AudioUnit work of `RemoteIOOutput`, including its teardown when a test's last reference goes. A per-call
    /// continuation could not reach those, because they sit inside async APIs and deinits.
    struct AudioHardwareTrait: SuiteTrait, TestScoping {
        func provideScope(
            for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
        ) async throws {
            await AudioHardwareLock.shared.acquire()
            do {
                try await withTaskExecutorPreference(AudioHardwareQueue.shared) { try await function() }
            } catch {
                await AudioHardwareLock.shared.release()
                throw error
            }
            await AudioHardwareLock.shared.release()
        }
    }

    extension Trait where Self == AudioHardwareTrait {
        /// Exclusive use of the real audio session and output hardware for the whole suite, on `AudioHardwareQueue`.
        static var audioHardware: Self { Self() }
    }

    extension Trait where Self == ConditionTrait {
        /// Runs only where `AudioHardwareAvailability` finds working audio output; otherwise skipped with a reason.
        static var audioOutputAvailable: Self {
            .enabled("no usable audio output on this machine") { await AudioHardwareAvailability.isAvailable() }
        }
    }

    /// The one serial queue the tests' real audio hardware work runs on, so it never blocks the cooperative pool.
    ///
    /// `AVAudioSession` and AudioUnit calls are synchronous and can block for seconds: on the first GitHub run, one
    /// test's activation and unit setup took 12.6 s on the simulator (locally under 30 ms). The pool is as wide as the
    /// CPU count, 3 on a GitHub macOS runner, and every suite running in parallel shares it, along with the player's
    /// rate negotiations. Here the caller's task suspends instead, and its pool thread goes back to the other suites.
    ///
    /// Two ways in: `run(_:)` for a synchronous body, bridged back with a checked continuation, and the queue as a
    /// `TaskExecutor`, which `AudioHardwareTrait` and `withTaskExecutorPreference` use for async code.
    final class AudioHardwareQueue: TaskExecutor {
        static let shared = AudioHardwareQueue()

        private static let label = "io.github.kiraa06.pointflac.tests.audio-hardware"
        private let queue = DispatchQueue(label: AudioHardwareQueue.label, qos: .userInitiated)

        /// Whether the caller is running on this queue, and so not on a cooperative-pool thread.
        static var isCurrent: Bool {
            String(cString: __dispatch_queue_get_label(nil)) == label
        }

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            let executor = asUnownedTaskExecutor()
            queue.async { job.runSynchronously(on: executor) }
        }

        /// Runs the blocking `body` on the queue and returns its result. The calling task suspends meanwhile.
        func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: body()) }
            }
        }
    }

    /// Whether this machine can run real audio output: the session activates, and a RemoteIO unit can be created,
    /// initialised and started, then stopped, with the speaker muted. Probed once, under `AudioHardwareLock`, so it
    /// cannot interleave with a suite that already holds the hardware, and on `AudioHardwareQueue`, never on the
    /// cooperative pool. Hosted CI runners may have no output device; the suites that need one skip there instead of
    /// failing. Anywhere with a device, including a developer's Mac, the suites run.
    ///
    /// Swift Testing evaluates the condition while planning the run, before any test starts, so a slow probe delays
    /// the run's start rather than any one test.
    enum AudioHardwareAvailability {
        private static let probe = Task<String?, Never> {
            await AudioHardwareLock.shared.acquire()
            let reason = await AudioHardwareQueue.shared.run { run() }
            await AudioHardwareLock.shared.release()
            if let reason { print("audio hardware unavailable, skipping hardware suites: \(reason)") }
            return reason
        }

        /// Nil when audio output works, else why not. Blocks; runs on `AudioHardwareQueue`.
        private static func run() -> String? {
            do {
                // What `SystemAudioSession.activate()` does, called directly because that method is async.
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                try session.setActive(true)
                let rate = Int(session.sampleRate)
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
