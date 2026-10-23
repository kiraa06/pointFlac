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

    public init(bodies: [Body]) {
        self.bodies = bodies
    }

    public init(slots: [GalaxySlot]) {
        self.bodies = slots.map { Body(center: $0.center, side: $0.side) }
    }

    /// True when nothing is moving noticeably and no two sleeves overlap, so the view can stop stepping.
    public var isSettled: Bool {
        for b in bodies where hypot(b.velocity.dx, b.velocity.dy) >= Self.restSpeed { return false }
        var settled = true
        forEachPair { i, j in
            let a = bodies[i]
            let b = bodies[j]
            let need = (a.side + b.side) / 2 + Self.gap - Self.tolerance
            if abs(a.center.x - b.center.x) < need && abs(a.center.y - b.center.y) < need { settled = false }
        }
        return settled
    }

    /// Advances one frame. The held body moves to `holdTarget` (it stays put without one) and its velocity becomes
    /// that move, so letting go throws it naturally. The others coast with damping, then four separation passes
    /// resolve overlaps.
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
        for pass in 0..<Self.passes {
            forEachPair { i, j in separate(i, j, kick: pass == 0) }
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

    /// Calls `visit(i, j)` with `i < j` for every pair close enough to touch, found through a uniform grid so 1,000
    /// sleeves don't cost a million comparisons. The cell is twice the largest sleeve, so a 3×3 block of cells holds
    /// every possible partner. Visit order depends only on body order, so a run is reproducible.
    private func forEachPair(_ visit: (Int, Int) -> Void) {
        let largest = bodies.reduce(0) { max($0, $1.side) }
        let cell = max(2 * 96, largest + Self.gap + 1)
        func index(_ v: CGFloat) -> Int64 { Int64((Double(v) / cell).rounded(.down)) }
        func key(_ cx: Int64, _ cy: Int64) -> Int64 { (cx << 32) ^ (cy & 0xFFFF_FFFF) }
        var cells: [Int64: [Int]] = [:]
        for i in bodies.indices {
            cells[key(index(bodies[i].center.x), index(bodies[i].center.y)), default: []].append(i)
        }
        for i in bodies.indices {
            let cx = index(bodies[i].center.x)
            let cy = index(bodies[i].center.y)
            for ix in (cx - 1)...(cx + 1) {
                for iy in (cy - 1)...(cy + 1) {
                    guard let members = cells[key(ix, iy)] else { continue }
                    for j in members where j > i { visit(i, j) }
                }
            }
        }
    }
}
