import PFAudio
import PFCore
import Synchronization

/// A host-side `AudioSessionControlling` that tests script by hand.
///
/// `rateResponse` plays the hardware: it maps the requested rate (or the preferred rate an activation brings) to the
/// rate the "device" settles on, which `sampleRate` then reports until the next request, or until a test moves it to
/// play a rate change under an unchanged port. All state sits behind one lock, so the class is checked `Sendable`.
/// `events` is single-consumer, like the real session's.
public final class FakeSession: AudioSessionControlling {
    private struct State {
        var requestedRates: [Int] = []
        var activationRates: [Int?] = []
        var currentPort: OutputPort = .builtIn
        var outputVolume: Float = 0.5
        var sampleRate = 48_000
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
    /// How many times `activate(preferredRate:)` was called.
    public var activationCount: Int { state.withLock { $0.activationRates.count } }
    /// The preferred rate of every activation, in order; nil for none.
    public var activationRates: [Int?] { state.withLock { $0.activationRates } }

    public var currentPort: OutputPort {
        get { state.withLock { $0.currentPort } }
        set { state.withLock { $0.currentPort = newValue } }
    }

    public var outputVolume: Float {
        get { state.withLock { $0.outputVolume } }
        set { state.withLock { $0.outputVolume = newValue } }
    }

    public var sampleRate: Int {
        get { state.withLock { $0.sampleRate } }
        set { state.withLock { $0.sampleRate = newValue } }
    }

    public func activate(preferredRate: Int?) async throws {
        let settled = preferredRate.map(rateResponse)
        state.withLock { s in
            s.activationRates.append(preferredRate)
            if let settled { s.sampleRate = settled }
        }
    }

    public func requestSampleRate(_ hz: Int) async -> Int {
        let rate = rateResponse(hz)
        state.withLock { s in
            s.requestedRates.append(hz)
            s.sampleRate = rate
        }
        return rate
    }

    /// Delivers `e` to the `events` consumer, as the real session would.
    public func emit(_ e: SessionEvent) {
        continuation.yield(e)
    }
}
