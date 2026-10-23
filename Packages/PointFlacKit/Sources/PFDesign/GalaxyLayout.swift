import CoreGraphics
import Foundation

/// The numbers that shape the Galaxy: how big a sleeve is at each rank, how far apart sleeves rest, and how the
/// placement search walks outward. One value type so the layout, the physics and the view can't disagree.
public struct GalaxyMetrics: Sendable, Equatable {
    /// Side of the top-ranked sleeve, which sits at the centre.
    public var coreSide: Double = 140
    /// Side the next rank starts from, and the floor the sides decay towards (`minSide`).
    public var maxSide: Double = 96
    public var minSide: Double = 34
    /// How quickly sides fall off with rank: larger keeps more sleeves big.
    public var falloff: Double = 5.4
    /// Clear space between resting sleeves. It must stay at least `2 × driftAmplitude + 6` so that two sleeves
    /// drifting towards each other can never touch.
    public var gap: Double = 14
    /// How far a sleeve drifts from home on each axis.
    public var driftAmplitude: Double = 4
    /// Vertical stretch of the search spiral: the screen is taller than it is wide, so the galaxy grows that way.
    public var aspect: Double = 1.28
    /// Radius added per search ring, and the arc length between candidate spots on a ring.
    public var radialStep: Double = 3
    public var arcStep: Double = 7

    public init() {}

    /// The side of the sleeve at `rank` (0 is the top), times `scale`. Rank 0 is the fixed core size; the rest decay
    /// exponentially from `maxSide` towards `minSide`, so the tail never becomes unreadably small.
    public func side(rank: Int, scale: Double) -> Double {
        if rank == 0 { return coreSide * scale }
        return (minSide + (maxSide - minSide) * exp(-Double(rank) / falloff)) * scale
    }
}

/// One album's resting place: the centre of its square sleeve and the sleeve's side, in points around the origin.
public struct GalaxySlot: Sendable, Equatable {
    public var center: CGPoint
    public var side: Double

    public init(center: CGPoint, side: Double) {
        self.center = center
        self.side = side
    }
}

/// Where each album rests in the Galaxy.
///
/// Why a spiral search rather than a formula: sleeves have different sizes, so the only way to keep them all clear of
/// each other yet packed close to the middle is to try spots outward from the centre and take the first free one. The
/// angle each ring starts at is rank × the golden angle, so successive ranks fan out around the centre instead of
/// piling up on one side. The world is unbounded (the view pans and zooms it), so the search always succeeds.
public struct GalaxyLayout: Sendable {
    /// Ranks that search from the centre outward with no shortcut, and how many rings back later ranks restart.
    private static let exactRanks = 64
    private static let lookbackRings = 2

    /// Homes for ranks `0..<count` at scale 1, in rank order. Same input, bit-identical output: nothing here depends
    /// on hashing order or randomness.
    public static func place(count: Int, metrics: GalaxyMetrics = .init()) -> [GalaxySlot] {
        guard count > 0 else { return [] }
        // The 3x3 cell scan is only exhaustive while no two sleeves can reach further than a cell: the reach is at most
        // the largest side plus the gap, and the core is the largest side unless a custom `maxSide` exceeds it.
        var grid = Grid(cell: max(metrics.coreSide, metrics.maxSide) + metrics.gap)
        var slots: [GalaxySlot] = []
        slots.reserveCapacity(count)
        var lastRing = 0

        for rank in 0..<count {
            let side = metrics.side(rank: rank, scale: 1)
            let start = Double(rank) * 2.39996
            // The first `exactRanks` search every ring from the centre, so the head of the galaxy always fills the
            // nearest free spot. Beyond that, sleeves are all close to `minSide` and the inside is packed, so the
            // search resumes a few rings behind the previous sleeve instead of rescanning thousands of blocked
            // spots: that keeps 1,000 albums fast, where a full scan per rank grows with the square of the radius.
            let first = rank < Self.exactRanks ? 0 : max(0, lastRing - Self.lookbackRings)
            let (ring, center) = firstFreeSpot(from: first, start: start, side: side, grid: grid, metrics: metrics)
            lastRing = ring
            grid.insert(x: Double(center.x), y: Double(center.y), side: side)
            slots.append(GalaxySlot(center: center, side: side))
        }
        return slots
    }

    /// Walks rings outward from `first` and returns the ring and centre of the first free spot. It always returns:
    /// the world is unbounded, so some ring is clear of every placed slot.
    private static func firstFreeSpot(
        from first: Int, start: Double, side: Double, grid: Grid, metrics: GalaxyMetrics
    ) -> (Int, CGPoint) {
        var ring = first
        while true {
            let radius = Double(ring) * metrics.radialStep
            let steps = radius == 0 ? 1 : max(10, Int((2 * Double.pi * radius / metrics.arcStep).rounded()))
            for k in 0..<steps {
                let angle = start + Double(k) / Double(steps) * 2 * Double.pi
                let x = cos(angle) * radius
                let y = sin(angle) * radius * metrics.aspect
                if grid.isFree(x: x, y: y, side: side, gap: metrics.gap) { return (ring, CGPoint(x: x, y: y)) }
            }
            ring += 1
        }
    }

    /// A uniform grid of the slots placed so far, so a free-spot check looks at a handful of neighbours instead of
    /// every slot. The cell is the largest possible reach between two sleeves, so the 3×3 block around a spot's cell
    /// holds every sleeve that could block it.
    private struct Grid {
        let cell: Double
        var cells: [Int64: [Int]] = [:]
        var xs: [Double] = []
        var ys: [Double] = []
        var sides: [Double] = []

        init(cell: Double) { self.cell = cell }

        private func index(_ v: Double) -> Int64 { Int64((v / cell).rounded(.down)) }
        private func key(_ cx: Int64, _ cy: Int64) -> Int64 { (cx << 32) ^ (cy & 0xFFFF_FFFF) }

        mutating func insert(x: Double, y: Double, side: Double) {
            cells[key(index(x), index(y)), default: []].append(xs.count)
            xs.append(x)
            ys.append(y)
            sides.append(side)
        }

        func isFree(x: Double, y: Double, side: Double, gap: Double) -> Bool {
            let cx = index(x)
            let cy = index(y)
            // The spot's own cell first: most blocked spots are blocked by a neighbour right there, so they exit early.
            if blocked(cells[key(cx, cy)], x, y, side, gap) { return false }
            for ix in (cx - 1)...(cx + 1) {
                for iy in (cy - 1)...(cy + 1) where ix != cx || iy != cy {
                    if blocked(cells[key(ix, iy)], x, y, side, gap) { return false }
                }
            }
            return true
        }

        private func blocked(_ members: [Int]?, _ x: Double, _ y: Double, _ side: Double, _ gap: Double) -> Bool {
            guard let members else { return false }
            for m in members.reversed() {
                let need = (sides[m] + side) / 2 + gap
                if abs(xs[m] - x) < need && abs(ys[m] - y) < need { return true }
            }
            return false
        }
    }
}

/// The slow idle wander of a sleeve around its home.
///
/// Why it's a pure function of (seed, time): the view draws from a `TimelineView`, so the offset is computed from the
/// clock rather than integrated, and stays exact at any frame rate. Each sleeve gets its own speed and phase from its
/// seed so they don't move in lockstep.
public struct Drift: Sendable {
    /// Offset from home at `time` seconds. Each axis stays within ±4 (2.5 + 1.5): fixed at the default
    /// `GalaxyMetrics.driftAmplitude`, which the layout gap is sized against (`gap ≥ 2 × 4 + 6`).
    public static func offset(seed: UInt64, time: Double) -> CGVector {
        var state = seed
        let speed = 0.5 + 0.6 * unit(splitMix64(&state))
        let phase = 2 * Double.pi * unit(splitMix64(&state))
        let w = time * speed
        let dx = 2.5 * sin(0.55 * w + phase) + 1.5 * sin(0.21 * w + 2 * phase)
        let dy = 2.5 * cos(0.55 * w + phase) + 1.5 * cos(0.21 * w + 2 * phase)
        return CGVector(dx: dx, dy: dy)
    }

    /// A stable seed for an album id: FNV-1a over its UTF-8 bytes. Unlike `hashValue` it doesn't change between
    /// launches, so an album drifts the same way every time the Galaxy opens.
    public static func seed(for id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// SplitMix64: one well-mixed 64-bit value per call, so a plain integer seed yields uncorrelated speed and phase.
    private static func splitMix64(_ state: inout UInt64) -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Maps 64 random bits to [0, 1) using the top 53.
    private static func unit(_ bits: UInt64) -> Double { Double(bits >> 11) / Double(1 << 53) }
}
