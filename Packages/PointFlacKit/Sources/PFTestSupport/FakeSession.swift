import PFAudio
import PFCore
import Synchronization

/// A host-side `AudioSessionControlling` that tests script by hand.
///
/// `rateResponse` plays the hardware: it maps the requested rate to the rate the "device" settles on. All state sits
/// behind one lock, so the class is checked `Sendable`. `events` is single-consumer, like the real session's.
public final class FakeSession: AudioSessionControlling {
    private struct State {
        var requestedRates: [Int] = []
        var activationCount = 0
        var currentPort: OutputPort = .builtIn
        var outputVolume: Float = 0.5
    }

    public let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let rateResponse: @Sendable (Int) -> Int
    private let state = Mutex(State())

    public init(rateResponse: @escaping @Sendable (Int) -> Int = { $0 }) {
        self.rateResponse = rateResponse
        (events, continuation) = AsyncStream<SessionEvent>.makeStream()
    }

    deinit {
        continuation.finish()
    }

    /// Every rate passed to `requestSampleRate`, in order.
    public var requestedRates: [Int] { state.withLock { $0.requestedRates } }
    /// How many times `activate()` was called.
    public var activationCount: Int { state.withLock { $0.activationCount } }

    public var currentPort: OutputPort {
        get { state.withLock { $0.currentPort } }
        set { state.withLock { $0.currentPort = newValue } }
    }

    public var outputVolume: Float {
        get { state.withLock { $0.outputVolume } }
        set { state.withLock { $0.outputVolume = newValue } }
    }

    public func activate() async throws {
        state.withLock { $0.activationCount += 1 }
    }

    public func requestSampleRate(_ hz: Int) async -> Int {
        state.withLock { $0.requestedRates.append(hz) }
        return rateResponse(hz)
    }

    /// Delivers `e` to the `events` consumer, as the real session would.
    public func emit(_ e: SessionEvent) {
        continuation.yield(e)
    }
}
