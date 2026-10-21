import Foundation

/// The crate → deck hand-off (spec §4.5) as a pure function of time.
///
/// Why a timeline rather than chained SwiftUI animations: every step reads its progress from one clock, so the
/// choreography holds Kiran's exact timings at any frame rate, a second tap can jump to the end in one assignment, and
/// the whole thing is testable on the host. The base timings are the browser sketch's; `pace` 3 is "Slow-mo ×3",
/// Kiran's choice: about 3.5 s until the platter spins, and the tonearm settled at about 4.7 s.
public struct HandoffTimeline: Sendable, Equatable {
    public enum Step: CaseIterable, Sendable {
        /// The sleeve lifts toward you.
        case lift
        /// The record slides up out of the sleeve.
        case slide
        /// The shelf sinks away.
        case sink
        /// The record arcs to the platter, growing and turning, with a spring settle on the spindle.
        case arc
        /// The title and artist fade in under the deck.
        case title
        /// The tonearm swings to the lead-in.
        case arm
    }

    public let pace: Double

    public init(pace: Double = 3) {
        self.pace = pace
    }

    /// Start and length of each step in the sketch, in seconds at pace 1.
    private static func base(_ step: Step) -> (start: Double, length: Double) {
        switch step {
        case .lift: (0, 0.18)
        case .slide: (0.18, 0.30)
        case .sink: (0.45, 0.52)
        case .arc: (0.45, 0.52)
        case .title: (0.95, 0.26)
        case .arm: (1.15, 0.42)
        }
    }

    public func start(_ step: Step) -> Double { Self.base(step).start * pace }
    public func end(_ step: Step) -> Double { (Self.base(step).start + Self.base(step).length) * pace }

    /// The record lands on the spindle: the soft thump, and the dot-matrix screen wakes.
    public var landTime: Double { end(.arc) }
    /// The platter starts to spin up.
    public var spinTime: Double { start(.arm) }
    /// The tonearm has settled on the lead-in: the needle drops and play starts.
    public var duration: Double { end(.arm) }

    /// Linear progress of `step` at `t`, 0 before it starts and 1 after it ends.
    public func linear(_ step: Step, at t: Double) -> Double {
        let length = end(step) - start(step)
        guard length > 0 else { return t >= start(step) ? 1 : 0 }
        return min(max((t - start(step)) / length, 0), 1)
    }

    /// Eased progress of `step` at `t`: the sketch's ease for the slides, and a damped spring (which overshoots a
    /// little, then settles) for the arc onto the spindle and the tonearm.
    public func progress(_ step: Step, at t: Double) -> Double {
        let x = linear(step, at: t)
        switch step {
        case .arc, .arm: return Easing.spring(x)
        default: return Easing.easeOut(x)
        }
    }
}

/// Easing curves shared by the deck's motion.
public enum Easing {
    /// The sketch's `cubic-bezier(.25, .8, .25, 1)`: a fast start and a long, soft landing.
    public static func easeOut(_ x: Double) -> Double {
        cubicBezier(x, 0.25, 0.8, 0.25, 1)
    }

    /// A damped spring from 0 to 1 over x in 0...1 (ζ = 0.7, about 5 % overshoot), exactly 1 at the end.
    public static func spring(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let zeta = 0.7
        let omega = 9.0
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * x)
        return 1 - decay * (cos(damped * x) + zeta * omega / damped * sin(damped * x))
    }

    /// CSS-style cubic Bézier timing: solves x(s) = `x` by Newton's method, then returns y(s).
    public static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        func bez(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        func slope(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * p1 + 6 * (1 - s) * s * (p2 - p1) + 3 * s * s * (1 - p2)
        }
        var s = x
        for _ in 0..<8 {
            let err = bez(s, x1, x2) - x
            let d = slope(s, x1, x2)
            guard abs(d) > 1e-6 else { break }
            s = min(max(s - err / d, 0), 1)
        }
        return bez(s, y1, y2)
    }
}
