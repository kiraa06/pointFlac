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

    /// The key the Sound tab keeps this output's settings under (Task 15, per-device profiles): `usb:<name>`,
    /// `wired:<name>`, `bluetooth:<name>`, `builtIn`, `airPlay:<name>` or `other:<name>`. The kind comes first, so two
    /// devices of one name on different kinds of port keep apart; the speaker and the receiver are one output.
    public var profileKey: String {
        switch self {
        case .usb(let name): "usb:\(name)"
        case .wired(let name): "wired:\(name)"
        case .bluetooth(let name): "bluetooth:\(name)"
        case .builtIn: "builtIn"
        case .airPlay(let name): "airPlay:\(name)"
        case .other(let name): "other:\(name)"
        }
    }

    /// The port `profileKey` names, or nil for a key no port makes. The name is everything after the first colon, so
    /// a name with colons of its own comes back whole.
    public init?(profileKey key: String) {
        if key == "builtIn" {
            self = .builtIn
            return
        }
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let name = String(key[key.index(after: colon)...])
        switch key[..<colon] {
        case "usb": self = .usb(name)
        case "wired": self = .wired(name)
        case "bluetooth": self = .bluetooth(name)
        case "airPlay": self = .airPlay(name)
        case "other": self = .other(name)
        default: return nil
        }
    }
}
