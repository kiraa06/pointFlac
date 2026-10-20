import Foundation

public enum SignalIndicator: Equatable, Sendable {
    case idle
    case pure
    case resampled(RateChange)
    case depthReduced(from: Int, to: Int)
    case processing(Int)
    case scrubbing
    case bluetoothLossy
}

/// Everything the signal strip needs to describe, honestly, what happens to the audio.
public struct SignalState: Sendable, Equatable {
    public var source: AudioFormat?
    public var plan: OutputPlan?
    public var hardwareRate: Int?
    public var port: OutputPort?
    public var systemVolume: Float?
    public var activeProcessing: [String]
    public var scrubbing: Bool

    public init(
        source: AudioFormat? = nil, plan: OutputPlan? = nil, hardwareRate: Int? = nil, port: OutputPort? = nil,
        systemVolume: Float? = nil, activeProcessing: [String] = [], scrubbing: Bool = false
    ) {
        self.source = source
        self.plan = plan
        self.hardwareRate = hardwareRate
        self.port = port
        self.systemVolume = systemVolume
        self.activeProcessing = activeProcessing
        self.scrubbing = scrubbing
    }

    /// Precedence: scrubbing > bluetoothLossy > processing > resampled > depthReduced > pure.
    public var indicator: SignalIndicator {
        guard source != nil else { return .idle }
        if scrubbing { return .scrubbing }
        if port?.isBluetooth == true { return .bluetoothLossy }
        if !activeProcessing.isEmpty { return .processing(activeProcessing.count) }
        if let change = plan?.resample { return .resampled(change) }
        if plan?.reduceTo24 == true, let bits = source?.bitsPerSample { return .depthReduced(from: bits, to: 24) }
        return .pure
    }

    /// Set only for a USB port with the system volume below full scale.
    public var volumeWarningPercent: Int? {
        guard port?.isUSB == true, let volume = systemVolume, volume < 1.0 else { return nil }
        return Int((volume * 100).rounded())
    }
}
