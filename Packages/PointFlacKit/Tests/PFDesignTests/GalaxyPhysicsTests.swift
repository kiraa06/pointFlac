import CoreGraphics
import Foundation
import Testing

@testable import PFDesign

@Suite("Galaxy physics")
struct GalaxyPhysicsTests {
    private func physics(count: Int = 38) -> GalaxyPhysics {
        GalaxyPhysics(slots: GalaxyLayout.place(count: count))
    }

    private func overlaps(_ p: GalaxyPhysics, gap: Double = 6 - 1e-3) -> Bool {
        for i in p.bodies.indices {
            for j in (i + 1)..<max(i + 1, p.bodies.count) {
                let a = p.bodies[i]
                let b = p.bodies[j]
                let need = (a.side + b.side) / 2 + gap
                if abs(Double(a.center.x - b.center.x)) < need && abs(Double(a.center.y - b.center.y)) < need {
                    return true
                }
            }
        }
        return false
    }

    /// Drags the biggest sleeve across the galaxy in 60 steps, easing to a stop, and lets go.
    private func dragAndRelease(_ p: inout GalaxyPhysics) -> CGPoint {
        let start = p.bodies[0].center
        let end = CGPoint(x: start.x + 260, y: start.y + 150)
        p.bodies[0].held = true
        for k in 1...60 {
            let t = Double(k) / 60
            let e = t * t * (3 - 2 * t)
            p.step(holdTarget: CGPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e))
        }
        p.bodies[0].held = false
        return end
    }

    @Test("a held sleeve shoves the others aside and the galaxy settles apart")
    func heldBodyShovesOthersWithoutOverlap() {
        var p = physics()
        _ = dragAndRelease(&p)
        var steps = 0
        while !p.isSettled && steps < 600 {
            p.step(holdTarget: nil)
            steps += 1
        }
        #expect(p.isSettled)
        #expect(!overlaps(p))
    }

    @Test("a dropped sleeve stays where it was let go")
    func droppedBodyStays() {
        var p = physics()
        _ = dragAndRelease(&p)
        let letGo = p.bodies[0].center
        let v = p.bodies[0].velocity
        // Damping 0.90 per step: a sleeve at speed s coasts at most s / (1 - 0.90) further.
        let coast = Double(hypot(v.dx, v.dy)) / 0.10
        var steps = 0
        while !p.isSettled && steps < 600 {
            p.step(holdTarget: nil)
            steps += 1
        }
        let moved = Double(hypot(p.bodies[0].center.x - letGo.x, p.bodies[0].center.y - letGo.y))
        #expect(moved <= 2 + coast)
        #expect(p.bodies[0].center.x > 100)  // it did not spring back to the middle
    }

    @Test("a laid-out galaxy with nothing held does not move")
    func restingBodiesDoNotMove() {
        var p = physics()
        let before = p.bodies.map(\.center)
        for _ in 0..<100 { p.step(holdTarget: nil) }
        let worst = zip(before, p.bodies).map { Double(hypot($0.x - $1.center.x, $0.y - $1.center.y)) }.max() ?? 0
        #expect(worst < 0.01)
        #expect(p.isSettled)
    }

    @Test("drifting homes never touch")
    func driftNeverTouches() {
        let slots = GalaxyLayout.place(count: 38)
        let seeds = slots.indices.map { Drift.seed(for: "album-\($0)") }
        for sample in 0..<200 {
            let time = Double(sample) * 1.7
            let moved = slots.indices.map { i -> CGPoint in
                let d = Drift.offset(seed: seeds[i], time: time)
                #expect(abs(Double(d.dx)) <= 4 && abs(Double(d.dy)) <= 4)
                return CGPoint(x: slots[i].center.x + d.dx, y: slots[i].center.y + d.dy)
            }
            for i in slots.indices {
                for j in (i + 1)..<max(i + 1, slots.count) {
                    let need = (slots[i].side + slots[j].side) / 2
                    let dx = abs(Double(moved[i].x - moved[j].x))
                    let dy = abs(Double(moved[i].y - moved[j].y))
                    let clear = dx > need || dy > need
                    #expect(clear)
                }
            }
        }
    }

    @Test("drift is deterministic and the seed helper is stable")
    func driftDeterministic() {
        #expect(Drift.offset(seed: 7, time: 12.5) == Drift.offset(seed: 7, time: 12.5))
        #expect(Drift.seed(for: "a") == Drift.seed(for: "a"))
        #expect(Drift.seed(for: "a") != Drift.seed(for: "b"))
        // FNV-1a 64 of the empty string is its offset basis.
        #expect(Drift.seed(for: "") == 0xcbf2_9ce4_8422_2325)
    }
}
