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

    /// The SIGNAL cell's runs, typed. USB and wired: Hi-Res or Lossless, then Pure when the indicator is `.pure`.
    /// The built-in speaker: Pure when it is, then "iOS speaker tuning", never a Lossless or Hi-Res claim. Every
    /// other route has no runs, and the cell keeps the indicator words.
    public static func signalBadges(_ s: SignalState) -> [SignalBadge] {
        var badges: [SignalBadge] = []
        switch s.port {
        case .usb, .wired:
            switch s.resolution {
            case .hiRes: badges = [.hiRes]
            case .lossless: badges = [.lossless]
            default: break
            }
            if !badges.isEmpty, s.indicator == .pure { badges.append(.pure) }
        case .builtIn:
            guard s.plan != nil, s.source != nil else { break }
            if s.indicator == .pure { badges.append(.pure) }
            badges.append(.speakerTuning)
        default: break
        }
        return badges
    }

    /// The same runs as upper-case text, e.g. `["HI-RES", "PURE"]` (the brief's interface; the cell itself shows
    /// `SignalBadge.displayText`).
    public static func badges(_ s: SignalState) -> [String] { signalBadges(s).map(\.text) }

    /// Whether the SIGNAL cell shows the resolution runs. False on Bluetooth, AirPlay, an unknown route, idle and
    /// pending, where the cell keeps the indicator words: those are the warnings, and must never go blank.
    public static func showsResolution(_ s: SignalState) -> Bool { !signalBadges(s).isEmpty }

    /// The small note beside the song title for the altered or transient states (the resolution text in the cell covers the
    /// rest): the depth reduction, processing, a downmix, scrubbing. Nil for pure, for the route warnings (Bluetooth,
    /// AirPlay, other, which stay in the cell), and for idle and pending. A rate change gets no note either (Kiran's
    /// call): the details sheet's Rate change row states it, and who made it.
    public static func titleNote(_ s: SignalState) -> String? {
        // When the cell shows the indicator words, they already say this state: never repeat it.
        guard showsResolution(s) else { return nil }
        switch s.indicator {
        case .depthReduced(let from, let to): return "\(from)→\(to)-bit"
        case .processing: return "Processing"
        case .downmixed(let from, let to): return "Downmixed \(from)→\(to)"
        case .scrubbing: return "Scrubbing"
        case .idle, .pending, .pure, .resampled, .bluetoothLossy, .airPlay, .otherRoute: return nil
        }
    }

    /// What VoiceOver reads for the title note: "to" for the arrow, and the units spelled out.
    public static func titleNoteSpoken(_ s: SignalState) -> String? {
        guard showsResolution(s) else { return nil }
        switch s.indicator {
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

/// One run of the SIGNAL cell's text: what it says, and what it means to a screen reader.
public enum SignalBadge: Hashable, Sendable {
    case hiRes
    case lossless
    case pure
    case speakerTuning

    public var text: String {
        switch self {
        case .hiRes: "HI-RES"
        case .lossless: "LOSSLESS"
        case .pure: "PURE"
        case .speakerTuning: "IOS SPEAKER TUNING"
        }
    }

    /// Mixed case, for the cell's plain text.
    public var displayText: String {
        switch self {
        case .hiRes: "Hi-Res"
        case .lossless: "Lossless"
        case .pure: "Pure"
        case .speakerTuning: "iOS speaker tuning"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .hiRes: "Hi-Res output"
        case .lossless: "Lossless output"
        case .pure: "Pure"
        case .speakerTuning: "iOS speaker tuning"
        }
    }
}
