import Foundation

/// The PCM format of an audio stream.
public struct AudioFormat: Sendable, Hashable, Codable {
    public var sampleRate: Int
    public var bitsPerSample: Int
    public var channels: Int

    public init(sampleRate: Int, bitsPerSample: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.channels = channels
    }

    /// Sample rate in kHz, exactly: up to three decimals, trailing zeros trimmed. 48000 → "48 kHz", 44100 → "44.1 kHz",
    /// 22050 → "22.05 kHz", 11025 → "11.025 kHz".
    ///
    /// Why exact rather than one decimal: rounding showed 11025 as "11.0 kHz" and 22050 as "22.1 kHz", rates the file
    /// does not have, and the strip must never misstate the audio. Integer arithmetic, so no rate picks up a binary
    /// floating-point artefact either.
    public var formattedRate: String {
        let hz = sampleRate.magnitude
        let sign = sampleRate < 0 ? "-" : ""
        let whole = hz / 1000
        let fraction = hz % 1000
        guard fraction != 0 else { return "\(sign)\(whole) kHz" }
        var digits = String(fraction)
        digits = String(repeating: "0", count: 3 - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(sign)\(whole).\(digits) kHz"
    }

    public var formattedDepth: String {
        "\(bitsPerSample)-bit"
    }
}
