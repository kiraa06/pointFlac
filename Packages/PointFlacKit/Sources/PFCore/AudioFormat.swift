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

    /// Sample rate in kHz, with one decimal place only when the rate is not a whole number of kHz.
    public var formattedRate: String {
        let locale = Locale(identifier: "en_US_POSIX")
        let kHz = Double(sampleRate) / 1000
        if sampleRate % 1000 == 0 {
            return String(format: "%.0f kHz", locale: locale, kHz)
        }
        return String(format: "%.1f kHz", locale: locale, kHz)
    }

    public var formattedDepth: String {
        "\(bitsPerSample)-bit"
    }
}
