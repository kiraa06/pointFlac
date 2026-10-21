import Foundation

/// The kind of audio output route currently in use.
///
/// USB, wired and built-in routes carry what pointFlac hands them (at the hardware rate). Bluetooth and AirPlay
/// re-encode, and `other` (CarPlay, HDMI, a port type pointFlac does not know) may alter the audio, so the signal strip
/// never calls those "Pure" (`SignalState.indicator`).
public enum OutputPort: Sendable, Equatable {
    case usb(String)
    case wired(String)
    case bluetooth(String)
    case builtIn
    case airPlay(String)
    case other(String)

    public var isUSB: Bool {
        if case .usb = self { return true }
        return false
    }

    public var isBluetooth: Bool {
        if case .bluetooth = self { return true }
        return false
    }
}
