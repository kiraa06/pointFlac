#if os(iOS)
    import Testing

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

    /// A first-come, first-served async lock.
    private actor AudioHardwareLock {
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
