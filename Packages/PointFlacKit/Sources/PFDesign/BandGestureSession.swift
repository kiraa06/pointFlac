import Foundation

/// What an EQ graph's handle drag and pinch hold while they run, kept out of the view so that every way a gesture can
/// stop puts it back to rest the same way: the finger lifts (`onEnded`), the system cancels the touches (a lock, a
/// system gesture, an alert: `onEnded` never runs, and the view learns of it only from a `@GestureState` flag
/// resetting), the app leaves the foreground, or the graph goes away.
///
/// One finger on a handle drags that band. A pinch shapes the Q of one band: the one being dragged when there is one,
/// else the band the view picks (the selected one, else the nearest). A pinch that takes over a drag hands back the
/// band as the drag found it, to undo the first finger's stray move, and holds the drag inert until its finger lifts.
public struct BandGestureSession<Band: Sendable>: Sendable {
    public struct Drag: Sendable {
        public let index: Int
        /// The band as the drag found it.
        public let origin: Band
        /// Where the finger took hold, relative to the band's centre, in points.
        public let grabX: Double
        public let grabY: Double
    }

    public struct Pinch: Sendable, Equatable {
        public let index: Int
        /// The band's Q when the pinch began: the pinch scales it.
        public let q: Double
    }

    public private(set) var drag: Drag?
    public private(set) var pinch: Pinch?
    /// A pinch happened during the current drag, which stays inert until its finger lifts.
    public private(set) var pinched = false

    public init() {}

    /// A drag on the handle of band `index` moved. Its first call starts the drag, from `band` and the grab offset;
    /// later calls keep that start, whichever handle reports them. Returns the drag to apply, or nil while a pinch
    /// holds it inert.
    public mutating func dragChanged(index: Int, band: Band, grabX: Double, grabY: Double) -> Drag? {
        guard !pinched else { return nil }
        if drag == nil { drag = Drag(index: index, origin: band, grabX: grabX, grabY: grabY) }
        return drag
    }

    /// The drag's finger lifted, or the system cancelled the drag.
    public mutating func dragStopped() {
        drag = nil
        pinched = false
    }

    /// A pinch moved. Its first call starts the pinch on the dragged band, if a drag is running, else on the band
    /// `choose` returns, with that band's Q from `q`. Returns the pinch to apply, and the band to put back first when
    /// the pinch shapes a band being dragged; nil when there is no band to pinch.
    public mutating func pinchChanged(
        choose: () -> Int?, q: (Int) -> Double?
    ) -> (pinch: Pinch, restore: Band?)? {
        if pinch == nil {
            guard let index = drag?.index ?? choose(), let startQ = q(index) else { return nil }
            pinch = Pinch(index: index, q: startQ)
            if drag != nil { pinched = true }
        }
        guard let pinch else { return nil }
        let restore = drag.flatMap { $0.index == pinch.index ? $0.origin : nil }
        return (pinch, restore)
    }

    /// The pinch's fingers lifted, or the system cancelled it. A drag it took over stays inert until its own finger
    /// lifts.
    public mutating func pinchStopped() {
        pinch = nil
        if drag == nil { pinched = false }
    }

    /// The app left the foreground or the graph went away: nothing a gesture held survives.
    public mutating func reset() {
        drag = nil
        pinch = nil
        pinched = false
    }

    /// True while no gesture holds anything.
    public var isIdle: Bool { drag == nil && pinch == nil && !pinched }
}
