import Foundation

/// What the library remembers of a track's listens: how often it counted, and when it last did.
public struct ListenStat: Sendable, Hashable {
    public var count: Int
    public var lastAt: Date?

    public init(count: Int, lastAt: Date?) {
        self.count = count
        self.lastAt = lastAt
    }
}

/// When a play counts as a listen: once the track has really been played for half its length, at most four minutes.
///
/// Fed the player's position on every poll, it adds up only time that passed while the track was playing and not being
/// scrubbed, in steps no larger than a poll could explain. So a seek forward, a pause, a scrub or a buffering stall
/// earns nothing, and a track cannot be counted by skipping through it. A backward step (a seek back, a repeat loop)
/// keeps what was played and carries on from the new position. One rule covers one play of one track: the caller makes
/// a new one when the track changes or restarts.
public struct ListenRule: Sendable {
    /// The longest forward step in position that counts as playing rather than a seek. Polls are 0.5 s apart; the
    /// rest is slack for a late poll.
    static let maxStep = 1.5
    /// A track shorter than this never counts: a short clip, a sample or a gap-filler is not a listen.
    static let minimumDuration = 30.0
    /// The cap on the threshold, so a long track counts after four minutes instead of half an hour.
    static let thresholdCap = 240.0

    /// Really-played seconds needed, or nil for a track under 30 s, which never counts.
    public let threshold: Double?
    private var lastPosition: Double?
    private var played = 0.0
    private var counted = false

    public init(durationSeconds: Double) {
        threshold = durationSeconds >= Self.minimumDuration ? min(0.5 * durationSeconds, Self.thresholdCap) : nil
    }

    /// Takes one observation of the player. Returns true exactly once: on the observation where the really-played
    /// time first reaches the threshold.
    public mutating func observe(positionSeconds: Double, playing: Bool, scrubbing: Bool) -> Bool {
        defer { lastPosition = positionSeconds }
        guard let threshold, !counted, let last = lastPosition else { return false }
        let step = positionSeconds - last
        if playing, !scrubbing, step > 0, step <= Self.maxStep { played += step }
        guard played >= threshold else { return false }
        counted = true
        return true
    }
}
