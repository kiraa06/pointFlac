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

    /// The SIGNAL cell's resolution runs, typed: the delivered resolution (never for a lossy or unknown route), then Pure
    /// only when the indicator is `.pure`.
    public static func signalBadges(_ s: SignalState) -> [SignalBadge] {
        var badges: [SignalBadge] = []
        switch s.resolution {
        case .hiRes(let bits, let rate): badges.append(.hiRes(bits: bits, rate: rate))
        case .lossless(let bits, let rate): badges.append(.lossless(bits: bits, rate: rate))
        case .lossy, nil: break
        }
        if s.indicator == .pure { badges.append(.pure) }
        return badges
    }

    /// The same runs as upper-case text, e.g. `["HI-RES 24/96", "PURE"]` (the brief's interface; the cell itself shows
    /// `SignalBadge.displayText`).
    public static func badges(_ s: SignalState) -> [String] { signalBadges(s).map(\.text) }

    /// Whether the SIGNAL cell shows the resolution runs. False on Bluetooth, AirPlay, an unknown route, idle and
    /// pending, where the cell keeps the indicator words: those are the warnings, and must never go blank.
    public static func showsResolution(_ s: SignalState) -> Bool { !signalBadges(s).isEmpty }

    /// The small note beside the song title for the altered or transient states (the resolution text in the cell covers the
    /// rest): the rate change, the depth reduction, processing, a downmix, scrubbing. Nil for pure, for the route
    /// warnings (Bluetooth, AirPlay, other, which stay in the cell), and for idle and pending.
    public static func titleNote(_ s: SignalState) -> String? {
        // When the cell shows the indicator words, they already say this state: never repeat it.
        guard showsResolution(s) else { return nil }
        switch s.indicator {
        case .resampled(let change): return "Resampled \(shortRate(change.from))→\(shortRate(change.to))"
        case .depthReduced(let from, let to): return "\(from)→\(to)-bit"
        case .processing: return "Processing"
        case .downmixed(let from, let to): return "Downmixed \(from)→\(to)"
        case .scrubbing: return "Scrubbing"
        case .idle, .pending, .pure, .bluetoothLossy, .airPlay, .otherRoute: return nil
        }
    }

    /// What VoiceOver reads for the title note: "to" for the arrow, and the units spelled out.
    public static func titleNoteSpoken(_ s: SignalState) -> String? {
        guard showsResolution(s) else { return nil }
        switch s.indicator {
        case .resampled(let change): return "Resampled \(shortRate(change.from)) to \(shortRate(change.to)) kilohertz"
        case .depthReduced(let from, let to): return "Reduced from \(from)-bit to \(to)-bit"
        case .downmixed(let from, let to): return "Downmixed from \(from) to \(to) channels"
        default: return titleNote(s)
        }
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
    static func shortRate(_ hz: Int) -> String {
        let formatted = AudioFormat.formatRate(hz)
        return String(formatted.dropLast(" kHz".count))
    }
}

/// One run of the SIGNAL cell's resolution text: what it says, and what it means to a screen reader.
public enum SignalBadge: Hashable, Sendable {
    case hiRes(bits: Int, rate: Int)
    case lossless(bits: Int, rate: Int)
    case pure

    public var text: String {
        switch self {
        case .hiRes(let bits, let rate): "HI-RES \(bits)/\(SignalStrip.shortRate(rate))"
        case .lossless(let bits, let rate): "LOSSLESS \(bits)/\(SignalStrip.shortRate(rate))"
        case .pure: "PURE"
        }
    }

    /// Mixed case, for the SIGNAL cell's plain text: `Hi-Res 24/96`, `Lossless 16/44.1`, `Pure`.
    public var displayText: String {
        switch self {
        case .hiRes(let bits, let rate): "Hi-Res \(bits)/\(SignalStrip.shortRate(rate))"
        case .lossless(let bits, let rate): "Lossless \(bits)/\(SignalStrip.shortRate(rate))"
        case .pure: "Pure"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .hiRes(let bits, let rate): "Hi-Res output, \(bits)-bit \(AudioFormat.formatRate(rate))"
        case .lossless(let bits, let rate): "Lossless output, \(bits)-bit \(AudioFormat.formatRate(rate))"
        case .pure: "Pure: untouched by pointFlac"
        }
    }
}
