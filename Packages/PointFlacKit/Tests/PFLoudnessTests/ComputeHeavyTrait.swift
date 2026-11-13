import PFTestSupport
import Testing

/// Runs a CPU-heavy suite or test on `ComputeQueue`, off the cooperative pool (see `ComputeQueue`). The same trait is
/// declared in PFDSPTests: a trait needs `Testing`, which the shared support module does not link.
struct ComputeHeavyTrait: SuiteTrait, TestTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await onComputeQueue { try await function() }
    }
}

extension Trait where Self == ComputeHeavyTrait {
    /// Heavy signal processing: run it on `ComputeQueue`, not the cooperative pool.
    static var computeHeavy: Self { Self() }
}
