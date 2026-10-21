import PFCore

/// Why the audio route changed, reduced to what the player acts on.
public enum RouteChangeReason: Sendable, Equatable {
    /// The previous output went away (headphones unplugged, DAC removed): playback should pause.
    case oldDeviceUnavailable
    case newDeviceAvailable
    case other

    /// Maps an `AVAudioSession.RouteChangeReason` raw value (newDeviceAvailable = 1, oldDeviceUnavailable = 2).
    /// Pure and free of AVFoundation, so host tests cover it. nil or unknown values become `.other`.
    public init(routeChangeRawValue raw: UInt?) {
        switch raw {
        case 1: self = .newDeviceAvailable
        case 2: self = .oldDeviceUnavailable
        default: self = .other
        }
    }
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

    /// Maps the raw values of an interruption notification: type (began = 1, ended = 0) and, on end, the options
    /// bit set (shouldResume = 1). Returns nil for a missing or unknown type. Pure, so host tests cover it.
    public static func interruption(typeRawValue type: UInt?, optionsRawValue options: UInt?) -> SessionEvent? {
        switch type {
        case 1: .interruptionBegan
        case 0: .interruptionEnded(shouldResume: (options ?? 0) & 1 != 0)
        default: nil
        }
    }
}

/// The audio session seen by the player: `SystemAudioSession` on iOS, `FakeSession` in host tests.
public protocol AudioSessionControlling: AnyObject, Sendable {
    /// Configures the session for long-form playback and activates it.
    ///
    /// With a `preferredRate`, the rate is asked for before activation (spec §5.2: "preferred rate is set before
    /// activation"), so a first play can come up at the file's rate, and the pipeline's negotiation that follows only
    /// reads it back instead of deactivating and reactivating. It is a hint, like `requestSampleRate`'s: read
    /// `sampleRate` for what the hardware took.
    func activate(preferredRate: Int?) async throws

    /// Asks the hardware for `hz` and returns the rate it actually runs at.
    ///
    /// iOS treats the preferred rate as a hint, so the result may differ from `hz`. The pipeline compares the two and
    /// resamples itself when they differ; it never lets iOS resample silently. The read-back rate is returned on every
    /// path, including when a step of the negotiation failed, never `hz`. An inactive session can legitimately read
    /// back 0, which the pipeline treats as "output rate unavailable". When an active session already runs at `hz`, an
    /// implementation should only read it back: a deactivate and reactivate cycle costs tens of milliseconds and posts
    /// route changes, for nothing.
    func requestSampleRate(_ hz: Int) async -> Int

    var currentPort: OutputPort { get }
    var outputVolume: Float { get }
    /// The rate the hardware runs at now. It can move without a negotiation (a configuration change under the same
    /// port), so the player compares it with the last negotiated rate on route changes. An inactive session can read 0.
    var sampleRate: Int { get }

    /// Session events. Single consumer: the stream is created once, so a second iterator would compete with the
    /// first for elements. The stream is unbounded: events are never dropped, and none are coalesced.
    ///
    /// The `outputVolume` KVO emits no initial value and fires reliably only while the session is active, so read
    /// `outputVolume` once at start rather than waiting for `.volumeChanged`.
    var events: AsyncStream<SessionEvent> { get }
}

extension AudioSessionControlling {
    /// Activates with no preferred rate: whatever the hardware runs at.
    public func activate() async throws {
        try await activate(preferredRate: nil)
    }
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
