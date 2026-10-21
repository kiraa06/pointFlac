import Foundation
import Testing

@testable import PFDesign

// MARK: SideLayout

@Test func oneTrackAlbumGetsOneSide() {
    let layout = SideLayout(durations: [300])
    #expect(layout.sides.count == 1)
    #expect(layout.code(ofTrack: 0) == "A1")
}

@Test func twoTracksAlwaysGetTwoSides() {
    let layout = SideLayout(durations: [120, 130])
    #expect(layout.sides.map(\.letter) == ["A", "B"])
    #expect(layout.sides.map(\.tracks) == [0..<1, 1..<2])
}

@Test func sidesAreBalancedAndNeverSplitATrack() {
    // 19 min 05 s: two sides, as even as whole tracks allow.
    let layout = SideLayout(durations: [190, 245, 170, 320, 220])
    #expect(layout.sides.count == 2)
    #expect(layout.sides[0].tracks == 0..<3)
    #expect(layout.sides[1].tracks == 3..<5)
    #expect(layout.code(ofTrack: 3) == "B1")
    #expect(layout.offset(ofTrack: 2) == 435)
    #expect(layout.side(ofTrack: 4) == 1)
}

@Test func longAlbumsGetMoreSidesUnderTheLimit() {
    // 80 minutes of 5-minute tracks: a double album, sides A–D, each under 22 minutes.
    let layout = SideLayout(durations: Array(repeating: 300, count: 16))
    #expect(layout.sides.map(\.letter) == ["A", "B", "C", "D"])
    #expect(layout.sides.allSatisfy { $0.duration <= SideLayout.maxSideSeconds })
    #expect(layout.sides.flatMap { Array($0.tracks) } == Array(0..<16))
}

@Test func aTrackLongerThanASideGetsItsOwnSide() {
    let layout = SideLayout(durations: [1500, 200, 200])
    #expect(layout.sides.count >= 2)
    #expect(layout.sides[0].tracks == 0..<1)
}

@Test func emptyAlbumHasNoSides() {
    #expect(SideLayout(durations: []).sides.isEmpty)
    #expect(SideLayout(durations: []).code(ofTrack: 0) == "")
}

// MARK: SideTimeline

@Test func timelineLocatesAndSnapsToTrackGaps() {
    let side = SideTimeline(durations: [100, 50, 200])
    #expect(side.total == 350)
    #expect(side.locate(120) == (1, 20))
    #expect(side.locate(-5) == (0, 0))
    #expect(side.locate(999) == (2, 200))
    let snapped = side.snapped(148.5, tolerance: 2)
    #expect(snapped.seconds == 150 && snapped.track == 2)
    let free = side.snapped(140, tolerance: 2)
    #expect(free.seconds == 140 && free.track == nil)
}

// MARK: SpinModel

@Test func spinRampsUpThenTurnsEveryOnePointEightSeconds() {
    var spin = SpinModel(spinUpSeconds: 1, windDownSeconds: 1)
    #expect(spin.isAtRest(at: 0))
    spin.setSpinning(true, at: 0)
    #expect(spin.velocity(at: 0.5) == SpinModel.fullSpeed / 2)
    // After the ramp, a full turn takes exactly 1.8 s.
    let a = spin.angle(at: 2)
    let b = spin.angle(at: 3.8)
    #expect(abs((b - a) - 360) < 1e-9)
    // Half the ramp's distance is lost to the spin-up: 0.5 s at full speed.
    #expect(abs(spin.angle(at: 1) - SpinModel.fullSpeed * 0.5) < 1e-9)
}

@Test func windDownStopsAndIsContinuous() {
    var spin = SpinModel(spinUpSeconds: 1, windDownSeconds: 2)
    spin.place(at: 90, time: 0, spinning: true)
    let before = spin.angle(at: 1)
    spin.setSpinning(false, at: 1)
    #expect(abs(spin.angle(at: 1) - before) < 1e-9)
    #expect(!spin.isAtRest(at: 2))
    #expect(spin.isAtRest(at: 3.01))
    let stopped = spin.angle(at: 3.5)
    #expect(spin.angle(at: 10) == stopped)
}

// MARK: Tonearm and jog

@Test func tonearmMapsAnglesToTheSide() {
    let arm = TonearmGeometry(restAngle: 0, leadInAngle: 20, runoutAngle: 40)
    #expect(arm.angle(forFraction: 0) == 20)
    #expect(arm.angle(forFraction: 0.5) == 30)
    #expect(arm.fraction(forAngle: 35) == 0.75)
    #expect(arm.fraction(forAngle: 5) == 0)
    #expect(arm.fraction(forAngle: 90) == 1)
}

@Test func jogUnwrapsAndTurnsIntoSeconds() {
    #expect(JogMath.delta(from: 170, to: -170) == 20)
    #expect(JogMath.delta(from: -170, to: 170) == -20)
    #expect(JogMath.seconds(forDegrees: 360) == 1.8)
    #expect(abs(JogMath.seconds(forDegrees: -650) - -3.25) < 1e-12)
}

// MARK: Hand-off

@Test func handoffKeepsKiransSlowMoTimings() {
    let timeline = HandoffTimeline()
    #expect(abs(timeline.end(.lift) - 0.54) < 1e-9)
    #expect(abs(timeline.end(.slide) - 1.44) < 1e-9)
    #expect(abs(timeline.start(.arc) - 1.35) < 1e-9)
    #expect(abs(timeline.landTime - 2.91) < 1e-9)
    #expect(abs(timeline.spinTime - 3.45) < 1e-9)
    #expect(abs(timeline.duration - 4.71) < 1e-9)
    #expect(timeline.progress(.arc, at: 0) == 0)
    #expect(timeline.progress(.arc, at: timeline.landTime) == 1)
    #expect(timeline.progress(.arm, at: 100) == 1)
}

@Test func springOvershootsALittleAndSettles() {
    let peak = stride(from: 0.0, through: 1, by: 0.01).map(Easing.spring).max() ?? 0
    #expect(peak > 1 && peak < 1.08)
    #expect(Easing.spring(1) == 1)
    #expect(Easing.easeOut(0.5) > 0.5)
}

// MARK: Formatting

@Test func clocksReadAsThePlayerShowsThem() {
    #expect(ClockFormat.clock(101.9) == "1:41")
    #expect(ClockFormat.remaining(137.2) == "−2:18")
    #expect(ClockFormat.precise(134.38) == "2:14.380")
    #expect(ClockFormat.offset(-3.25) == "−3.250 s")
    #expect(ClockFormat.clock(.nan) == "0:00")
}

@Test func highlightIgnoresCaseAndAccents() {
    let text = "Beyoncé · Lemonade"
    let ranges = MatchHighlighter.ranges(of: "beyonce lem", in: text)
    #expect(ranges.map { String(text[$0]) } == ["Beyoncé", "Lem"])
    #expect(MatchHighlighter.ranges(of: "zzz", in: text).isEmpty)
}

/// The arc onto the platter uses its whole step: the old spring covered 91 % of the way in the first 30 % of the step,
/// so the record darted onto the deck instead of flying there.
@Test func arcGlidesAcrossItsWholeStepAndSettles() {
    let timeline = HandoffTimeline()
    let at = { (fraction: Double) in
        timeline.progress(.arc, at: timeline.start(.arc) + (timeline.landTime - timeline.start(.arc)) * fraction)
    }
    #expect((0.05...0.2).contains(at(0.1)))  // moving at once (no stall after the slide), but not darting
    #expect(at(0.3) < 0.7)  // the spring was at 0.91 here
    #expect((0.75...0.92).contains(at(0.5)))
    let peak = stride(from: 0.0, through: 1, by: 0.01).map(at).max() ?? 0
    #expect(peak > 1.005 && peak < 1.03)  // a slight settle on the spindle
    #expect(at(1) == 1)
}

/// Letting go of a held record on a running deck: the platter turns on under the slipmat, so the record catches it in
/// a fraction of a second, not the motor's start-up from rest.
@Test func releasedRecordCatchesThePlatterQuickly() {
    var spin = SpinModel()
    spin.place(at: 10, time: 0, spinning: false)
    spin.setSpinning(true, at: 0, rampSeconds: SpinModel.releaseSeconds)
    #expect(SpinModel.releaseSeconds <= 0.2)
    #expect(spin.velocity(at: SpinModel.releaseSeconds) == SpinModel.fullSpeed)
    #expect(spin.velocity(at: SpinModel.releaseSeconds / 2) < SpinModel.fullSpeed)
    // Pressing play on a stopped record still uses the motor's own start-up.
    var start = SpinModel()
    start.setSpinning(true, at: 0)
    #expect(start.velocity(at: SpinModel.releaseSeconds) < SpinModel.fullSpeed / 2)
}
