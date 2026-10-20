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

        /// Observer tokens and the KVO handle. Neither `NSObjectProtocol` nor `NSKeyValueObservation` is `Sendable`,
        /// so `@unchecked` is forced on this struct; it is safe because it only lives inside the `Mutex` below and is
        /// touched only in `init` and `deinit`.
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
                    let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    let reason: RouteChangeReason =
                        switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
                        case .oldDeviceUnavailable: .oldDeviceUnavailable
                        case .newDeviceAvailable: .newDeviceAvailable
                        default: .other
                        }
                    continuation.yield(.routeChanged(reason, Self.readCurrentPort()))
                })

            tokens.append(
                center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) {
                    @Sendable note in
                    let info = note.userInfo
                    guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                        let type = AVAudioSession.InterruptionType(rawValue: raw)
                    else { return }
                    switch type {
                    case .began:
                        continuation.yield(.interruptionBegan)
                    case .ended:
                        let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                            .map(AVAudioSession.InterruptionOptions.init(rawValue:))
                        continuation.yield(.interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false))
                    @unknown default:
                        break
                    }
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
        /// If any step throws, the failure is swallowed and the read-back rate is still returned: it is whatever the
        /// hardware runs at, and the pipeline resamples to it. Returning `hz` instead would claim a rate the
        /// hardware may not have.
        public func requestSampleRate(_ hz: Int) async -> Int {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setActive(false)
                try session.setPreferredSampleRate(Double(hz))
                try session.setActive(true)
            } catch {
                // Fall through to the read-back below.
            }
            return Int(session.sampleRate)
        }

        public var currentPort: OutputPort { Self.readCurrentPort() }
        public var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }

        private static func readCurrentPort() -> OutputPort {
            guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return .other("") }
            return OutputPort(portType: port.portType.rawValue, name: port.portName)
        }
    }
#endif
