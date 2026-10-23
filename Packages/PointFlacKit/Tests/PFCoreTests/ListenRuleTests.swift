import Testing

@testable import PFCore

/// The listen rule: a play counts once, when really-played time reaches half the track (at most four minutes).
/// Seeking, pausing and scrubbing earn no credit.

/// Plays `rule` from `from` to `to` in `step`-second observations, and returns how many observations returned true.
private func play(_ rule: inout ListenRule, from: Double, to: Double, step: Double = 0.5) -> Int {
    var hits = 0
    var position = from
    while position <= to {
        if rule.observe(positionSeconds: position, playing: true, scrubbing: false) { hits += 1 }
        position += step
    }
    return hits
}

@Test func countsOnceAtHalfTheLength() {
    var rule = ListenRule(durationSeconds: 200)
    #expect(rule.threshold == 100)
    var firstHit: Double?
    var hits = 0
    var position = 0.0
    while position <= 100.5 {
        if rule.observe(positionSeconds: position, playing: true, scrubbing: false) {
            hits += 1
            firstHit = firstHit ?? position
        }
        position += 0.5
    }
    #expect(hits == 1)
    #expect(firstHit == 100)
    // Playing on never counts it again.
    let run1 = play(&rule, from: 101, to: 199)
    #expect(run1 == 0)
}

@Test func fourMinuteCap() {
    let rule = ListenRule(durationSeconds: 600)
    #expect(rule.threshold == 240)
    var long = ListenRule(durationSeconds: 600)
    let run2 = play(&long, from: 0, to: 240)
    #expect(run2 == 1)
}

@Test func shortTracksNeverCount() {
    var rule = ListenRule(durationSeconds: 29)
    #expect(rule.threshold == nil)
    let run3 = play(&rule, from: 0, to: 29)
    #expect(run3 == 0)
    #expect(ListenRule(durationSeconds: 30).threshold == 15)
}

@Test func seeksDoNotCount() {
    var rule = ListenRule(durationSeconds: 200)
    let obs1 = rule.observe(positionSeconds: 0, playing: true, scrubbing: false)
    #expect(!obs1)
    let obs2 = rule.observe(positionSeconds: 150, playing: true, scrubbing: false)
    #expect(!obs2)
    // The seek earned nothing: 49 real seconds from 150 on (to the end) are short of the 100 needed.
    let run4 = play(&rule, from: 150.5, to: 199)
    #expect(run4 == 0)
    // After a backward jump the 49 s are kept, and 51 more of real playing complete the 100.
    let obs3 = rule.observe(positionSeconds: 10, playing: true, scrubbing: false)
    #expect(!obs3)
    let run5 = play(&rule, from: 10.5, to: 120)
    #expect(run5 == 1)
}

@Test func pausedTimeDoesNotCount() {
    var rule = ListenRule(durationSeconds: 200)
    var hits = 0
    for step in 0...400 {
        // Position advances, but the player reports not playing: buffering, or a stale paused position.
        if rule.observe(positionSeconds: Double(step) * 0.5, playing: false, scrubbing: false) { hits += 1 }
    }
    #expect(hits == 0)
}

@Test func scrubbingDoesNotCount() {
    var rule = ListenRule(durationSeconds: 200)
    var hits = 0
    for step in 0...400 {
        if rule.observe(positionSeconds: Double(step) * 0.5, playing: true, scrubbing: true) { hits += 1 }
    }
    #expect(hits == 0)
}

@Test func backwardsResets() {
    var rule = ListenRule(durationSeconds: 200)
    let run6 = play(&rule, from: 0, to: 50)
    #expect(run6 == 0)
    // Jump back to 10: the 50 s already played is kept, and it continues from there.
    let obs4 = rule.observe(positionSeconds: 10, playing: true, scrubbing: false)
    #expect(!obs4)
    // 50 more seconds of real playing, from 10 to 60, brings the total to 100.
    let run7 = play(&rule, from: 10.5, to: 59.5)
    #expect(run7 == 0)
    let obs5 = rule.observe(positionSeconds: 60, playing: true, scrubbing: false)
    #expect(obs5)
}

// MARK: ListenSession

/// One observation of a player playing track "t" at index 0, 200 s long.
private func observe(
    _ session: inout ListenSession, at position: Double, index: Int? = 0, id: String? = "t", duration: Double = 200,
    playing: Bool = true, scrubbing: Bool = false
) -> String? {
    session.observe(
        index: index, trackID: id, durationSeconds: duration, positionSeconds: position, playing: playing,
        scrubbing: scrubbing)
}

@Test func sessionReportsTheTrackOnceItCounts() {
    var session = ListenSession()
    var reported: [String] = []
    var position = 0.0
    while position <= 150 {
        if let id = observe(&session, at: position) { reported.append(id) }
        position += 0.5
    }
    #expect(reported == ["t"])
}

@Test func sessionStartsFreshWhenTheTrackChanges() {
    var session = ListenSession()
    var reported: [String] = []
    // 60 s of track "a", then 60 s of "b": neither reaches its 100 s alone, though together they would.
    for step in 0...120 {
        if let id = observe(&session, at: Double(step) * 0.5, index: 0, id: "a") { reported.append(id) }
    }
    for step in 0...120 {
        if let id = observe(&session, at: Double(step) * 0.5, index: 1, id: "b") { reported.append(id) }
    }
    #expect(reported.isEmpty)
}

@Test func sessionCountsEachLoopOfRepeatOne() {
    var session = ListenSession()
    var reported: [String] = []
    // Three loops of a 200 s track, each played through to 101 s, then the position falls back to the start.
    for _ in 0..<3 {
        var position = 0.0
        while position <= 101 {
            if let id = observe(&session, at: position) { reported.append(id) }
            position += 0.5
        }
    }
    #expect(reported == ["t", "t", "t"])
}

@Test func sessionTreatsAScrubBackToTheStartAsTheSamePlay() {
    var session = ListenSession()
    var reported: [String] = []
    for step in 0...160 {
        if let id = observe(&session, at: Double(step) * 0.5) { reported.append(id) }
    }
    // 80 s played; the finger drags back to the start. That is not a new play: the 80 s are kept, and 20 more count.
    _ = observe(&session, at: 1, scrubbing: true)
    for step in 3...42 {
        if let id = observe(&session, at: Double(step) * 0.5) { reported.append(id) }
    }
    #expect(reported == ["t"])
}

@Test func sessionIgnoresNothingPlaying() {
    var session = ListenSession()
    #expect(observe(&session, at: 0, index: nil, id: nil) == nil)
}
