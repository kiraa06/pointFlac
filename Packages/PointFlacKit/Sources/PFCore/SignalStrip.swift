import Foundation

public enum SignalStrip {
    public static let idleText = "No record"

    /// `FLAC · <depth> · <hardware rate> · <signal>`, then ` · ● Volume N%` when a USB route runs below full volume
    /// (spec §5.7: the warning sits next to the state, it does not replace it).
    public static func text(_ s: SignalState) -> String {
        guard let source = s.source else { return idleText }
        let rate = AudioFormat(
            sampleRate: s.hardwareRate ?? source.sampleRate, bitsPerSample: source.bitsPerSample,
            channels: source.channels
        ).formattedRate
        var text = "FLAC · \(source.formattedDepth) · \(rate) · \(label(s.indicator))"
        if let percent = s.volumeWarningPercent {
            text += " · ● Volume \(percent)%"
        }
        return text
    }

    /// The words for one indicator. `.idle` reads as the idle strip, never as "● Pure": with no track there is
    /// nothing to call pure.
    static func label(_ indicator: SignalIndicator) -> String {
        switch indicator {
        case .idle: idleText
        case .pending: "● Starting…"
        case .pure: "● Pure"
        case .resampled(let change): "● Resampled \(shortRate(change.from))→\(shortRate(change.to))"
        case .depthReduced(let from, let to): "● \(from)→\(to)-bit"
        case .processing: "● Processing"
        case .scrubbing: "● Scrubbing"
        case .bluetoothLossy: "● Bluetooth (lossy)"
        case .airPlay: "● AirPlay (re-encoded)"
        case .downmixed(let from, let to): "● Downmixed \(from)→\(to)"
        case .otherRoute: "● Output may alter audio"
        }
    }

    /// kHz shorthand without the unit, as exact as `AudioFormat.formattedRate`: 44.1, 48, 88.2, 22.05, 11.025.
    private static func shortRate(_ hz: Int) -> String {
        let formatted = AudioFormat(sampleRate: hz, bitsPerSample: 0, channels: 0).formattedRate
        return String(formatted.dropLast(" kHz".count))
    }
}
