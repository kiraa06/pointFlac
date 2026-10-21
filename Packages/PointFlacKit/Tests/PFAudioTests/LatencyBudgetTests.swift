import PFTestSupport
import Testing

/// The CI tolerance itself: ×3 only when `CI` says "true", and messages that name the budget and the multiplier.
@Suite struct LatencyBudgetTests {
    @Test func multipliesOnlyUnderCI() {
        #expect(LatencyBudget.multiplier(environment: ["CI": "true"]) == 3)
        #expect(LatencyBudget.multiplier(environment: [:]) == 1)
        #expect(LatencyBudget.multiplier(environment: ["CI": "false"]) == 1)
        #expect(LatencyBudget.multiplier(environment: ["CI": ""]) == 1)
    }

    @Test func scalesAndDescribesTheBudget() {
        let m = LatencyBudget.multiplier
        #expect(LatencyBudget.scaled(.milliseconds(50)) == .milliseconds(50 * m))
        #expect(LatencyBudget.describe(.milliseconds(50)) == "budget \(50 * m) ms (50 ms × \(m))")
    }
}
