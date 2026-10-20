import Foundation

/// The kind of audio output route currently in use.
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
