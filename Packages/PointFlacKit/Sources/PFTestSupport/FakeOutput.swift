import PFAudio
import PFCore
import Synchronization

/// A host-side `AudioOutput` that tests drive by hand: `pull(frames:)` plays the part of the render thread.
///
/// Only real audio is captured, the frames `RenderSource.render` reports and never underrun or hold silence, so exact
/// comparisons do not depend on how far ahead the decode thread happens to be. All state sits behind one lock. `pull`
/// holds it across `render`, so `stop()` waits for an in-flight pull, as RemoteIO's stop waits for its callback, and
/// tests may pull from any task while the decode thread drives the output.
public final class FakeOutput: AudioOutput, Sendable {
    private struct State {
        var source: RenderSource?
        var plan: OutputPlan?
        var channels = 0
        var started = false
        /// Preallocated in `configure`, sized for the largest pull.
        var buffer: UnsafeMutableRawPointer?
        var plans: [OutputPlan] = []
        var capturedFloat: [Float] = []
        var capturedInt32: [Int32] = []
        var hardwareSideSampleRate: Int?
    }

    public let maximumFramesPerPull: Int
    private let state = Mutex(State())

    public init(maximumFramesPerPull: Int = 4096) {
        self.maximumFramesPerPull = maximumFramesPerPull
    }

    deinit {
        state.withLock { $0.buffer?.deallocate() }
    }

    public var source: RenderSource? {
        get { state.withLock { $0.source } }
        set { state.withLock { $0.source = newValue } }
    }

    /// Every plan passed to `configure`, in order.
    public var plans: [OutputPlan] { state.withLock { $0.plans } }
    /// Real frames rendered while the configured client was Float32.
    public var capturedFloat: [Float] { state.withLock { $0.capturedFloat } }
    /// Real frames rendered while the configured client was Int32.
    public var capturedInt32: [Int32] { state.withLock { $0.capturedInt32 } }
    public var isStarted: Bool { state.withLock { $0.started } }

    /// What the output reports for its hardware side. Nil by default, like an output that cannot tell; a test sets a
    /// rate to play a device that resamples after the unit (ruling R17).
    public var hardwareSideSampleRate: Int? {
        get { state.withLock { $0.hardwareSideSampleRate } }
        set { state.withLock { $0.hardwareSideSampleRate = newValue } }
    }

    public func configure(_ plan: OutputPlan, channels: Int) throws {
        let byteCount = maximumFramesPerPull * channels * MemoryLayout<UInt32>.stride
        state.withLock { s in
            s.buffer?.deallocate()
            s.buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
            s.plan = plan
            s.channels = channels
            s.plans.append(plan)
        }
    }

    public func start() throws {
        state.withLock { $0.started = true }
    }

    public func stop() {
        state.withLock { $0.started = false }
    }

    /// One render callback of `frames` frames. Does nothing unless the output is started. Captures the real-audio
    /// prefix and returns its length in frames.
    @discardableResult
    public func pull(frames: Int) -> Int {
        precondition(frames <= maximumFramesPerPull, "pull(frames:) beyond maximumFramesPerPull")
        return state.withLock { s in
            guard s.started, let source = s.source, let buffer = s.buffer, let plan = s.plan else { return 0 }
            let real = source.render(into: buffer, frames: frames)
            let count = real * s.channels
            switch plan.client {
            case .float32:
                let values = buffer.bindMemory(to: Float.self, capacity: count)
                s.capturedFloat.append(contentsOf: UnsafeBufferPointer(start: values, count: count))
            case .int32:
                let values = buffer.bindMemory(to: Int32.self, capacity: count)
                s.capturedInt32.append(contentsOf: UnsafeBufferPointer(start: values, count: count))
            }
            return real
        }
    }
}
