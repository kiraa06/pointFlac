import Synchronization

/// Serialises the player's calls into the audio session: every rate negotiation, from whichever pipeline asks, and
/// every activation. One call at a time, in the order the calls arrive.
///
/// Why: the pipeline cancels a negotiation when it stops, but cancellation is cooperative. The session call may still
/// be running (deactivate, set the preferred rate, reactivate) when a newer pipeline asks for its own rate. Waiting for
/// it keeps the stale call's side effects from landing after the newer one's.
///
/// Why a FIFO gate rather than an actor: an actor method that awaits `requestSampleRate` lets the next call in while it
/// is suspended (actor reentrancy), so two negotiations could still interleave. Here a call keeps its turn across its
/// awaits, and turns pass strictly in arrival order. A cancelled call keeps its place, but it skips the session when
/// its turn comes.
final class SessionGate: Sendable {
    private struct State {
        var busy = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let session: AudioSessionControlling
    private let state = Mutex(State())

    init(session: AudioSessionControlling) {
        self.session = session
    }

    /// Asks the session for `hz` for the pipeline holding `lease`, once every earlier call has finished, and returns
    /// the rate the hardware runs at.
    ///
    /// Returns 0 ("no usable rate") without touching the session if, when its turn comes, the lease has been revoked
    /// or the task cancelled. Either way that pipeline has been stopped and will never play. Its request must not
    /// reconfigure the session under the pipeline that replaced it, whose output may be running by then.
    func requestSampleRate(_ hz: Int, for lease: OutputLease) async -> Int {
        await withTurn {
            guard lease.holdsOutput, !Task.isCancelled else { return 0 }
            return await session.requestSampleRate(hz)
        }
    }

    /// Configures and activates the session, in turn with the negotiations.
    func activate() async throws {
        try await withTurn { try await session.activate() }
    }

    /// Calls waiting for their turn, not counting the one running. For tests.
    var waiting: Int {
        state.withLock { $0.waiting.count }
    }

    private func withTurn<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
            let free = state.withLock { s in
                guard s.busy else {
                    s.busy = true
                    return true
                }
                s.waiting.append(turn)
                return false
            }
            if free { turn.resume() }
        }
    }

    /// Hands the turn to the longest waiter, or frees the gate.
    private func release() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard !s.waiting.isEmpty else {
                s.busy = false
                return nil
            }
            return s.waiting.removeFirst()
        }
        next?.resume()
    }
}
