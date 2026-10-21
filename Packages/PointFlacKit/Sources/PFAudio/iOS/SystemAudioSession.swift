#if os(iOS)
    import AVFoundation
    import Foundation
    import PFCore
    import Synchronization

    /// The real `AVAudioSession`, configured for long-form playback.
    ///
    /// Checked `Sendable`: the mutable state is the observer tokens, behind a `Mutex`, and `SessionActivity`'s
    /// atomics. `AVAudioSession` itself is a process-wide singleton read on demand, never stored.
    public final class SystemAudioSession: AudioSessionControlling {
        /// Single consumer (the player). Created once; finished in `deinit`.
        public let events: AsyncStream<SessionEvent>
        private let continuation: AsyncStream<SessionEvent>.Continuation
        private let activity = SessionActivity()

        /// Observer tokens and the KVO handle, held in a `Mutex`, touched only in `init` and `deinit`.
        /// `@unchecked Sendable` is forced: without it the iOS build fails with "'inout sending' parameter '$0'
        /// cannot be task-isolated at end of function" where `init` assigns the non-Sendable `NSObjectProtocol` tokens
        /// and `NSKeyValueObservation` inside `withLock`.
        private struct Observers: @unchecked Sendable {
            var tokens: [any NSObjectProtocol] = []
            var volume: NSKeyValueObservation?
        }
        private let observers = Mutex(Observers())

        public init() {
            let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
            self.events = stream
            self.continuation = continuation

            let center = NotificationCenter.default
            let session = AVAudioSession.sharedInstance()
            let activity = activity
            var tokens: [any NSObjectProtocol] = []

            tokens.append(
                center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) {
                    @Sendable note in
                    let reason = RouteChangeReason(
                        routeChangeRawValue: note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    continuation.yield(.routeChanged(reason, Self.readCurrentPort()))
                })

            tokens.append(
                center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) {
                    @Sendable note in
                    let info = note.userInfo
                    let event = SessionEvent.interruption(
                        typeRawValue: info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                        optionsRawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    // The system has deactivated the session for the interruption.
                    if event == .interruptionBegan { activity.isActive.store(false, ordering: .releasing) }
                    if let event { continuation.yield(event) }
                })

            // After a reset the owner must set the category again and reactivate; that is the player's job.
            tokens.append(
                center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil)
                {
                    @Sendable _ in
                    activity.isActive.store(false, ordering: .releasing)
                    continuation.yield(.mediaServicesReset)
                })

            let volume = session.observe(\.outputVolume, options: [.new]) { @Sendable _, change in
                if let value = change.newValue { continuation.yield(.volumeChanged(value)) }
            }
            observers.withLock {
                $0.tokens = tokens
                $0.volume = volume
            }
        }

        deinit {
            let (tokens, volume) = observers.withLock { ($0.tokens, $0.volume) }
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            volume?.invalidate()
            continuation.finish()
        }

        /// Sets the category and, when given, the preferred rate, then activates. Setting the rate before activation is
        /// what lets a first play come up at the file's rate without a deactivate and reactivate cycle afterwards. A
        /// refused preferred rate is not fatal: the session activates at whatever rate the hardware picks, and the
        /// pipeline's read-back sees it.
        public func activate(preferredRate: Int?) async throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            if let preferredRate {
                try? session.setPreferredSampleRate(Double(preferredRate))
            }
            try session.setActive(true)
            activity.isActive.store(true, ordering: .releasing)
        }

        /// Reads the hardware rate back and returns it, after deactivating, setting the preferred rate and
        /// reactivating, unless the active session already runs at `hz`. Then nothing is touched: a cycle would cost
        /// tens of milliseconds and post route changes for no change (final review I6).
        ///
        /// The read-back rate is returned on every path, including when a step throws: it is whatever the hardware
        /// runs at, and the pipeline resamples to it. Returning `hz` instead would claim a rate the hardware may not
        /// have. An inactive session can read back 0.
        ///
        /// Threading: despite `async`, every AVAudioSession call here is synchronous and may block for tens to
        /// hundreds of milliseconds, occupying the calling thread. That is acceptable for a rare per-track call. The
        /// caller must have stopped the output first (the pipeline does); otherwise `setActive(false)` throws a busy
        /// error and the rate does not change, though the read-back keeps the result correct.
        public func requestSampleRate(_ hz: Int) async -> Int {
            let session = AVAudioSession.sharedInstance()
            let running = Int(session.sampleRate)
            if running == hz, activity.isActive.load(ordering: .acquiring) {
                // iOS can deactivate a suspended app's session without an interruption notification, which
                // `isActive` cannot see. Re-asserting activation is idempotent and posts no route change.
                try? session.setActive(true)
                return Int(session.sampleRate)
            }
            do {
                try session.setActive(false)
                activity.isActive.store(false, ordering: .releasing)
                activity.deactivations.add(1, ordering: .relaxed)
            } catch {
                // Still active (busy output): the preferred rate cannot take effect. Read back what is running.
                return Int(session.sampleRate)
            }
            // Deactivation succeeded, so reactivation must be attempted even if setting the preferred rate fails.
            // Otherwise the session would stay inactive while playback continues, and the read-back would come from
            // an inactive session.
            do {
                try session.setPreferredSampleRate(Double(hz))
            } catch {
                // Not fatal: reactivate at whatever rate the hardware picks.
            }
            do {
                try session.setActive(true)
                activity.isActive.store(true, ordering: .releasing)
            } catch {
                // Nothing more to do; the read-back below reports what the session has.
            }
            return Int(session.sampleRate)
        }

        /// Whether this object last left the session active: a successful activation sets it; a deactivation, an
        /// interruption (the system deactivates the session) and a media-services reset clear it. Internal for tests.
        var isActive: Bool { activity.isActive.load(ordering: .acquiring) }

        /// Deactivations `requestSampleRate` has made so far. Internal for tests, which prove it short-circuits.
        var deactivations: Int { activity.deactivations.load(ordering: .relaxed) }

        public var currentPort: OutputPort { Self.readCurrentPort() }
        public var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }
        public var sampleRate: Int { Int(AVAudioSession.sharedInstance().sampleRate) }

        private static func readCurrentPort() -> OutputPort {
            guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return .other("") }
            return OutputPort(portType: port.portType.rawValue, name: port.portName)
        }
    }

    /// What `SystemAudioSession` knows of the session's activity, shared with its notification observers.
    /// AVAudioSession has no public "is active" query, so the session object tracks what it did and what the system
    /// told it.
    private final class SessionActivity: Sendable {
        let isActive = Atomic<Bool>(false)
        let deactivations = Atomic<Int>(0)
    }
#endif
