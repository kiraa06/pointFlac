import CoreGraphics
import Foundation

/// The Galaxy's collision physics: a held sleeve shoves the others aside, and everything stays where it ends up.
///
/// Why no spring home: a sleeve you drop, or one that was pushed, becomes part of the new arrangement. Resting
/// sleeves therefore have no force on them and cost nothing but the overlap check. Units are the points of
/// `GalaxySlot`, in the same world space.
public struct GalaxyPhysics: Sendable {
    /// One sleeve in motion. `held` marks the one under the finger; it follows `step`'s target and has infinite mass.
    public struct Body: Sendable, Equatable {
        public var center: CGPoint
        public var velocity: CGVector
        public var side: Double
        public var held: Bool

        public init(center: CGPoint, velocity: CGVector = .zero, side: Double, held: Bool = false) {
            self.center = center
            self.velocity = velocity
            self.side = side
            self.held = held
        }
    }

    public var bodies: [Body]

    /// Sleeve sizes the grid cell must cover at the least (twice the biggest non-core side).
    private let maxSide: Double
    /// Reused between steps so a frame allocates nothing: bodies sorted by grid cell (see `bin`).
    private var entries: [Entry] = []

    private struct Entry {
        var key: Int64
        var index: Int32
    }

    /// Clear space the separation pass leaves, and the one `isSettled` demands. Smaller than the layout gap: a
    /// shoved sleeve only has to stop touching, not return to the airy resting spacing.
    private static let gap = 6.0
    private static let damping = 0.90
    private static let passes = 4
    /// Share of a push a sleeve keeps as velocity, so a shove carries a little and the galaxy feels soft.
    private static let kick = 0.25
    private static let restSpeed = 0.05
    /// Overlap below this is float noise from the separation arithmetic, not a real overlap.
    private static let tolerance = 1e-3

    public init(bodies: [Body], metrics: GalaxyMetrics = .init()) {
        self.bodies = bodies
        self.maxSide = metrics.maxSide
        entries.reserveCapacity(bodies.count)
    }

    public init(slots: [GalaxySlot], metrics: GalaxyMetrics = .init()) {
        self.init(bodies: slots.map { Body(center: $0.center, side: $0.side) }, metrics: metrics)
    }

    /// True when nothing is moving noticeably and no two sleeves overlap, so the view can stop stepping.
    public var isSettled: Bool {
        for b in bodies where hypot(b.velocity.dx, b.velocity.dy) >= Self.restSpeed { return false }
        var grid: [Entry] = []
        let cell = cellSize()
        Self.bin(bodies, cell: cell, into: &grid)
        for p in grid.indices {
            let i = Int(grid[p].index)
            let a = bodies[i]
            var settled = true
            Self.forEachNeighbour(of: i, in: grid, bodies: bodies, cell: cell) { j in
                let b = bodies[j]
                let need = (a.side + b.side) / 2 + Self.gap - Self.tolerance
                if abs(a.center.x - b.center.x) < need && abs(a.center.y - b.center.y) < need { settled = false }
            }
            if !settled { return false }
        }
        return true
    }

    /// Advances one frame. The held body moves to `holdTarget` (it stays put without one) and its velocity becomes
    /// that move, so letting go throws it naturally. The others coast with damping, then four separation passes
    /// resolve overlaps.
    ///
    /// The grid is rebuilt into reused storage before each pass, since the previous pass moved bodies. Within a pass
    /// a body can still shift past its binned cell; a pair that therefore gets missed is caught by the next pass.
    public mutating func step(holdTarget: CGPoint?) {
        for i in bodies.indices {
            if bodies[i].held {
                let target = holdTarget ?? bodies[i].center
                bodies[i].velocity = CGVector(dx: target.x - bodies[i].center.x, dy: target.y - bodies[i].center.y)
                bodies[i].center = target
            } else {
                bodies[i].velocity.dx *= Self.damping
                bodies[i].velocity.dy *= Self.damping
                bodies[i].center.x += bodies[i].velocity.dx
                bodies[i].center.y += bodies[i].velocity.dy
            }
        }
        let cell = cellSize()
        for pass in 0..<Self.passes {
            Self.bin(bodies, cell: cell, into: &entries)
            for p in entries.indices {
                let i = Int(entries[p].index)
                let (cx, cy) = Self.cellOf(bodies[i].center, cell)
                for ix in (cx - 1)...(cx + 1) {
                    for iy in (cy - 1)...(cy + 1) {
                        var q = Self.lowerBound(entries, Self.key(ix, iy))
                        let key = Self.key(ix, iy)
                        while q < entries.count && entries[q].key == key {
                            let j = Int(entries[q].index)
                            if j > i { separate(i, j, kick: pass == 0) }
                            q += 1
                        }
                    }
                }
            }
        }
    }

    /// Pushes two squares apart along the axis they overlap least on, the cheapest way out. A held body never moves;
    /// otherwise the push is shared by area, so a big sleeve barely budges when a small one runs into it.
    private mutating func separate(_ i: Int, _ j: Int, kick: Bool) {
        let p = bodies[i]
        let q = bodies[j]
        if p.held && q.held { return }
        let dx = Double(q.center.x - p.center.x)
        let dy = Double(q.center.y - p.center.y)
        let half = (p.side + q.side) / 2 + Self.gap
        let ox = half - abs(dx)
        let oy = half - abs(dy)
        if ox <= 0 || oy <= 0 { return }
        let mp = p.side * p.side
        let mq = q.side * q.side
        let wp = p.held ? 0 : (q.held ? 1 : mq / (mp + mq))
        let wq = 1 - wp
        if ox < oy {
            let d = (dx >= 0 ? 1.0 : -1.0) * ox
            bodies[i].center.x -= d * wp
            bodies[j].center.x += d * wq
            if kick {
                bodies[i].velocity.dx -= d * wp * Self.kick
                bodies[j].velocity.dx += d * wq * Self.kick
            }
        } else {
            let d = (dy >= 0 ? 1.0 : -1.0) * oy
            bodies[i].center.y -= d * wp
            bodies[j].center.y += d * wq
            if kick {
                bodies[i].velocity.dy -= d * wp * Self.kick
                bodies[j].velocity.dy += d * wq * Self.kick
            }
        }
    }

    // MARK: Spatial grid

    /// Grid cell: at least twice the biggest regular sleeve, and always more than the largest actual sleeve plus the
    /// gap, so the 3x3 block of cells around a body holds every body it could touch.
    private func cellSize() -> Double {
        var largest = 0.0
        for b in bodies where b.side > largest { largest = b.side }
        return max(2 * maxSide, largest + Self.gap + 1)
    }

    private static func cellOf(_ c: CGPoint, _ cell: Double) -> (Int64, Int64) {
        (Int64((Double(c.x) / cell).rounded(.down)), Int64((Double(c.y) / cell).rounded(.down)))
    }

    private static func key(_ cx: Int64, _ cy: Int64) -> Int64 { (cx << 32) ^ (cy & 0xFFFF_FFFF) }

    /// Fills `grid` with every body tagged by its cell, sorted by (cell, index). Sorting by index within a cell keeps
    /// the visit order a pure function of the body order, so a run is reproducible. Reuses `grid`'s storage.
    private static func bin(_ bodies: [Body], cell: Double, into grid: inout [Entry]) {
        grid.removeAll(keepingCapacity: true)
        for i in bodies.indices {
            let (cx, cy) = cellOf(bodies[i].center, cell)
            grid.append(Entry(key: key(cx, cy), index: Int32(i)))
        }
        grid.sort { $0.key != $1.key ? $0.key < $1.key : $0.index < $1.index }
    }

    /// First position in `grid` whose key is at least `key`.
    private static func lowerBound(_ grid: [Entry], _ key: Int64) -> Int {
        var lo = 0
        var hi = grid.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if grid[mid].key < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Calls `visit(j)` for every other body `j > i` in the 3x3 cells around body `i`.
    private static func forEachNeighbour(
        of i: Int, in grid: [Entry], bodies: [Body], cell: Double, _ visit: (Int) -> Void
    ) {
        let (cx, cy) = cellOf(bodies[i].center, cell)
        for ix in (cx - 1)...(cx + 1) {
            for iy in (cy - 1)...(cy + 1) {
                let k = key(ix, iy)
                var q = lowerBound(grid, k)
                while q < grid.count && grid[q].key == k {
                    let j = Int(grid[q].index)
                    if j > i { visit(j) }
                    q += 1
                }
            }
        }
    }
}
