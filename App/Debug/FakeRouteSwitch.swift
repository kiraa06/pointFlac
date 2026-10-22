#if DEBUG
    import Foundation
    import Observation
    import PFAudio
    import PFCore
    import Synchronization

    /// `-PFFakeRoute <profile key>` (DEBUG only), such as `-PFFakeRoute "usb:Test DAC"`: the audio session reports the
    /// output that key names (`OutputPort(profileKey:)`) in place of the real one, and the Sound tab offers a button
    /// that switches between it and the built-in speaker, posting a route change each time, as unplugging the device
    /// and plugging it back in do (the player pauses on the unplug, as for real). The audio itself still goes where
    /// iOS sends it. For the per-device settings' UI test and screenshots: the simulator has only its speaker.
    @MainActor
    @Observable
    final class FakeRouteSwitch {
        /// The session the player is given.
        @ObservationIgnored let session: FakeRouteSession
        /// The device the launch named.
        let device: OutputPort
        /// The output reported now.
        private(set) var port: OutputPort

        init(device: OutputPort) {
            self.device = device
            port = device
            session = FakeRouteSession(port: device)
        }

        /// The switch the launch asked for, if any.
        static func fromLaunch() -> FakeRouteSwitch? {
            guard let key = UserDefaults.standard.string(forKey: "PFFakeRoute"), let port = OutputPort(profileKey: key)
            else { return nil }
            return FakeRouteSwitch(device: port)
        }

        /// Where `toggle` goes next.
        var next: OutputPort { port == .builtIn ? device : .builtIn }

        /// From the device to the speaker (an unplug), or back (a plug-in).
        func toggle() {
            let to = next
            port = to
            session.route(to: to, reason: to == .builtIn ? .oldDeviceUnavailable : .newDeviceAvailable)
        }
    }

    /// `SystemAudioSession` with the port it reports replaced (see `FakeRouteSwitch`). Everything else, events
    /// included, is the real session's; its route changes report the chosen port.
    final class FakeRouteSession: AudioSessionControlling {
        let events: AsyncStream<SessionEvent>
        private let continuation: AsyncStream<SessionEvent>.Continuation
        private let real = SystemAudioSession()
        private let port: Mutex<OutputPort>

        init(port: OutputPort) {
            self.port = Mutex(port)
            (events, continuation) = AsyncStream<SessionEvent>.makeStream()
            let realEvents = real.events
            Task { [weak self] in
                for await event in realEvents {
                    guard let self else { return }
                    if case .routeChanged(let reason, _) = event {
                        continuation.yield(.routeChanged(reason, currentPort))
                    } else {
                        continuation.yield(event)
                    }
                }
            }
        }

        deinit {
            continuation.finish()
        }

        /// Reports `port` from now on, with a route change for `reason`.
        func route(to port: OutputPort, reason: RouteChangeReason) {
            self.port.withLock { $0 = port }
            continuation.yield(.routeChanged(reason, port))
        }

        func activate(preferredRate: Int?) async throws {
            try await real.activate(preferredRate: preferredRate)
        }

        func requestSampleRate(_ hz: Int) async -> Int {
            await real.requestSampleRate(hz)
        }

        var currentPort: OutputPort { port.withLock { $0 } }
        var outputVolume: Float { real.outputVolume }
        var sampleRate: Int { real.sampleRate }
    }
#endif
