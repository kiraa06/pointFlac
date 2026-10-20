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
        /// What the last negotiation or activation that reached the session left the hardware at.
        var negotiated: Int?
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
            let rate = await session.requestSampleRate(hz)
            state.withLock { $0.negotiated = rate }
            return rate
        }
    }

    /// Configures and activates the session, in turn with the negotiations, and records the rate it comes up at.
    ///
    /// Recording it matters (ledger T13): an activation can move the hardware rate (a preferred rate, or a route that
    /// changed while the session was down) and posts same-port route changes. Were the settled rate still the previous
    /// negotiation's, such a notification, handled before the start's own negotiation takes the turn, would look like
    /// the hardware moving and restart the start for nothing. An inactive session's 0 is not recorded.
    func activate(preferredRate: Int?) async throws {
        try await withTurn {
            try await session.activate(preferredRate: preferredRate)
            let rate = session.sampleRate
            if rate > 0 { state.withLock { $0.negotiated = rate } }
        }
    }

    /// The rate the last negotiation read back, or the last activation came up at, once nothing is using the session.
    /// Nil while a call holds the turn, whose answer is not in yet, and before the first negotiation or activation.
    ///
    /// The player compares it with the session's live rate on a route change. A route notification that a negotiation
    /// or an activation itself causes is handled either while that call holds the turn (nil: ignored) or after it,
    /// when the rate it recorded equals the live rate. Either way it cannot set off another negotiation, so reacting
    /// cannot loop.
    var settledRate: Int? {
        state.withLock { $0.busy ? nil : $0.negotiated }
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
