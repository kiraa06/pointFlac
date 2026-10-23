import PFAudio
import PFDesign
import SwiftUI

/// The turntable (spec §4.3), in the design chosen in Customize deck (`DeckDesign`), true to a real deck's
/// proportions: a plinth, a platter with its mat and strobe, the record (black vinyl by default), the tonearm and a
/// dot-matrix screen. Played by hand: drag the tonearm (or a linear deck's carriage) to seek across the side
/// (snapping into track gaps, with a loupe), turn the record to jog (1.8 s a turn, applied on release), tap the
/// tonearm at rest to drop the needle, and tap the record while the needle is up to turn it over.
///
/// This view owns the state and the gestures; the pieces it composes live in `App/Deck`. Everything that does not
/// move is drawn once per design and size; per frame, only the record's print turns, the arm moves and the 45 rpm
/// strobe rows creep.
struct DeckStage: View {
    let playback: PlaybackController
    let theme: Theme
    let handoff: HandoffDirector
    let discSpace: Namespace.ID
    /// The display unfolded into the tracklist (plan 9 §3). The player owns it, so a tap anywhere off the stage folds
    /// it back too.
    @Binding var tracklistOpen: Bool

    @AppStorage(DeckPreferences.designKey) private var designID = DeckDesign.standard.id
    @AppStorage(DeckPreferences.recordStyleKey) private var recordStyleRaw = RecordStyle.standard.rawValue

    @State private var spin = SpinModel()
    /// The platter under the record: it keeps turning beneath a held record (the slipmat slips), and drives the
    /// strobe.
    @State private var platter = SpinModel()
    @State private var lift = LiftModel()
    /// The arm held by a hand, as a position along its travel (`ArmTravel`).
    @State private var armDrag: Double?
    @State private var snapTrack: Int?
    @State private var jog: Jog?
    @State private var holdTimer: Task<Void, Never>?
    /// True while a finger is on the record. Gesture state resets even when the system cancels the gesture (a call
    /// banner, the app leaving the foreground), which `onEnded` does not report: the hold is let go then too.
    @GestureState private var touching = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flip = 0.0
    @State private var restTick = 0
    /// The tonearm on its way to a song the tracklist chose, until it lands.
    @State private var swing: ArmSwing?
    /// A jump to the other side turned the record over already: the side change it causes must not turn it again.
    @State private var flipClaim: FlipClaim?
    /// The plinth's size, for working out where the arm is when a jump arrives (outside the geometry reader).
    @State private var deckSize: CGSize = .zero

    /// The tonearm swinging to a song the tracklist chose (plan 9 §3), instead of snapping to it. On the same side it
    /// swings straight there, over 0.6 s. On the other side the record turns over first while the arm parks at rest,
    /// and then the arm drops. Under Reduce Motion the arm fades out where it was and in where it goes. Once it has
    /// landed, the side's live position drives the arm again. A hand on the arm or the record, or the player landing on
    /// another song (Next, Previous, a drop), ends it at once: the arm never pulls back to a song the music has left.
    /// A linear deck's carriage slides the same way, along its rail.
    struct ArmSwing {
        let serial: Int
        /// The arm's position when the jump came.
        let from: Double
        let track: Int
        let side: Int
        /// The song chosen is the one playing: the player only seeks back to its start, so the live position is the
        /// old one until the seek lands, and the swing aims at the start throughout.
        let restart: Bool
        /// When the arm starts to move. A jump from the unfolded display holds it until the display has nearly
        /// folded away, so the swing is seen rather than played out under the panel.
        let began: Date
        /// Seconds parked at rest while the record turns over first; zero on the same side.
        let park: Double
        let fades: Bool

        static let swingSeconds = 0.6
        static let fadeSeconds = 0.3

        var duration: Double { park + (fades ? Self.fadeSeconds : Self.swingSeconds) }
    }

    /// How long a jump from the unfolded display holds the arm: the pick's beat before the fold (0.25 s), and most
    /// of the fold.
    static let holdUnderPanel = 0.5

    /// The record turned over for a jump to `side`; claimed until `until`, in case the player never gets there.
    struct FlipClaim {
        let side: Int
        let until: Date
    }

    /// The end-of-side flip's length, which a jump to the other side reuses.
    static let flipSeconds = 0.9

    /// A finger on the record. Until it engages (it moves, or holds still for `holdToEngage`) it may still be a tap,
    /// and the record carries on as it was. Once engaged, the hand holds the record: the picture follows the finger
    /// and the music follows the hand.
    struct Jog {
        var baseAngle: Double
        var lastFinger: Double
        var degrees: Double
        var lastTime: Date
        /// The hand's turning speed, smoothed over a few touches, in degrees per second.
        var velocity: Double
        var engaged: Bool
        /// The player holds the record (`beginScrub` took it); otherwise the turn is a plain jog, applied on release.
        var scrubbing = false
        let began: Date
        /// How far the finger has moved, in points.
        var travel: CGFloat
        var lastLocation: CGPoint
    }

    /// A finger that holds a playing record still this long takes hold of it (it brakes to a stop under it). A paused
    /// record is only taken hold of by turning it, so a slow tap still turns it over.
    static let holdToEngage: Duration = .milliseconds(150)
    /// A finger that moves this far holds the record at once.
    static let travelToEngage: CGFloat = 3

    private var design: DeckDesign { DeckDesign.design(id: designID) }
    private var recordStyle: RecordStyle { RecordStyle(rawValue: recordStyleRaw) ?? .standard }

    var body: some View {
        GeometryReader { proxy in
            let layout = DeckLayout(size: proxy.size, design: design)
            let paint = DeckPaint(design: design, theme: theme)
            ZStack(alignment: .topLeading) {
                // A new design cross-fades in over the old one.
                deck(layout, paint)
                    // VoiceOver names the turntable as it enters the deck.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(design.name) turntable")
                    .accessibilityIdentifier("deckStage")
                    .id(design.id)
                    // The outgoing design fades out over the incoming one, which is drawn whole beneath it: a
                    // cross-fade with no dip to the background. A newer deck always sorts under the one it replaces
                    // (a removed view keeps the order it last had).
                    .zIndex(-Date.timeIntervalSinceReferenceDate)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                loupe(layout)
                tracklistPanel(layout, paint)
            }
            .animation(.easeInOut(duration: 0.45), value: design.id)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(PlayerSpace.name))
            } action: { frame in
                deckSize = frame.size
                // The record's size does not depend on the design.
                let l = DeckLayout(size: frame.size)
                handoff.platterRect = CGRect(
                    x: frame.minX + l.recordCenter.x - l.recordRadius,
                    y: frame.minY + l.recordCenter.y - l.recordRadius,
                    width: l.recordRadius * 2, height: l.recordRadius * 2)
            }
        }
        .onAppear {
            lift.set(down: needleDown, at: Date.timeIntervalSinceReferenceDate, animated: false)
        }
        .onChange(of: needleDown) { _, down in
            lift.set(down: down, at: Date.timeIntervalSinceReferenceDate, animated: !reduceMotion)
        }
        .onChange(of: playback.isPlaying, initial: true) { _, playing in
            let now = Date.timeIntervalSinceReferenceDate
            spin.setSpinning(playing || handoff.spinning, at: now)
            platter.setSpinning(playing || handoff.spinning, at: now)
        }
        .onChange(of: handoff.spinning) { _, spinning in
            let now = Date.timeIntervalSinceReferenceDate
            spin.setSpinning(spinning || playback.isPlaying, at: now)
            platter.setSpinning(spinning || playback.isPlaying, at: now)
        }
        .onChange(of: touching) { _, touching in
            // A cancelled gesture resets `touching` without `onEnded`; a normal end runs `onEnded` first, which clears
            // `jog`, so this only lets go of a hold nothing else will.
            guard !touching else { return }
            Task { @MainActor in if jog != nil { letGo(asTap: false) } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, jog != nil { letGo(asTap: false) }
        }
        .onDisappear {
            if jog != nil { letGo(asTap: false) }
            tracklistOpen = false
        }
        .onChange(of: handoff.landed) { _, landed in
            if landed {
                spin.place(at: HandoffDirector.landingAngle, time: Date.timeIntervalSinceReferenceDate, spinning: false)
            }
        }
        .onChange(of: playback.currentSide) { old, new in
            guard old != new else { return }
            // A jump to the other side turned the record over when it was asked for, before the player got there.
            if let claim = flipClaim, claim.side == new, Date() < claim.until {
                flipClaim = nil
                return
            }
            // End of side: the deck turns the record over while the audio carries on (spec §4.3). A whole turn, so
            // the picture disc never ends up mirrored.
            guard playback.isPlaying else { return }
            withAnimation(.spring(duration: Self.flipSeconds, bounce: 0.1)) { flip += 360 }
        }
        .onChange(of: playback.lastJump) { _, jump in
            if let jump { startSwing(jump) }
        }
        .onChange(of: playback.trackIndex) { _, track in
            // The player landed on another song than the one chosen (Next or Previous, a drop, the side playing on):
            // the arm follows the music from here, not the jump.
            if let swing, let track, track != swing.track { endSwing() }
        }
        .task(id: swing?.serial) {
            // The swing hands the arm back once it has landed and the player has reached the song (a slow start
            // would otherwise pull the arm back to the old groove for a moment), or after a second more regardless.
            guard let current = swing else { return }
            try? await Task.sleep(for: .seconds(max(0, current.began.timeIntervalSinceNow) + current.duration))
            let deadline = Date().addingTimeInterval(1)
            while !Task.isCancelled, !reached(current), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !Task.isCancelled, swing?.serial == current.serial { swing = nil }
        }
        .task(id: playback.isPlaying) {
            // Let the timeline run through the wind-down (and the arm's lift), then pause it.
            try? await Task.sleep(for: .seconds(max(spin.windDownSeconds, LiftModel.lowerSeconds) + 0.1))
            restTick += 1
        }
    }

    // MARK: The deck

    private func deck(_ layout: DeckLayout, _ paint: DeckPaint) -> some View {
        DeckLayers(paint: paint, layout: layout, live: true, playing: playback.isPlaying) {
            TimelineView(.animation(minimumInterval: nil, paused: timelinePaused)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                let position = armPosition(layout, at: context.date)
                ZStack(alignment: .topLeading) {
                    DeckMovingParts(
                        paint: paint, layout: layout, strobePhase: strobePhase(now), armPosition: position,
                        lift: lift.value(at: now), armOpacity: armOpacity(at: context.date)
                    ) {
                        record(layout, angle: recordAngle(now))
                            // A record Up Next pulls in arrives with a short settle (the hand-off's short form).
                            // Not during the hand-off, whose own record lands exactly where this one appears.
                            .transition(
                                handoff.isRunning ? .identity : .scale(scale: 0.7).combined(with: .opacity)
                            )
                            .animation(.spring(duration: 0.6, bounce: 0.2), value: playback.album?.id)
                    }
                    armHitArea(layout, position: position)
                }
            }
            .accessibilityHidden(tracklistOpen)
        } front: {
            if design.controls == .dj {
                DeckStartStop(
                    paint: paint, layout: layout, playing: playback.isPlaying, enabled: playback.album != nil
                ) {
                    playback.togglePlayPause()
                }
                .accessibilityHidden(tracklistOpen)
            }
            DeckScreen(
                playback: playback, paint: paint, size: layout.size,
                open: canUnfold ? { unfoldTracklist() } : nil
            )
            .accessibilityHidden(tracklistOpen)
        }
    }

    // MARK: State

    private var timelinePaused: Bool {
        _ = restTick
        let now = Date.timeIntervalSinceReferenceDate
        return !playback.isPlaying && !handoff.isRunning && jog == nil && armDrag == nil && swing == nil
            && spin.isAtRest(at: now) && platter.isAtRest(at: now) && lift.isSettled(at: now)
    }

    /// The stylus is in the groove: the record plays and no hand or swing holds the arm up.
    private var needleDown: Bool {
        playback.isPlaying && armDrag == nil && swing == nil && !handoff.isRunning
    }

    private var showsRecord: Bool {
        playback.album != nil && (!handoff.isRunning || handoff.landed)
    }

    private func recordAngle(_ now: Double) -> Double {
        if let jog, jog.engaged { return jog.baseAngle + jog.degrees }
        return spin.angle(at: now)
    }

    /// The 45 rpm strobe rows' creep: still at rest, a slow drift while the platter turns at 33⅓. Still under Reduce
    /// Motion.
    private func strobePhase(_ now: Double) -> Double {
        reduceMotion ? 0 : StrobeRows.creep(platterDegrees: platter.angle(at: now))
    }

    private func armPosition(_ layout: DeckLayout, at date: Date) -> Double {
        let travel = layout.travel
        if let armDrag { return armDrag }
        if handoff.isRunning {
            let t = handoff.elapsed(at: date)
            let p = handoff.timeline.progress(.arm, at: t)
            return travel.rest + (travel.leadIn - travel.rest) * p
        }
        if let swing { return swingPosition(swing, layout, at: date) }
        return livePosition(layout)
    }

    /// Where the side's position puts the needle; at rest when nothing plays.
    private func livePosition(_ layout: DeckLayout) -> Double {
        guard playback.trackIndex != nil, playback.player.status != .ended else { return layout.travel.rest }
        let total = playback.sideTimeline(playback.currentSide).total
        let fraction = total > 0 ? playback.sidePosition / total : 0
        return layout.travel.position(forFraction: fraction)
    }

    // MARK: The swing

    /// The swinging arm at `date`: parked towards rest while the record turns over, then on its way to the song's
    /// groove, then holding there until the swing hands back.
    private func swingPosition(_ swing: ArmSwing, _ layout: DeckLayout, at date: Date) -> Double {
        let t = date.timeIntervalSince(swing.began)
        let rest = layout.travel.rest
        if t < 0 { return swing.from }
        if t < swing.park {
            return swing.from + (rest - swing.from) * Self.easeInOut(t / swing.park)
        }
        let start = swing.park > 0 ? rest : swing.from
        let target = swingTarget(swing, layout)
        let x = (t - swing.park) / (swing.fades ? ArmSwing.fadeSeconds : ArmSwing.swingSeconds)
        if swing.fades { return x < 0.5 ? start : target }
        return start + (target - start) * Self.springEase(x)
    }

    /// The song's groove: the live position once the player plays it (so the hand-back is seamless), its start until
    /// then. A restart aims at the start throughout: until its seek lands, the live position is the old one.
    private func swingTarget(_ swing: ArmSwing, _ layout: DeckLayout) -> Double {
        if !swing.restart, playback.trackIndex == swing.track, playback.player.status != .ended {
            return livePosition(layout)
        }
        let total = playback.sideTimeline(swing.side).total
        guard total > 0 else { return layout.travel.leadIn }
        return layout.travel.position(forFraction: playback.layout.offset(ofTrack: swing.track) / total)
    }

    /// The player is at the swing's song (back near its start, for a restart), so the live position can take over.
    private func reached(_ swing: ArmSwing) -> Bool {
        playback.trackIndex == swing.track && (!swing.restart || playback.player.position.seconds < 1.5)
    }

    /// A hand took over, or the music moved elsewhere: the arm goes back to following the needle at once. The
    /// record's flip, if one ran, stays claimed, since the jump that caused it is still on its way to the player.
    private func endSwing() {
        swing = nil
    }

    /// Under Reduce Motion the arm does not travel: it fades out where it was and back in at the song.
    private func armOpacity(at date: Date) -> Double {
        guard let swing, swing.fades else { return 1 }
        let x = date.timeIntervalSince(swing.began) / ArmSwing.fadeSeconds
        return x >= 1 ? 1 : abs(1 - 2 * min(max(x, 0), 1))
    }

    /// A jump from the tracklist, the sheet's or the display's. The arm starts from where it is drawn: mid-swing, or
    /// where the needle was when the song was chosen. A song on the other side turns the record over first (the
    /// end-of-side flip, claimed so the side change does not run it again) while the arm parks. From the display,
    /// all of it waits for the panel to fold out of the way.
    private func startSwing(_ jump: PlaybackController.TrackJump) {
        guard let side = playback.layout.side(ofTrack: jump.track), deckSize != .zero, !handoff.isRunning else {
            return
        }
        let layout = DeckLayout(size: deckSize, design: design)
        let now = Date()
        let from: Double
        if let swing {
            from = swingPosition(swing, layout, at: now)
        } else if let position = jump.fromPosition {
            let total = playback.sideTimeline(jump.fromSide).total
            from = total > 0 ? layout.travel.position(forFraction: position / total) : layout.travel.rest
        } else {
            from = layout.travel.rest
        }
        let turns = side != jump.fromSide
        let hold = tracklistOpen ? Self.holdUnderPanel : 0
        if turns {
            flipClaim = FlipClaim(side: side, until: now.addingTimeInterval(hold + 3))
            if !reduceMotion {
                withAnimation(.spring(duration: Self.flipSeconds, bounce: 0.1).delay(hold)) { flip += 360 }
            }
        }
        swing = ArmSwing(
            serial: jump.serial, from: from, track: jump.track, side: side, restart: playback.trackIndex == jump.track,
            began: now.addingTimeInterval(hold), park: turns && !reduceMotion ? Self.flipSeconds : 0,
            fades: reduceMotion)
    }

    /// The swing's easing: quick off the mark, a touch past the groove (a 1.8 % overshoot, like a light spring) and
    /// settled exactly at the end, so the hand-back to the live position never jumps. An ease-out-back.
    static func springEase(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        let c1 = 0.7
        let c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    static func easeInOut(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: The display's tracklist

    /// Something to list, and nothing else under way.
    private var canUnfold: Bool {
        playback.album != nil && !playback.tracks.isEmpty && !handoff.isRunning
    }

    private func unfoldTracklist() {
        guard canUnfold else { return }
        withAnimation(DeckTracklist.animation(reduceMotion: reduceMotion)) { tracklistOpen = true }
    }

    private func foldTracklist() {
        withAnimation(DeckTracklist.animation(reduceMotion: reduceMotion)) { tracklistOpen = false }
    }

    /// A song picked on the display plays at once; the display folds back a beat later, once the inverted bar has
    /// moved to it.
    private func pickFromDisplay(_ index: Int) {
        playback.jump(toTrack: index)
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            foldTracklist()
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func record(_ layout: DeckLayout, angle: Double) -> some View {
        if showsRecord, let album = playback.album {
            let d = layout.recordRadius * 2
            RecordView(
                face: RecordFace(album: album, side: sideLetter ?? "A", bands: bands(layout), style: recordStyle),
                diameter: d, angle: angle
            )
            .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .frame(width: d, height: d)
            .contentShape(Circle())
            .gesture(jogGesture(layout))
            .position(layout.recordCenter)
            .accessibilityElement()
            .accessibilityLabel("Record, \(album.title)")
            .accessibilityHint("Turn to scrub. Tap while the needle is up to turn it over.")
            .accessibilityIdentifier("deckRecord")
            .accessibilityAction { tapRecord() }
            .accessibilityAction(named: "Back 5 seconds") { jogBy(-5) }
            .accessibilityAction(named: "Forward 5 seconds") { jogBy(5) }
            .id(album.id)
        }
    }

    /// Where a finger takes the arm, over the drawn arm (`TonearmAssembly`): the arm's gestures live here.
    @ViewBuilder
    private func armHitArea(_ layout: DeckLayout, position: Double) -> some View {
        if let arm = layout.pivoted {
            pivotedHandle(arm, angle: position)
                .gesture(armGesture(layout))
                .simultaneousGesture(TapGesture().onEnded { tapTonearm() })
                .sensoryFeedback(.selection, trigger: snapTrack)
        } else {
            carriageHandle(layout, position: position)
                .gesture(armGesture(layout))
                .simultaneousGesture(TapGesture().onEnded { tapTonearm() })
                .sensoryFeedback(.selection, trigger: snapTrack)
        }
    }

    /// A pivoted arm's targets, turned with it: a band 14 pt wide round the drawn tube, so a touch just beside it
    /// reaches the record, and generous circles round the headshell (where a finger naturally takes the arm, and
    /// what VoiceOver calls the tonearm) and the pivot.
    private func pivotedHandle(_ arm: PivotedArm, angle: Double) -> some View {
        let m = ArmMetrics(arm: arm)
        let pad: CGFloat = 40
        let size = CGSize(width: m.width + pad * 2, height: m.height + pad * 2)
        let pivot = CGPoint(x: m.pivot.x + pad, y: m.pivot.y + pad)
        let grip = CGPoint(x: m.grip.x + pad, y: m.grip.y + pad)
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(TubeBand(metrics: m, style: design.armStyle, pad: pad))
            Circle().fill(Color.white.opacity(0.001)).frame(width: 48, height: 48)
                .position(pivot)
            Circle().fill(Color.white.opacity(0.001)).frame(width: 64, height: 64)
                .modifier(TonearmAccessibility(value: armValue, nudge: nudge))
                .position(grip)
        }
        .frame(width: size.width, height: size.height)
        .rotationEffect(.degrees(angle), anchor: UnitPoint(x: pivot.x / size.width, y: pivot.y / size.height))
        .position(x: arm.pivot.x - pivot.x + size.width / 2, y: arm.pivot.y - pivot.y + size.height / 2)
    }

    /// The linear carriage's target: a generous circle round the carriage and its cartridge.
    private func carriageHandle(_ layout: DeckLayout, position: Double) -> some View {
        let stylus = layout.needle(at: position)
        return Circle().fill(Color.white.opacity(0.001)).frame(width: 64, height: 64)
            .modifier(TonearmAccessibility(value: armValue, nudge: nudge))
            .position(x: stylus.x, y: stylus.y - layout.recordRadius * 0.08)
    }

    /// The display unfolded into the tracklist, over the platter, inset from the plinth's edge, in the display's ink.
    @ViewBuilder
    private func tracklistPanel(_ layout: DeckLayout, _ paint: DeckPaint) -> some View {
        if tracklistOpen {
            // A tap beside the panel, on the plinth's rim, folds it back as well.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { foldTracklist() }
                .accessibilityHidden(true)
                .zIndex(1)
            // An explicit z-index: without one, a ZStack draws a view leaving it under its siblings, and the fold
            // would play out hidden behind the plinth.
            DeckTracklist(
                playback: playback, theme: theme.withDisplay(ink: paint.displayInk, back: paint.displayBack),
                pick: { pickFromDisplay($0) }, fold: { foldTracklist() }
            )
            .padding(DeckTracklist.inset)
            .frame(width: layout.size.width, height: layout.size.height)
            .transition(
                DeckTracklist.unfold(
                    from: DeckScreen.frame(in: layout.size), in: layout.size, reduceMotion: reduceMotion)
            )
            .zIndex(2)
        }
    }

    @ViewBuilder
    private func loupe(_ layout: DeckLayout) -> some View {
        if let armDrag {
            let timeline = playback.sideTimeline(playback.currentSide)
            let raw = layout.travel.fraction(forPosition: armDrag) * timeline.total
            let (local, offset) = timeline.locate(raw)
            let index = sideFirstTrack + local
            let title = playback.tracks.indices.contains(index) ? playback.tracks[index].title : ""
            Loupe(
                heading: "\(playback.layout.code(ofTrack: index)) · \(title.uppercased())",
                value: ClockFormat.precise(offset), detail: nil, seed: index, phase: offset
            )
            .position(x: layout.size.width * 0.32, y: layout.size.height * 0.2)
            .allowsHitTesting(false)
        } else if let jog, jog.engaged {
            let offset = JogMath.seconds(forDegrees: jog.degrees)
            let target = max(0, playback.player.position.seconds + offset)
            Loupe(
                heading: "SCRUB", value: ClockFormat.offset(offset), detail: ClockFormat.precise(target), seed: 0,
                phase: target
            )
            .position(x: layout.size.width * 0.62, y: layout.size.height * 0.86)
            .allowsHitTesting(false)
        }
    }

    // MARK: Gestures

    private var sideFirstTrack: Int {
        let sides = playback.layout.sides
        return sides.indices.contains(playback.currentSide) ? sides[playback.currentSide].tracks.lowerBound : 0
    }

    /// The arm (or the carriage) under a finger: it follows the finger along its travel, clicking into track gaps,
    /// and drops the needle where it is let go.
    private func armGesture(_ layout: DeckLayout) -> some Gesture {
        let travel = layout.travel
        return DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard playback.album != nil, !handoff.isRunning else { return }
                // A hand on the arm takes it from a swing in flight, park included: it lands where the hand drops it.
                if swing != nil { endSwing() }
                let raw = travel.clamped(travel.position(toward: value.location))
                let timeline = playback.sideTimeline(playback.currentSide)
                let seconds = travel.fraction(forPosition: raw) * timeline.total
                // Gaps are bands about 1.5 % of the side wide: wide enough to feel, narrow enough to pass.
                let snapped = timeline.snapped(seconds, tolerance: timeline.total * 0.015)
                if raw >= travel.leadIn, let track = snapped.track, timeline.total > 0 {
                    armDrag = travel.position(forFraction: snapped.seconds / timeline.total)
                    snapTrack = track
                } else {
                    armDrag = raw
                    if snapped.track == nil { snapTrack = nil }
                }
            }
            .onEnded { _ in
                guard let position = armDrag else { return }
                armDrag = nil
                snapTrack = nil
                // Let go short of the record, the arm goes back to its rest without seeking.
                guard position >= travel.leadIn - 1 else { return }
                let timeline = playback.sideTimeline(playback.currentSide)
                let seconds = travel.fraction(forPosition: position) * timeline.total
                let side = playback.currentSide
                Task { await playback.seek(side: side, to: seconds) }
            }
    }

    /// The record under a finger (spec §4.3): turn it to scrub (the music follows the hand, one turn is 1.8 s), hold it
    /// still to stop it, let go and it spins back up. A quick touch that does not move is a tap, which turns the
    /// record over while the needle is up.
    private func jogGesture(_ layout: DeckLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in
                let r = layout.recordRadius
                let finger = atan2(value.location.y - r, value.location.x - r) * 180 / .pi
                guard var current = jog else {
                    jog = Jog(
                        baseAngle: 0, lastFinger: finger, degrees: 0, lastTime: value.time, velocity: 0,
                        engaged: false, began: value.time, travel: 0, lastLocation: value.location)
                    holdTimer?.cancel()
                    holdTimer = nil
                    if playback.isPlaying {
                        holdTimer = Task {
                            try? await Task.sleep(for: Self.holdToEngage)
                            guard !Task.isCancelled else { return }
                            engageJog()
                        }
                    }
                    return
                }
                current.travel += hypot(
                    value.location.x - current.lastLocation.x, value.location.y - current.lastLocation.y)
                current.lastLocation = value.location
                let delta = JogMath.delta(from: current.lastFinger, to: finger)
                current.lastFinger = finger
                let dt = value.time.timeIntervalSince(current.lastTime)
                if current.engaged {
                    current.degrees += delta
                    // The hand's speed from this touch: a touch after a pause starts afresh, and touches coalesced a
                    // millisecond apart only add their turn (their speed would be noise).
                    if dt > 0.05 {
                        current.velocity = delta / dt
                        current.lastTime = value.time
                    } else if dt >= 0.002 {
                        current.velocity = current.velocity * 0.5 + delta / dt * 0.5
                        current.lastTime = value.time
                    }
                    jog = current
                    if current.scrubbing {
                        playback.scrub(degrees: current.degrees, degreesPerSecond: current.velocity)
                    }
                } else {
                    current.lastTime = value.time
                    jog = current
                    if current.travel >= Self.travelToEngage { engageJog() }
                }
            }
            .onEnded { _ in letGo(asTap: true) }
    }

    /// The finger takes hold of the record: the picture stops under it, where it was, and the music follows the hand.
    private func engageJog() {
        guard var current = jog, !current.engaged else { return }
        endSwing()
        current.engaged = true
        current.baseAngle = spin.angle(at: Date.timeIntervalSinceReferenceDate)
        current.degrees = 0
        current.velocity = 0
        current.scrubbing = playback.beginScrub()
        jog = current
    }

    /// The finger left the record. A touch that never took hold is a tap (unless the system cancelled it); a hold
    /// lets the record go: it spins back up if it was playing, and the music hands back to the player.
    private func letGo(asTap: Bool) {
        holdTimer?.cancel()
        holdTimer = nil
        guard let ended = jog else { return }
        jog = nil
        guard ended.engaged else {
            if asTap { tapRecord() }
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        spin.place(at: ended.baseAngle + ended.degrees, time: now, spinning: false)
        // A let-go record catches the platter turning under the slipmat: quick, and the sound's ramp matches.
        spin.setSpinning(playback.isPlaying, at: now, rampSeconds: SpinModel.releaseSeconds)
        if ended.scrubbing {
            playback.endScrub(spinUpSeconds: SpinModel.releaseSeconds)
        } else {
            jogBy(JogMath.seconds(forDegrees: ended.degrees))
        }
    }

    private func jogBy(_ seconds: Double) {
        guard playback.trackIndex != nil else { return }
        endSwing()
        let side = playback.currentSide
        let target = playback.sidePosition + seconds
        Task { await playback.seek(side: side, to: target) }
    }

    private func nudge(_ seconds: Double) {
        jogBy(seconds)
    }

    private func tapTonearm() {
        guard !handoff.isRunning, playback.album != nil, !playback.isPlaying else { return }
        endSwing()
        Task { await playback.dropNeedleOnCuedSide() }
    }

    private func tapRecord() {
        guard !playback.isPlaying, playback.album != nil else { return }
        playback.flipCuedSide()
        withAnimation(.spring(duration: 0.8, bounce: 0.1)) { flip += 360 }
    }

    // MARK: Text

    private func bands(_ layout: DeckLayout) -> [CGFloat] {
        RecordFace.bands(for: playback.sideTimeline(playback.currentSide))
    }

    private var armValue: String {
        guard let side = sideLetter else { return "No record" }
        let total = playback.sideTimeline(playback.currentSide).total
        return "Side \(side), \(ClockFormat.clock(playback.sidePosition)) of \(ClockFormat.clock(total))"
    }

    private var sideLetter: String? {
        let sides = playback.layout.sides
        return sides.indices.contains(playback.currentSide) ? sides[playback.currentSide].letter : nil
    }
}

/// The tonearm's handle as VoiceOver reads it: "Tonearm", where the needle is on the side, and adjustable by 15 s.
private struct TonearmAccessibility: ViewModifier {
    let value: String
    let nudge: (Double) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement()
            .accessibilityLabel("Tonearm")
            .accessibilityValue(value)
            .accessibilityIdentifier("tonearmHandle")
            .accessibilityAdjustableAction { direction in
                nudge(direction == .increment ? 15 : -15)
            }
    }
}
