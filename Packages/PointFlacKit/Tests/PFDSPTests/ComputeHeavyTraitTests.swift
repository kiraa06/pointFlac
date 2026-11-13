import PFTestSupport
import Testing

/// The heavy suites run on `ComputeQueue`, off the cooperative pool, and everything else stays where it was.
@Suite("Compute-heavy trait")
struct ComputeHeavyTraitTests {
    @Test(.computeHeavy) func aTaggedTestRunsOnTheComputeQueue() {
        #expect(ComputeQueue.isCurrent)
    }

    @Test func anUntaggedTestStaysOnThePool() {
        #expect(!ComputeQueue.isCurrent)
    }
}

@Suite("Compute-heavy suite", .computeHeavy)
struct ComputeHeavySuiteTests {
    @Test func aTestInATaggedSuiteRunsOnTheComputeQueue() {
        #expect(ComputeQueue.isCurrent)
    }

    @Test func soDoesAnAsyncOneAfterASuspension() async {
        await Task.yield()
        #expect(ComputeQueue.isCurrent)
    }
}
