import Foundation

public enum SignalStrip {
    public static let idleText = "No record"

    public static func text(_ s: SignalState) -> String {
        guard let source = s.source else { return idleText }
        let rate = AudioFormat(
            sampleRate: s.hardwareRate ?? source.sampleRate, bitsPerSample: source.bitsPerSample,
            channels: source.channels
        ).formattedRate
        return "FLAC · \(source.formattedDepth) · \(rate) · \(label(s.indicator))"
    }

    private static func label(_ indicator: SignalIndicator) -> String {
        switch indicator {
        case .idle, .pure: "● Pure"
        case .resampled(let change): "● Resampled \(shortRate(change.from))→\(shortRate(change.to))"
        case .depthReduced(let from, let to): "● \(from)→\(to)-bit"
        case .processing: "● Processing"
        case .scrubbing: "● Scrubbing"
        case .bluetoothLossy: "● Bluetooth (lossy)"
        }
    }

    /// kHz shorthand without the unit: 44.1, 48, 88.2, 96.
    private static func shortRate(_ hz: Int) -> String {
        let formatted = AudioFormat(sampleRate: hz, bitsPerSample: 0, channels: 0).formattedRate
        return String(formatted.dropLast(" kHz".count))
    }
}
