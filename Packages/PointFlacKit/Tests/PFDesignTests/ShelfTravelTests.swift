import CoreGraphics
import Testing

@testable import PFDesign

/// The Shelf under a finger: it follows the finger between open and closed, stretches with resistance past open and
/// never goes past closed; on release a quick flick goes the way it points, otherwise the nearer end wins.
@Suite("Shelf travel")
struct ShelfTravelTests {
    /// About an iPhone's: the panel's height plus the tab bar's inset under it.
    let travel: CGFloat = 620

    @Test("between open and closed the panel follows the finger point for point")
    func followsTheFinger() {
        #expect(ShelfTravel.offset(start: travel, translation: -120, travel: travel) == travel - 120)
        #expect(ShelfTravel.offset(start: travel, translation: -travel, travel: travel) == 0)
        #expect(ShelfTravel.offset(start: 0, translation: 200, travel: travel) == 200)
        #expect(ShelfTravel.offset(start: 0, translation: 0, travel: travel) == 0)
    }

    @Test("it never goes below the fully closed edge, however far the finger pulls down")
    func stopsAtClosed() {
        #expect(ShelfTravel.offset(start: 0, translation: travel + 300, travel: travel) == travel)
        #expect(ShelfTravel.offset(start: travel, translation: 80, travel: travel) == travel)
    }

    @Test("past open it rubber-bands: it moves, less than the finger, less and less, and never past the limit")
    func rubberBandsPastOpen() {
        let limit: CGFloat = 30
        var last: CGFloat = 0
        for over in stride(from: CGFloat(10), through: 3000, by: 10) {
            let offset = ShelfTravel.offset(start: 0, translation: -over, travel: travel, stretchLimit: limit)
            let stretch = -offset
            #expect(stretch > last, "it stopped moving \(over) pt past open")
            #expect(stretch < over)
            #expect(stretch < limit)
            last = stretch
        }
        // Each further point of finger travel moves the panel less than the one before.
        let first = -ShelfTravel.offset(start: 0, translation: -20, travel: travel, stretchLimit: limit)
        let second = -ShelfTravel.offset(start: 0, translation: -40, travel: travel, stretchLimit: limit) - first
        #expect(second < first)
        // No stretch at all where there is no room for it.
        #expect(ShelfTravel.offset(start: 0, translation: -100, travel: travel, stretchLimit: 0) == 0)
    }

    @Test("a slow release past halfway goes on; short of halfway it goes back")
    func slowReleaseGoesToTheNearerEnd() {
        // Opening from closed: let go past halfway up opens, short of it closes again.
        #expect(ShelfTravel.settlesOpen(offset: travel * 0.4, velocity: 0, travel: travel))
        #expect(!ShelfTravel.settlesOpen(offset: travel * 0.6, velocity: 0, travel: travel))
        // Closing from open: let go past halfway down closes, short of it opens again.
        #expect(!ShelfTravel.settlesOpen(offset: travel * 0.7, velocity: 0, travel: travel))
        #expect(ShelfTravel.settlesOpen(offset: travel * 0.2, velocity: 0, travel: travel))
        // Stretched past open, it goes back to open; held at closed, it stays closed.
        #expect(ShelfTravel.settlesOpen(offset: -20, velocity: 0, travel: travel))
        #expect(!ShelfTravel.settlesOpen(offset: travel, velocity: 0, travel: travel))
        // A slow drift does not change the answer far from halfway.
        #expect(!ShelfTravel.settlesOpen(offset: travel * 0.8, velocity: -60, travel: travel))
        #expect(ShelfTravel.settlesOpen(offset: travel * 0.2, velocity: 60, travel: travel))
    }

    @Test("a quick flick beats the position, both ways")
    func flickBeatsPosition() {
        // A short flick up from nearly closed opens.
        #expect(ShelfTravel.settlesOpen(offset: travel - 40, velocity: -1200, travel: travel))
        // A short flick down from nearly open closes.
        #expect(!ShelfTravel.settlesOpen(offset: 40, velocity: 1200, travel: travel))
        // Dragged past halfway one way, flicked back the other: the flick wins.
        #expect(!ShelfTravel.settlesOpen(offset: travel * 0.3, velocity: 900, travel: travel))
        #expect(ShelfTravel.settlesOpen(offset: travel * 0.7, velocity: -900, travel: travel))
        // However large the shelf, a flick at flick speed wins.
        let tall: CGFloat = 4000
        #expect(ShelfTravel.settlesOpen(offset: tall - 10, velocity: -ShelfTravel.flickSpeed, travel: tall))
        #expect(!ShelfTravel.settlesOpen(offset: 10, velocity: ShelfTravel.flickSpeed, travel: tall))
    }

    @Test("a moderate release coasts: where it would coast to decides")
    func moderateReleaseCoasts() {
        // Let go a little short of halfway, still moving up: it coasts past halfway and opens.
        #expect(ShelfTravel.settlesOpen(offset: travel * 0.55, velocity: -300, travel: travel))
        // The same place moving down: it closes.
        #expect(!ShelfTravel.settlesOpen(offset: travel * 0.45, velocity: 300, travel: travel))
    }

    @Test("the settle carries the finger's speed, as a share of the distance left")
    func springVelocity() {
        // Closing from 120 pt down at 500 pt/s: 500 pt/s over the 500 pt left is 1 distance per second.
        #expect(ShelfTravel.springVelocity(offset: 120, target: travel, velocity: 500) == 1)
        // Opening from 300 pt down at 600 pt/s up: 2 distances per second, towards the target.
        #expect(ShelfTravel.springVelocity(offset: 300, target: 0, velocity: -600) == 2)
        // Moving away from the target counts against it.
        #expect(ShelfTravel.springVelocity(offset: 300, target: 0, velocity: 150) == -0.5)
        // Already there: nothing to carry.
        #expect(ShelfTravel.springVelocity(offset: 0, target: 0, velocity: 800) == 0)
        // A wild speed is held to a sane one.
        let wild = ShelfTravel.springVelocity(offset: 100, target: 0, velocity: -1_000_000)
        #expect(wild == Double(ShelfTravel.maxSettleSpeed / 100))
    }
}
