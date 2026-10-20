import Foundation

/// Times as the player shows them, always in a monospaced font so digits never jitter.
public enum ClockFormat {
    /// m:ss, from whole seconds rounded down. Negative or non-finite input reads as 0:00.
    public static func clock(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// −m:ss, the time left.
    public static func remaining(_ seconds: Double) -> String {
        "−" + clock(seconds.rounded(.up))
    }

    /// m:ss.mmm, the loupe's millisecond readout.
    public static func precise(_ seconds: Double) -> String {
        let ms = seconds.isFinite ? max(0, Int((seconds * 1000).rounded())) : 0
        return String(format: "%d:%02d.%03d", ms / 60_000, (ms / 1000) % 60, ms % 1000)
    }

    /// +s.sss s or −s.sss s, the jog wheel's offset.
    public static func offset(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "−" : "+"
        return sign + String(format: "%.3f s", abs(seconds))
    }
}

/// Where a search query's words appear in a result, for highlighting the matching letters (spec §4.6).
public enum MatchHighlighter {
    /// The first occurrence of each word of `query` in `text`, ignoring case and accents, merged and in order.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        var found: [Range<String.Index>] = []
        for word in words where !word.isEmpty {
            if let r = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                found.append(r)
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in found {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
