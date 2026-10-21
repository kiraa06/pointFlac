import Foundation

/// How an album lays out on a record: which tracks sit on which side (spec §4.3, Runout's model).
///
/// Why a model of sides at all: the deck seeks across a side, not a track, and its tonearm sweeps one side's grooves.
/// The rules are Runout's: at most about 22 minutes a side, a track is never split, sides are balanced by duration,
/// and an album of two or more tracks always gets at least two sides (one-track albums get one).
public struct SideLayout: Sendable, Equatable {
    public struct Side: Sendable, Equatable {
        /// "A", "B", …
        public let letter: String
        /// Album track indices on this side, in order.
        public let tracks: Range<Int>
        /// The side's playing time, in seconds.
        public let duration: Double
    }

    /// The longest side the layout aims for: Runout's 22 minutes, a real LP's practical limit.
    public static let maxSideSeconds: Double = 22 * 60

    public let sides: [Side]
    private let durations: [Double]

    /// - Parameter durations: each track's length in seconds, in album order. Unknown lengths count as zero.
    public init(durations: [Double]) {
        let clean = durations.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        self.durations = clean
        sides = Self.layout(clean)
    }

    /// The side holding album track `index`, as an index into `sides`.
    public func side(ofTrack index: Int) -> Int? {
        sides.firstIndex { $0.tracks.contains(index) }
    }

    /// The track's code on the record: side letter and position on that side, e.g. "A2".
    public func code(ofTrack index: Int) -> String {
        guard let s = side(ofTrack: index) else { return "" }
        return "\(sides[s].letter)\(index - sides[s].tracks.lowerBound + 1)"
    }

    /// Seconds from the start of the track's side to the start of the track.
    public func offset(ofTrack index: Int) -> Double {
        guard let s = side(ofTrack: index) else { return 0 }
        return durations[sides[s].tracks.lowerBound..<index].reduce(0, +)
    }

    /// The track lengths on side `s`, for its timeline.
    public func durations(onSide s: Int) -> [Double] {
        guard sides.indices.contains(s) else { return [] }
        return Array(durations[sides[s].tracks])
    }

    /// The fewest sides that keep every side under the limit (at least two for two or more tracks), then the split
    /// into that many contiguous groups whose longest group is shortest: a linear-partition DP, tiny for real albums.
    private static func layout(_ d: [Double]) -> [Side] {
        guard !d.isEmpty else { return [] }
        if d.count == 1 { return [Side(letter: "A", tracks: 0..<1, duration: d[0])] }
        let total = d.reduce(0, +)
        var count = max(2, Int((total / maxSideSeconds).rounded(.up)))
        count = min(count, d.count)
        var cuts = partition(d, into: count)
        while count < d.count, groupSums(d, cuts).contains(where: { $0 > maxSideSeconds + 0.5 }) {
            count += 1
            cuts = partition(d, into: count)
        }
        var sides: [Side] = []
        var start = 0
        for (i, end) in (cuts + [d.count]).enumerated() {
            sides.append(Side(letter: letter(i), tracks: start..<end, duration: d[start..<end].reduce(0, +)))
            start = end
        }
        return sides
    }

    /// Split points (exclusive group ends, without the last) for `k` contiguous groups minimising the largest sum.
    private static func partition(_ d: [Double], into k: Int) -> [Int] {
        let n = d.count
        var prefix = [0.0]
        for x in d { prefix.append(prefix.last! + x) }
        // best[j][i]: the smallest possible largest group when the first i tracks go into j groups.
        var best = Array(repeating: Array(repeating: Double.infinity, count: n + 1), count: k + 1)
        var cut = Array(repeating: Array(repeating: 0, count: n + 1), count: k + 1)
        best[0][0] = 0
        for j in 1...k {
            for i in j...n {
                for m in (j - 1)..<i {
                    let cost = max(best[j - 1][m], prefix[i] - prefix[m])
                    if cost < best[j][i] - 1e-9 {
                        best[j][i] = cost
                        cut[j][i] = m
                    }
                }
            }
        }
        var cuts: [Int] = []
        var i = n
        for j in stride(from: k, to: 1, by: -1) {
            i = cut[j][i]
            cuts.append(i)
        }
        return cuts.reversed()
    }

    private static func groupSums(_ d: [Double], _ cuts: [Int]) -> [Double] {
        var sums: [Double] = []
        var start = 0
        for end in cuts + [d.count] {
            sums.append(d[start..<end].reduce(0, +))
            start = end
        }
        return sums
    }

    private static func letter(_ i: Int) -> String {
        i < 26 ? String(UnicodeScalar(UInt8(65 + i))) : "S\(i + 1)"
    }
}

/// One side's tracks laid end to end: where a time on the side falls, and where its track gaps are.
public struct SideTimeline: Sendable, Equatable {
    public let durations: [Double]
    public let starts: [Double]
    public let total: Double

    public init(durations: [Double]) {
        self.durations = durations
        var starts: [Double] = []
        var t = 0.0
        for d in durations {
            starts.append(t)
            t += d
        }
        self.starts = starts
        total = t
    }

    /// The track (index on the side) and the offset into it for `seconds` on the side, clamped to the side.
    public func locate(_ seconds: Double) -> (track: Int, offset: Double) {
        guard !durations.isEmpty else { return (0, 0) }
        let t = min(max(seconds, 0), total)
        let track = (starts.lastIndex { $0 <= t } ?? 0)
        return (track, min(t - starts[track], durations[track]))
    }

    /// `seconds`, pulled onto a track start when within `tolerance` of one: the needle clicking into a track gap.
    /// Returns the track snapped to, if any, so the view can tick a haptic only when the snap changes.
    public func snapped(_ seconds: Double, tolerance: Double) -> (seconds: Double, track: Int?) {
        for (i, start) in starts.enumerated() where abs(seconds - start) <= tolerance {
            return (start, i)
        }
        return (min(max(seconds, 0), total), nil)
    }
}
