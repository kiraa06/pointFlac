import CoreGraphics
import Foundation
import Testing

@testable import PFDesign

@Suite("Galaxy layout")
struct GalaxyLayoutTests {
    private let metrics = GalaxyMetrics()

    @Test("rank 0 is at the centre and the biggest")
    func rankZeroIsAtTheCentreAndBiggest() {
        let slots = GalaxyLayout.place(count: 38)
        #expect(slots[0].center == .zero)
        #expect(slots[0].side == metrics.coreSide)
        #expect(slots.dropFirst().allSatisfy { $0.side < slots[0].side })
    }

    @Test("no two slots touch, at any size of library", arguments: [1, 2, 3, 38, 1000])
    func noTwoSlotsTouch(count: Int) {
        let slots = GalaxyLayout.place(count: count)
        #expect(slots.count == count)
        var worst = Double.infinity
        for i in slots.indices {
            for j in (i + 1)..<max(i + 1, slots.count) {
                let a = slots[i]
                let b = slots[j]
                let need = (a.side + b.side) / 2 + metrics.gap
                // Free means clear on at least one axis, so the pair's margin is the larger of the two axis margins.
                let marginX = abs(Double(a.center.x - b.center.x)) - need
                let marginY = abs(Double(a.center.y - b.center.y)) - need
                worst = min(worst, max(marginX, marginY))
            }
        }
        #expect(count == 1 || worst >= -1e-9)
    }

    @Test("lower ranks sit nearer the middle")
    func nearnessFollowsRank() {
        let slots = GalaxyLayout.place(count: 38)
        func mean(_ range: ClosedRange<Int>) -> Double {
            let d = range.map { Double(hypot(slots[$0].center.x, slots[$0].center.y)) }
            return d.reduce(0, +) / Double(d.count)
        }
        #expect(mean(1...5) < mean(30...37))
    }

    @Test("sides shrink with rank and never go below the minimum")
    func sidesShrinkWithRankAndNeverGoBelowMin() {
        let slots = GalaxyLayout.place(count: 200)
        for i in 1..<slots.count {
            #expect(slots[i].side <= slots[i - 1].side)
            #expect(slots[i].side >= metrics.minSide)
        }
        #expect(metrics.side(rank: 0, scale: 0.5) == metrics.coreSide * 0.5)
        #expect(metrics.side(rank: 1, scale: 1) <= metrics.maxSide)
    }

    @Test("the same count gives bit-identical slots")
    func deterministic() {
        #expect(GalaxyLayout.place(count: 120) == GalaxyLayout.place(count: 120))
    }

    @Test("the gap covers two sleeves drifting together, which Drift's fixed amplitude of 4 relies on")
    func gapCoversDrift() {
        #expect(metrics.driftAmplitude == 4)
        #expect(metrics.gap >= 2 * 4 + 6)
    }

    @Test("an empty library places nothing")
    func empty() {
        #expect(GalaxyLayout.place(count: 0).isEmpty)
    }

    @Test("1,000 albums place quickly even in a Debug host test")
    func thousandAlbumsPlaceQuickly() {
        let clock = ContinuousClock()
        let took = clock.measure { _ = GalaxyLayout.place(count: 1000) }
        #expect(took < .seconds(1))
    }
}
