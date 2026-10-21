import Foundation
import Testing

@testable import PFDesign

/// A band as the EQ graph's gestures see it: an id to tell bands apart, and the frequency the drag moves.
private struct Band: Equatable, Sendable {
    var id: Int
    var hz: Double
}

@Suite("EQ handle gesture session")
struct BandGestureSessionTests {
    private let bands = [Band(id: 0, hz: 100), Band(id: 1, hz: 1000), Band(id: 2, hz: 8000)]
    private let qs = [0.7, 1.0, 2.0]

    @Test("a drag keeps the band and grab it started with")
    func dragKeepsItsStart() {
        var s = BandGestureSession<Band>()
        let first = s.dragChanged(index: 1, band: bands[1], grabX: 3, grabY: -2)
        // Later events, whatever handle reports them, keep the first band and grab.
        let later = s.dragChanged(index: 2, band: bands[2], grabX: 9, grabY: 9)
        #expect(first?.index == 1)
        #expect(later?.index == 1)
        #expect(later?.origin == bands[1])
        #expect(later?.grabX == 3 && later?.grabY == -2)
        s.dragStopped()
        #expect(s.isIdle)
    }

    @Test("a cancelled drag leaves nothing for the next one")
    func cancelledDragStartsAfresh() {
        var s = BandGestureSession<Band>()
        _ = s.dragChanged(index: 1, band: bands[1], grabX: 3, grabY: -2)
        // The system cancels the drag: no onEnded, only the gesture flag resetting, which stops the drag.
        s.dragStopped()
        let next = s.dragChanged(index: 0, band: bands[0], grabX: 1, grabY: 1)
        #expect(next?.index == 0)
        #expect(next?.origin == bands[0])
        #expect(next?.grabX == 1)
    }

    @Test("a pinch during a drag shapes the dragged band, puts it back, and holds the drag")
    func pinchTakesOverADrag() {
        var s = BandGestureSession<Band>()
        _ = s.dragChanged(index: 1, band: bands[1], grabX: 0, grabY: 0)
        // The view would pick band 2 (the selection); the drag's band wins.
        let p = s.pinchChanged(choose: { 2 }, q: { qs[$0] })
        #expect(p?.pinch == .init(index: 1, q: 1.0))
        #expect(p?.restore == bands[1])
        #expect(s.dragChanged(index: 1, band: bands[1], grabX: 0, grabY: 0) == nil)
    }

    @Test("lifting the pinch first leaves the drag inert until its finger lifts")
    func pinchLiftsFirst() {
        var s = BandGestureSession<Band>()
        _ = s.dragChanged(index: 1, band: bands[1], grabX: 0, grabY: 0)
        _ = s.pinchChanged(choose: { nil }, q: { qs[$0] })
        s.pinchStopped()
        #expect(s.dragChanged(index: 1, band: bands[1], grabX: 0, grabY: 0) == nil)
        s.dragStopped()
        #expect(s.isIdle)
    }

    @Test("lifting the drag first ends the hold; the pinch then stops cleanly")
    func dragLiftsFirst() {
        var s = BandGestureSession<Band>()
        _ = s.dragChanged(index: 1, band: bands[1], grabX: 0, grabY: 0)
        _ = s.pinchChanged(choose: { nil }, q: { qs[$0] })
        s.dragStopped()
        // The pinch carries on alone, on the same band, with nothing to put back.
        let p = s.pinchChanged(choose: { 2 }, q: { qs[$0] })
        #expect(p?.pinch.index == 1)
        #expect(p?.restore == nil)
        s.pinchStopped()
        #expect(s.isIdle)
    }

    @Test("a pinch alone takes the band the view chooses, with its Q")
    func pinchAlone() {
        var s = BandGestureSession<Band>()
        let p = s.pinchChanged(choose: { 2 }, q: { qs[$0] })
        #expect(p?.pinch == .init(index: 2, q: 2.0))
        #expect(p?.restore == nil)
    }

    @Test("a cancelled pinch leaves nothing for the next one")
    func cancelledPinchStartsAfresh() {
        var s = BandGestureSession<Band>()
        _ = s.pinchChanged(choose: { 2 }, q: { qs[$0] })
        s.pinchStopped()
        let next = s.pinchChanged(choose: { 0 }, q: { qs[$0] })
        #expect(next?.pinch == .init(index: 0, q: 0.7))
    }

    @Test("reset clears a drag, a pinch and the hold at once")
    func resetClearsEverything() {
        var s = BandGestureSession<Band>()
        _ = s.dragChanged(index: 1, band: bands[1], grabX: 0, grabY: 0)
        _ = s.pinchChanged(choose: { nil }, q: { qs[$0] })
        s.reset()
        #expect(s.isIdle)
        #expect(s.dragChanged(index: 0, band: bands[0], grabX: 0, grabY: 0)?.index == 0)
    }

    @Test("no band to pinch: nothing starts")
    func nothingToPinch() {
        var s = BandGestureSession<Band>()
        #expect(s.pinchChanged(choose: { nil }, q: { qs[$0] }) == nil)
        #expect(s.isIdle)
    }
}
