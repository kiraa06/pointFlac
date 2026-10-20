import PFCore

/// Why the audio route changed, reduced to what the player acts on.
public enum RouteChangeReason: Sendable, Equatable {
    /// The previous output went away (headphones unplugged, DAC removed): playback should pause.
    case oldDeviceUnavailable
    case newDeviceAvailable
    case other
}

/// Something the audio session reports that the player reacts to.
public enum SessionEvent: Sendable, Equatable {
    case routeChanged(RouteChangeReason, OutputPort)
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case volumeChanged(Float)
    /// The media server died. The session must be reconfigured and reactivated by the owner; the session object
    /// itself does not do that.
    case mediaServicesReset
}

/// The audio session seen by the player: `SystemAudioSession` on iOS, `FakeSession` in host tests.
public protocol AudioSessionControlling: AnyObject, Sendable {
    /// Configures the session for long-form playback and activates it.
    func activate() async throws

    /// Asks the hardware for `hz` and returns the rate it actually runs at, always read back from the session.
    ///
    /// iOS treats the preferred rate as a hint, so the result may differ from `hz`. The pipeline compares the two and
    /// resamples itself when they differ; it never lets iOS resample silently. A rate ≤ 0 means "unavailable" to the
    /// pipeline, so implementations return the read-back rate even when a step of the negotiation failed.
    func requestSampleRate(_ hz: Int) async -> Int

    var currentPort: OutputPort { get }
    var outputVolume: Float { get }

    /// Session events. Single consumer: the stream is created once, so a second iterator would compete with the
    /// first for elements.
    var events: AsyncStream<SessionEvent> { get }
}

extension OutputPort {
    /// Maps an `AVAudioSession.Port` raw value and the port's display name. Pure, so host tests cover it.
    public init(portType: String, name: String) {
        switch portType {
        case "USBAudio": self = .usb(name)
        case "Headphones", "LineOut": self = .wired(name)
        case "BluetoothA2DPOutput", "BluetoothLE", "BluetoothHFP": self = .bluetooth(name)
        case "Speaker", "Receiver": self = .builtIn
        case "AirPlay": self = .airPlay(name)
        default: self = .other(name)
        }
    }
}
