/// One pipeline the player started, with what belongs to it: the lease through which it reaches the output, the task
/// reading its events, and the queue of calls into it.
@MainActor
final class PlayerEngine {
    let pipeline: PlaybackPipeline
    let lease: OutputLease
    let generation: UInt64
    var events: Task<Void, Never>?
    /// The pipeline has the queue, so its `position` means something.
    var hasStarted = false
    private(set) var isRetired = false
    private var lastCall: Task<Void, Never>?

    init(pipeline: PlaybackPipeline, lease: OutputLease, generation: UInt64) {
        self.pipeline = pipeline
        self.lease = lease
        self.generation = generation
    }

    /// Runs `call` once every call enqueued before it has finished. The pipeline's `start` and `seek` are nonisolated
    /// `async` methods, so two awaited from the main actor could reach it in either order, and a seek that lands
    /// before `start` is dropped.
    func enqueue(_ call: @escaping @Sendable @MainActor (PlaybackPipeline) async -> Void) -> Task<Void, Never> {
        let previous = lastCall
        let pipeline = self.pipeline
        let task = Task {
            await previous?.value
            await call(pipeline)
        }
        lastCall = task
        return task
    }

    /// Stops the pipeline for good. The lease is revoked after `stop()`, which must still reach the output.
    func retire() {
        isRetired = true
        pipeline.stop()
        lease.revoke()
        events?.cancel()
    }
}
