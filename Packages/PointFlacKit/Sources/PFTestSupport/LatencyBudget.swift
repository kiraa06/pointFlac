import Foundation

/// Wall-clock budgets in tests, scaled on shared CI runners (final review I8).
///
/// A budget test asserts the spec's figure (a 50 ms seek, a 150 ms first frame) on a developer's machine, where it is
/// a regression net. Hosted runners are noisy: the ledger measured a 50 ms seek at 23–28 ms under parallel load on a
/// developer's Mac alone. So under CI every budget is multiplied by 3 (spec §6.5: "CI uses tolerances because shared
/// runners are noisy"). Failure messages name the budget and the multiplier, so a CI failure says what it was held to.
///
/// Hang guards scale the same way: the timeouts of the tests' polling helpers and stress runs. On a 3-vCPU runner the
/// suites running alongside compete for the same threads and CPU, and the whole test process can stall for seconds.
public enum LatencyBudget {
    /// 3 under CI, 1 otherwise.
    public static let multiplier = multiplier(environment: ProcessInfo.processInfo.environment)

    /// 3 when `CI` is "true", 1 otherwise. GitHub Actions sets `CI`. `scripts/test.sh` forwards it to the simulator
    /// stages as `TEST_RUNNER_CI`, which xcodebuild passes to the test process as `CI`.
    public static func multiplier(environment: [String: String]) -> Int {
        environment["CI"] == "true" ? 3 : 1
    }

    /// `budget` × `multiplier`.
    public static func scaled(_ budget: Duration) -> Duration {
        budget * multiplier
    }

    /// For failure messages: "budget 150 ms (50 ms × 3)".
    public static func describe(_ budget: Duration) -> String {
        "budget \(milliseconds(scaled(budget))) (\(milliseconds(budget)) × \(multiplier))"
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return "\(seconds * 1_000 + attoseconds / 1_000_000_000_000_000) ms"
    }
}
