#if os(iOS)
    import AVFoundation
    import Foundation
    import PFCore
    import Synchronization

    /// The real `AVAudioSession`, configured for long-form playback.
    ///
    /// Checked `Sendable`: the only mutable state is the observer tokens, behind a `Mutex`. `AVAudioSession` itself
    /// is a process-wide singleton read on demand, never stored.
    public final class SystemAudioSession: AudioSessionControlling {
        /// Single consumer (the player). Created once; finished in `deinit`.
        public let events: AsyncStream<SessionEvent>
        private let continuation: AsyncStream<SessionEvent>.Continuation

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
                    if let event { continuation.yield(event) }
                })

            // After a reset the owner must set the category again and reactivate; that is the player's job.
            tokens.append(
                center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil)
                {
                    @Sendable _ in
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

        public func activate() async throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        }

        /// Deactivates, sets the preferred rate, reactivates, then reads the hardware rate back.
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
            do {
                try session.setActive(false)
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
            } catch {
                // Nothing more to do; the read-back below reports what the session has.
            }
            return Int(session.sampleRate)
        }

        public var currentPort: OutputPort { Self.readCurrentPort() }
        public var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }
        public var sampleRate: Int { Int(AVAudioSession.sharedInstance().sampleRate) }

        private static func readCurrentPort() -> OutputPort {
            guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return .other("") }
            return OutputPort(portType: port.portType.rawValue, name: port.portName)
        }
    }
#endif
