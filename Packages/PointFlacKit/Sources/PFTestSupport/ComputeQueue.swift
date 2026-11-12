import Foundation

/// The executor the CPU-heavy suites run on, so they never fill the cooperative pool.
///
/// Swift Testing runs every test on the cooperative pool, which is only as wide as the CPU count, and a synchronous
/// test holds its thread until it returns. The signal-processing suites (the sound chain, the level-matched A/B, the
/// loudness meter, the true-peak limiter, the matched biquads and the resampler's quality checks) are about 50 s of
/// single-thread CPU in a debug build. In a full parallel run they took every pool thread at once, and for about 20 s
/// nothing else in the process could run: tests waiting on a stubbed network reply, a coordination timeout or a
/// cancellation saw their own timers fire first and failed (`.offline`, a move that should have timed out, …).
///
/// Jobs here run on an operation queue at most half the CPU count wide (at least 2), so the heavy suites get CPU and
/// the pool stays free for everyone else. They run at utility QoS: below the pool's default, so a test waiting on a
/// timer is never queued behind them, and level with the library's own queue, whose coordinated moves the trash tests
/// time. Use `onComputeQueue(_:)`, or a suite trait built on it.
public final class ComputeQueue: TaskExecutor {
    public static let shared = ComputeQueue()

    /// How many jobs run at once: half the active CPUs, at least 2.
    public static let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

    private let queue: OperationQueue

    /// Whether the caller is running on this queue, and so not on a cooperative-pool thread.
    public static var isCurrent: Bool { OperationQueue.current === shared.queue }

    private init() {
        let queue = OperationQueue()
        queue.name = "io.github.kiraa06.pointflac.tests.compute"
        queue.maxConcurrentOperationCount = Self.width
        queue.qualityOfService = .utility
        self.queue = queue
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.addOperation { job.runSynchronously(on: executor) }
    }
}

/// Runs `body`, and the nonisolated async code it calls (a synchronous test function included), on `ComputeQueue`.
public func onComputeQueue(_ body: () async throws -> Void) async rethrows {
    try await withTaskExecutorPreference(ComputeQueue.shared, operation: body)
}
