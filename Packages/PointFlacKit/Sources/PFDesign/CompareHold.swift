import Foundation

/// The Sound tab's hold-to-compare button (Task 14), kept out of the view so that every way a press can end releases
/// it the same way: the finger lifts (`onEnded`); the system cancels the touch (a lock, a system gesture, an alert:
/// `onEnded` never runs, and the view learns of it only from a `@GestureState` flag resetting, which it reports as a
/// lift); or something ends the hold under the finger (the app leaves the foreground, the tab goes away, the output
/// route changes, comparing stops being available), which is an interruption.
///
/// After an interruption the finger still down is ignored until it lifts, so a hold the app ended can't come back by
/// itself on the finger's next move. VoiceOver users can't hold, so VoiceOver's activate latches and unlatches instead.
public struct CompareHold: Sendable, Equatable {
    /// The original is playing: a finger holds the button, or VoiceOver latched it.
    public private(set) var isHeld = false
    /// A finger is down on the button.
    private var touching = false
    /// The hold was ended under a finger still down: that finger can't take hold again until it lifts.
    private var cutShort = false

    public init() {}

    /// A finger is on the button: its touch-down, or any move. It takes hold if comparing is `available`, unless the
    /// app cut this finger's hold short; a hold that finds comparing unavailable ends, as an interruption. Returns
    /// whether `isHeld` changed.
    @discardableResult
    public mutating func touch(available: Bool) -> Bool {
        touching = true
        guard available else { return interrupt() }
        guard !isHeld, !cutShort else { return false }
        isHeld = true
        return true
    }

    /// The finger lifted, or the system cancelled the touch. Returns whether `isHeld` changed.
    @discardableResult
    public mutating func lift() -> Bool {
        touching = false
        cutShort = false
        return release()
    }

    /// Something ended the hold: the app left the foreground, the tab went away, the route changed, or comparing
    /// stopped being available. A finger still down is ignored until it lifts. Returns whether `isHeld` changed.
    @discardableResult
    public mutating func interrupt() -> Bool {
        if touching, isHeld { cutShort = true }
        return release()
    }

    /// VoiceOver's activate: latches the original on, or off again. Returns whether `isHeld` changed.
    @discardableResult
    public mutating func toggle(available: Bool) -> Bool {
        guard isHeld || available else { return false }
        isHeld.toggle()
        return true
    }

    private mutating func release() -> Bool {
        guard isHeld else { return false }
        isHeld = false
        return true
    }
}
