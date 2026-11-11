import CoreGraphics
import Foundation

/// The Shelf under a finger, kept out of the view so it can be tested: while the finger is down the panel follows it
/// point for point between fully open and fully closed, stretches with growing resistance past fully open, and never
/// goes below fully closed. Only when the finger lifts does it settle, at one end: the way a quick flick points;
/// otherwise wherever it would coast to, the nearer end (so a slow release past halfway goes on, short of it goes back).
///
/// Positions are the panel's offset down from fully open, in points: 0 is open, `travel` is closed (the panel's
/// height and whatever lies under it, so closed is wholly out of sight).
public enum ShelfTravel {
    /// The furthest past fully open the panel can be pulled, however far the finger goes.
    public static let stretchLimit: CGFloat = 36
    /// A release at least this fast, in points per second, goes the way it was going, wherever the panel is.
    public static let flickSpeed: CGFloat = 900
    /// The fastest the settle starts, in points per second, whatever the finger did.
    public static let maxSettleSpeed: CGFloat = 4000
    /// How far a release coasts per point per second of speed: UIKit's normal deceleration (a rate of 0.998 a
    /// millisecond), which a system sheet projects its release with too.
    static let coastSeconds: CGFloat = 0.998 / (1 - 0.998) / 1000

    /// Where the panel is: moved by the finger's vertical `translation` (negative is up) from `start`, where it rested
    /// when the finger took it (0 or `travel`). Past open it stretches, never further than `stretchLimit`; it stops at
    /// closed.
    public static func offset(
        start: CGFloat, translation: CGFloat, travel: CGFloat, stretchLimit: CGFloat = stretchLimit
    ) -> CGFloat {
        let raw = start + translation
        guard raw < 0 else { return min(raw, travel) }
        return -stretch(-raw, limit: stretchLimit)
    }

    /// A rubber band (UIScrollView's curve): about half the finger's distance at first, then less and less, never
    /// reaching `limit`.
    static func stretch(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        guard distance > 0, limit > 0 else { return 0 }
        return limit * (1 - 1 / (distance * 0.55 / limit + 1))
    }

    /// Whether a release at `offset`, moving at `velocity` (points per second, positive down), settles open; if not,
    /// it settles closed. A flick goes the way it points; anything slower goes to the end nearer where it would coast.
    public static func settlesOpen(offset: CGFloat, velocity: CGFloat, travel: CGFloat) -> Bool {
        if abs(velocity) >= flickSpeed { return velocity < 0 }
        return offset + velocity * coastSeconds < travel / 2
    }

    /// The settle's starting speed for a release at `offset`, moving at `velocity` (points per second, positive down),
    /// towards `target`: as a share of the distance left per second, which is how a SwiftUI spring takes it. Positive
    /// is towards the target.
    public static func springVelocity(offset: CGFloat, target: CGFloat, velocity: CGFloat) -> Double {
        let distance = target - offset
        guard abs(distance) >= 0.5 else { return 0 }
        let speed = min(max(velocity, -maxSettleSpeed), maxSettleSpeed)
        return Double(speed / distance)
    }
}
