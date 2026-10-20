import Foundation

/// A sample-rate conversion performed by pointFlac itself.
public struct RateChange: Sendable, Equatable {
    public var from: Int
    public var to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// How audio is handed to iOS for a given source and hardware rate.
public struct OutputPlan: Sendable, Equatable {
    public enum Client: Sendable, Equatable {
        case float32
        case int32
    }

    public var client: Client
    public var clientSampleRate: Int
    public var resample: RateChange?
    public var reduceTo24: Bool

    public init(client: Client, clientSampleRate: Int, resample: RateChange?, reduceTo24: Bool) {
        self.client = client
        self.clientSampleRate = clientSampleRate
        self.resample = resample
        self.reduceTo24 = reduceTo24
    }
}

public struct OutputCapabilities: Sendable {
    public var int32Passthrough: Bool

    public init(int32Passthrough: Bool) {
        self.int32Passthrough = int32Passthrough
    }

    /// What pointFlac assumes the output path carries: no Int32 passthrough. 32-bit sources are TPDF-dithered to 24
    /// bits on a Float32 client, and the signal strip says so; spec §5.2 accepts this as a disclosed limit.
    ///
    /// Spike S1 (ruling R13) keeps this false whatever the simulator shows. Its capture proves what pointFlac hands the
    /// RemoteIO unit, not what iOS passes to the DAC, and the simulator runs on the Mac's CoreAudio, not iPhone
    /// hardware. It flips to true only on device evidence with a 32-bit-capable USB DAC; the steps that would justify
    /// it are in `docs/spikes/S1-output-path.md`.
    public static let current = OutputCapabilities(int32Passthrough: false)
}

public enum OutputFormatPolicy {
    public static func plan(source: AudioFormat, hardwareRate: Int, capabilities: OutputCapabilities) -> OutputPlan {
        let resample = hardwareRate != source.sampleRate ? RateChange(from: source.sampleRate, to: hardwareRate) : nil
        let deep = source.bitsPerSample > 24
        let client: OutputPlan.Client = (deep && capabilities.int32Passthrough && resample == nil) ? .int32 : .float32
        return OutputPlan(
            client: client, clientSampleRate: hardwareRate, resample: resample,
            reduceTo24: deep && client == .float32)
    }
}
