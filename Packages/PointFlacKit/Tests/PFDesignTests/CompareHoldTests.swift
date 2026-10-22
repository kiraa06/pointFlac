import Testing

@testable import PFDesign

/// The Sound tab's hold-to-compare button: held while a finger is down, and released by every way a press can end:
/// the finger lifting, the system cancelling the touch (the view learns of it from a `@GestureState` reset), the app
/// leaving the foreground, the tab going away, the route changing, or comparing becoming unavailable.
@Suite("Hold to compare")
struct CompareHoldTests {
    @Test("a finger down holds, its moves keep holding, and lifting it releases")
    func pressAndLift() {
        var hold = CompareHold()
        var changed = hold.touch(available: true)
        #expect(changed)
        #expect(hold.isHeld)
        // Every later move of the same finger reports again: no change.
        changed = hold.touch(available: true)
        #expect(!changed)
        #expect(hold.isHeld)
        changed = hold.lift()
        #expect(changed)
        #expect(!hold.isHeld)
        // A second lift (the gesture's end, then its flag's reset) changes nothing.
        changed = hold.lift()
        #expect(!changed)
    }

    @Test("a touch while comparing is unavailable (Pure, no chain, nothing playing) holds nothing")
    func unavailableHoldsNothing() {
        var hold = CompareHold()
        var changed = hold.touch(available: false)
        #expect(!changed)
        #expect(!hold.isHeld)
        // It becomes available under the same finger: that finger takes hold.
        changed = hold.touch(available: true)
        #expect(changed)
        #expect(hold.isHeld)
    }

    @Test("a cancelled touch releases: the gesture flag's reset reports it as a lift")
    func cancelReleases() {
        var hold = CompareHold()
        hold.touch(available: true)
        // The system cancelled the touch: `onEnded` never runs, the `@GestureState` flag resets, the view lifts.
        var changed = hold.lift()
        #expect(changed)
        #expect(!hold.isHeld)
        // A new touch holds again.
        changed = hold.touch(available: true)
        #expect(changed)
    }

    /// The finger still down can't take hold again until it lifts.
    @Test("an interruption (the background, the tab going away, a route change) releases until the finger lifts")
    func interruptionReleasesUntilTheFingerLifts() {
        var hold = CompareHold()
        hold.touch(available: true)
        var changed = hold.interrupt()
        #expect(changed)
        #expect(!hold.isHeld)
        // The same finger moves on: no hold.
        changed = hold.touch(available: true)
        #expect(!changed)
        #expect(!hold.isHeld)
        // It lifts; the next touch holds.
        changed = hold.lift()
        #expect(!changed)
        changed = hold.touch(available: true)
        #expect(changed)
        #expect(hold.isHeld)
    }

    @Test("an interruption with no finger down changes nothing, and leaves the next touch free")
    func interruptionAtRest() {
        var hold = CompareHold()
        var changed = hold.interrupt()
        #expect(!changed)
        changed = hold.touch(available: true)
        #expect(changed)
    }

    @Test("comparing becoming unavailable under the finger releases it, as an interruption")
    func becomingUnavailableReleases() {
        var hold = CompareHold()
        hold.touch(available: true)
        // The next move finds comparing unavailable (Pure switched on by another finger, playback stopped).
        var changed = hold.touch(available: false)
        #expect(changed)
        #expect(!hold.isHeld)
        changed = hold.touch(available: true)
        #expect(!changed, "the finger that was cut short took hold again")
        hold.lift()
        changed = hold.touch(available: true)
        #expect(changed)
    }

    @Test("VoiceOver's activate latches and unlatches, since a VoiceOver user can't hold; an interruption unlatches")
    func voiceOverLatches() {
        var hold = CompareHold()
        var changed = hold.toggle(available: false)
        #expect(!changed)
        changed = hold.toggle(available: true)
        #expect(changed)
        #expect(hold.isHeld)
        changed = hold.toggle(available: true)
        #expect(changed)
        #expect(!hold.isHeld)
        hold.toggle(available: true)
        changed = hold.interrupt()
        #expect(changed)
        #expect(!hold.isHeld)
        // No finger was down, so nothing is cut short.
        changed = hold.touch(available: true)
        #expect(changed)
    }
}
