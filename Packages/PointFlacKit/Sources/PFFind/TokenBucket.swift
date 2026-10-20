/// A cancellable rate limiter for MusicBrainz, which allows an average of one request per second per client and
/// answers 503 to anything faster.
///
/// It is the generic cell rate algorithm, which behaves like a token bucket of `burst` tokens refilled every
/// `interval` but needs only one stored instant. Each ``acquire()`` reserves the next slot and sleeps until it, so
/// waiters are served in call order. A waiter that is cancelled (a newer keystroke) gives its slot back when nobody
/// reserved after it.
public actor TokenBucket {
    public nonisolated let interval: Duration
    public nonisolated let burst: Int
    private let clock = ContinuousClock()
    /// The theoretical arrival time of the next request when the bucket is drained steadily.
    private var nextArrival: ContinuousClock.Instant

    public init(interval: Duration = .seconds(1), burst: Int = 1) {
        precondition(burst >= 1, "a bucket holds at least one token")
        self.interval = interval
        self.burst = burst
        self.nextArrival = ContinuousClock.now
    }

    /// Waits until a request may be sent.
    ///
    /// - Throws: `CancellationError` if the task is cancelled before its slot; the slot is then returned.
    public func acquire() async throws {
        try Task.checkCancellation()
        let now = clock.now
        let arrival = max(nextArrival, now)
        let slot = max(now, arrival - interval * (burst - 1))
        nextArrival = arrival + interval
        guard slot > now else { return }
        let reserved = nextArrival
        do {
            try await clock.sleep(until: slot, tolerance: .milliseconds(5))
        } catch {
            // Only the most recent reservation can be undone without letting a later waiter overlap an earlier one.
            if nextArrival == reserved {
                nextArrival = reserved - interval
            }
            throw error
        }
    }

    /// Holds every request back for at least `delay`, after the server said it is busy (503 or 429, `Retry-After`).
    public func penalize(for delay: Duration) {
        // With a burst allowance the next slot is `arrival - interval * (burst - 1)`; offset so it lands at `until`.
        let until = clock.now + delay + interval * (burst - 1)
        nextArrival = max(nextArrival, until)
    }
}
