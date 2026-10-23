import PFAudio
import PFDesign
import SwiftUI

/// The plinth's geometry, from its size: where the record, the pivot and the needle are, and the tonearm's lead-in and
/// run-out angles, solved so the needle really sits on the outer and inner grooves.
struct DeckLayout {
    let size: CGSize
    let recordCenter: CGPoint
    let recordRadius: CGFloat
    let pivot: CGPoint
    let armLength: CGFloat
    let arm: TonearmGeometry

    init(size: CGSize) {
        self.size = size
        let w = size.width
        let pad = w * 0.05
        let platter = min(w * 0.76, size.height - pad - Self.screenBand)
        recordRadius = platter / 2 * 0.94
        recordCenter = CGPoint(x: pad + platter / 2, y: pad + platter / 2)
        pivot = CGPoint(x: w - w * 0.1, y: w * 0.09)
        let reach = hypot(pivot.x - recordCenter.x, pivot.y - recordCenter.y)
        armLength = reach * 0.95
        let closest = atan2(pivot.x - recordCenter.x, recordCenter.y - pivot.y) * 180 / .pi
        let center = recordCenter
        let pivot = pivot
        let length = armLength
        func distance(_ angle: Double) -> Double {
            let r = angle * .pi / 180
            let needle = CGPoint(x: pivot.x - length * sin(r), y: pivot.y + length * cos(r))
            return hypot(needle.x - center.x, needle.y - center.y)
        }
        // Distance falls as the arm swings in, so bisect for the outer and inner groove radii.
        func solve(_ target: Double) -> Double {
            var lo = 0.0
            var hi = closest
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if distance(mid) > target { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
        let radius = Double(recordRadius)
        arm = TonearmGeometry(restAngle: 2, leadInAngle: solve(radius * 0.93), runoutAngle: solve(radius * 0.42))
    }

    /// Room under the platter for the dot-matrix screen.
    static let screenBand: CGFloat = 58

    /// The plinth's height for a width: the platter, its margin, and the screen's band.
    static func height(forWidth w: CGFloat) -> CGFloat {
        w * 0.05 + w * 0.76 + screenBand
    }

    func needle(at angle: Double) -> CGPoint {
        let r = angle * .pi / 180
        return CGPoint(x: pivot.x - armLength * sin(r), y: pivot.y + armLength * cos(r))
    }

    /// The arm angle pointing at `point` (a finger), from the pivot.
    func angle(toward point: CGPoint) -> Double {
        atan2(pivot.x - point.x, point.y - pivot.y) * 180 / .pi
    }

    /// The groove radius, as a fraction of the record's, under the needle at `fraction` of the side.
    func bandRadius(forFraction fraction: Double) -> CGFloat {
        let p = needle(at: arm.angle(forFraction: fraction))
        return hypot(p.x - recordCenter.x, p.y - recordCenter.y) / recordRadius
    }

    /// The track gaps of a side, as `RecordDisc` draws them. The hand-off's record in flight uses it too, so the record
    /// that lands looks exactly like the one that flew.
    func bands(for timeline: SideTimeline) -> [CGFloat] {
        guard timeline.total > 0 else { return [] }
        return timeline.starts.dropFirst().map { bandRadius(forFraction: $0 / timeline.total) }
    }
}

/// The glass turntable (spec §4.3): a frosted plinth, a strobe-dotted platter, the record as a picture disc, an
/// S-shaped tonearm and a dot-matrix screen. Played by hand: drag the tonearm to seek across the side (snapping into
/// track gaps, with a loupe), turn the record to jog (1.8 s a turn, applied on release), tap the tonearm at rest to
/// drop the needle, and tap the record while the needle is up to turn it over.
struct DeckStage: View {
    let playback: PlaybackController
    let theme: Theme
    let handoff: HandoffDirector
    let discSpace: Namespace.ID
    /// The display unfolded into the tracklist (plan 9 §3). The player owns it, so a tap anywhere off the stage folds
    /// it back too.
    @Binding var tracklistOpen: Bool

    @State private var spin = SpinModel()
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
    /// landed, the side's live position drives the arm again.
    struct ArmSwing {
        let serial: Int
        /// The arm's angle when the jump came.
        let from: Double
        let track: Int
        let side: Int
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

    var body: some View {
        GeometryReader { proxy in
            let layout = DeckLayout(size: proxy.size)
            ZStack(alignment: .topLeading) {
                plinth
                platterBase(layout)
                TimelineView(.animation(minimumInterval: nil, paused: timelinePaused)) { context in
                    let now = context.date.timeIntervalSinceReferenceDate
                    ZStack(alignment: .topLeading) {
                        record(layout, angle: recordAngle(now))
                            // A record Up Next pulls in arrives with a short settle (the hand-off's short form).
                            // Not during the hand-off, whose own record lands exactly where this one appears.
                            .transition(
                                handoff.isRunning ? .identity : .scale(scale: 0.7).combined(with: .opacity)
                            )
                            .animation(.spring(duration: 0.6, bounce: 0.2), value: playback.album?.id)
                        tonearm(layout, angle: armAngle(layout, at: context.date))
                            .opacity(armOpacity(at: context.date))
                    }
                }
                .accessibilityHidden(tracklistOpen)
                DeckScreen(
                    playback: playback, theme: theme, size: layout.size,
                    open: canUnfold ? { unfoldTracklist() } : nil
                )
                .accessibilityHidden(tracklistOpen)
                loupe(layout)
                tracklistPanel(layout)
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(PlayerSpace.name))
            } action: { frame in
                deckSize = frame.size
                let l = DeckLayout(size: frame.size)
                handoff.deckLayout = l
                handoff.platterRect = CGRect(
                    x: frame.minX + l.recordCenter.x - l.recordRadius,
                    y: frame.minY + l.recordCenter.y - l.recordRadius,
                    width: l.recordRadius * 2, height: l.recordRadius * 2)
            }
        }
        .onChange(of: playback.isPlaying, initial: true) { _, playing in
            spin.setSpinning(playing || handoff.spinning, at: Date.timeIntervalSinceReferenceDate)
        }
        .onChange(of: handoff.spinning) { _, spinning in
            spin.setSpinning(spinning || playback.isPlaying, at: Date.timeIntervalSinceReferenceDate)
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
        .task(id: swing?.serial) {
            // The swing hands the arm back once it has landed and the player has reached the song (a slow start
            // would otherwise pull the arm back to the old groove for a moment), or after a second more regardless.
            guard let current = swing else { return }
            try? await Task.sleep(for: .seconds(max(0, current.began.timeIntervalSinceNow) + current.duration))
            let deadline = Date().addingTimeInterval(1)
            while !Task.isCancelled, playback.trackIndex != current.track, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !Task.isCancelled, swing?.serial == current.serial { swing = nil }
        }
        .task(id: playback.isPlaying) {
            // Let the timeline run through the wind-down, then pause it.
            try? await Task.sleep(for: .seconds(spin.windDownSeconds + 0.1))
            restTick += 1
        }
    }

    // MARK: State

    private var timelinePaused: Bool {
        _ = restTick
        let now = Date.timeIntervalSinceReferenceDate
        return !playback.isPlaying && !handoff.isRunning && jog == nil && armDrag == nil && swing == nil
            && spin.isAtRest(at: now)
    }

    private var showsRecord: Bool {
        playback.album != nil && (!handoff.isRunning || handoff.landed)
    }

    private func recordAngle(_ now: Double) -> Double {
        if let jog, jog.engaged { return jog.baseAngle + jog.degrees }
        return spin.angle(at: now)
    }

    private func armAngle(_ layout: DeckLayout, at date: Date) -> Double {
        if let armDrag { return armDrag }
        if handoff.isRunning {
            let t = handoff.elapsed(at: date)
            let p = handoff.timeline.progress(.arm, at: t)
            return layout.arm.restAngle + (layout.arm.leadInAngle - layout.arm.restAngle) * p
        }
        if let swing { return swingAngle(swing, layout, at: date) }
        return liveArmAngle(layout)
    }

    /// Where the side's position puts the needle; at rest when nothing plays.
    private func liveArmAngle(_ layout: DeckLayout) -> Double {
        guard playback.trackIndex != nil, playback.player.status != .ended else { return layout.arm.restAngle }
        let total = playback.sideTimeline(playback.currentSide).total
        let fraction = total > 0 ? playback.sidePosition / total : 0
        return layout.arm.angle(forFraction: fraction)
    }

    // MARK: The swing

    /// The swinging arm at `date`: parked towards rest while the record turns over, then on its way to the song's
    /// groove, then holding there until the swing hands back.
    private func swingAngle(_ swing: ArmSwing, _ layout: DeckLayout, at date: Date) -> Double {
        let t = date.timeIntervalSince(swing.began)
        let rest = layout.arm.restAngle
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
    /// then.
    private func swingTarget(_ swing: ArmSwing, _ layout: DeckLayout) -> Double {
        if playback.trackIndex == swing.track, playback.player.status != .ended { return liveArmAngle(layout) }
        let total = playback.sideTimeline(swing.side).total
        guard total > 0 else { return layout.arm.leadInAngle }
        return layout.arm.angle(forFraction: playback.layout.offset(ofTrack: swing.track) / total)
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
        let layout = DeckLayout(size: deckSize)
        let now = Date()
        let from: Double
        if let swing {
            from = swingAngle(swing, layout, at: now)
        } else if let position = jump.fromPosition {
            let total = playback.sideTimeline(jump.fromSide).total
            from = total > 0 ? layout.arm.angle(forFraction: position / total) : layout.arm.restAngle
        } else {
            from = layout.arm.restAngle
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
            serial: jump.serial, from: from, track: jump.track, side: side, began: now.addingTimeInterval(hold),
            park: turns && !reduceMotion ? Self.flipSeconds : 0, fades: reduceMotion)
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

    /// How far the unfolded display sits inside the plinth's edge.
    static let panelInset: CGFloat = 8

    /// Something to list, and nothing else under way.
    private var canUnfold: Bool {
        playback.album != nil && !playback.tracks.isEmpty && !handoff.isRunning
    }

    private func unfoldTracklist() {
        guard canUnfold else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.15)) {
            tracklistOpen = true
        }
    }

    private func foldTracklist() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.15)) {
            tracklistOpen = false
        }
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

    /// The panel grows out of the display: scaled about the point that maps the panel's frame onto the display's, so
    /// at the start it is exactly the display, and fading in on the way. Under Reduce Motion, a cross-fade.
    private func unfold(_ layout: DeckLayout) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let size = layout.size
        let inset = Self.panelInset
        let display = DeckScreen.frame(in: size)
        let panel = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        guard panel.width > display.width, panel.height > display.height else { return .opacity }
        let scale = CGSize(width: display.width / panel.width, height: display.height / panel.height)
        // The fixed point A of a scale s that takes the panel's edge (at `inset`) to the display's: A + s(inset - A)
        // is the display's edge.
        let anchor = UnitPoint(
            x: (display.minX - inset * scale.width) / (1 - scale.width) / size.width,
            y: (display.minY - inset * scale.height) / (1 - scale.height) / size.height)
        return .modifier(
            active: Unfold(scale: scale, anchor: anchor, opacity: 0),
            identity: Unfold(scale: CGSize(width: 1, height: 1), anchor: anchor, opacity: 1))
    }

    // MARK: Pieces

    private var plinth: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [theme.plinthTop, theme.plinthBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .glassEffect(.regular.tint(theme.plinthTop.opacity(0.2)), in: .rect(cornerRadius: 26))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(theme.plinthEdge, lineWidth: 1)
            )
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.08), radius: 14, y: 10)
    }

    private func platterBase(_ layout: DeckLayout) -> some View {
        let d = layout.recordRadius * 2 / 0.94
        return ZStack {
            Canvas { context, size in
                // The strobe dots round the platter's rim.
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = size.width / 2 - 2
                for i in 0..<180 {
                    let a = Double(i) * .pi / 90
                    let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                    context.fill(
                        Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)), with: .color(theme.strobe)
                    )
                }
            }
            Circle().fill(
                RadialGradient(
                    colors: [Color(white: 0.24), Color(white: 0.12)], center: .center, startRadius: 0,
                    endRadius: d / 2)
            )
            .padding(d * 0.035)
            Circle().fill(Color(white: 0.88)).frame(width: 8, height: 8).shadow(radius: 1)
        }
        .frame(width: d, height: d)
        .position(layout.recordCenter)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func record(_ layout: DeckLayout, angle: Double) -> some View {
        if showsRecord, let album = playback.album {
            let d = layout.recordRadius * 2
            RecordDisc(
                albumID: album.id, artwork: album.artwork, bands: bands(layout), grooveInk: .black
            )
            .equatable()
            .rotationEffect(.degrees(angle))
            .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .overlay(RecordSheen())
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
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

    private func tonearm(_ layout: DeckLayout, angle: Double) -> some View {
        let length = layout.armLength
        return ZStack(alignment: .top) {
            TonearmShape()
                .fill(
                    LinearGradient(
                        colors: theme.isDark
                            ? [Color(white: 0.85), Color(white: 0.45), Color(white: 0.8)]
                            : [Color(white: 0.97), Color(white: 0.68), Color(white: 0.93)],
                        startPoint: .leading, endPoint: .trailing)
                )
                .shadow(color: .black.opacity(0.28), radius: 3, x: 2, y: 3)
                .frame(width: 44, height: length + 18)
            // The handle: a generous target round the headshell, where a finger naturally grabs the arm.
            Circle().fill(Color.white.opacity(0.001)).frame(width: 64, height: 64)
                .offset(y: length - 24)
                .accessibilityElement()
                .accessibilityLabel("Tonearm")
                .accessibilityValue(armValue)
                .accessibilityIdentifier("tonearmHandle")
                .accessibilityAdjustableAction { direction in
                    nudge(direction == .increment ? 15 : -15)
                }
        }
        .frame(width: 64, height: length + 48, alignment: .top)
        .rotationEffect(.degrees(angle), anchor: .top)
        .position(x: layout.pivot.x, y: layout.pivot.y + (length + 48) / 2)
        .overlay {
            Circle()
                .fill(
                    RadialGradient(colors: [.white, Color(white: 0.7)], center: .center, startRadius: 0, endRadius: 14)
                )
                .frame(width: 28, height: 28).shadow(color: .black.opacity(0.25), radius: 2, y: 2)
                .position(layout.pivot)
        }
        .gesture(armGesture(layout))
        .simultaneousGesture(TapGesture().onEnded { tapTonearm() })
        .sensoryFeedback(.selection, trigger: snapTrack)
    }

    /// The display unfolded into the tracklist, over the platter, inset from the plinth's edge.
    @ViewBuilder
    private func tracklistPanel(_ layout: DeckLayout) -> some View {
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
                playback: playback, theme: theme, pick: { pickFromDisplay($0) }, fold: { foldTracklist() }
            )
            .padding(Self.panelInset)
            .frame(width: layout.size.width, height: layout.size.height)
            .transition(unfold(layout))
            .zIndex(2)
        }
    }

    @ViewBuilder
    private func loupe(_ layout: DeckLayout) -> some View {
        if let armDrag {
            let timeline = playback.sideTimeline(playback.currentSide)
            let raw = layout.arm.fraction(forAngle: armDrag) * timeline.total
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

    private func armGesture(_ layout: DeckLayout) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard playback.album != nil, !handoff.isRunning else { return }
                let raw = min(max(layout.angle(toward: value.location), layout.arm.restAngle), layout.arm.runoutAngle)
                let timeline = playback.sideTimeline(playback.currentSide)
                let seconds = layout.arm.fraction(forAngle: raw) * timeline.total
                // Gaps are bands about 1.5 % of the side wide: wide enough to feel, narrow enough to pass.
                let snapped = timeline.snapped(seconds, tolerance: timeline.total * 0.015)
                if raw >= layout.arm.leadInAngle, let track = snapped.track, timeline.total > 0 {
                    armDrag = layout.arm.angle(forFraction: snapped.seconds / timeline.total)
                    snapTrack = track
                } else {
                    armDrag = raw
                    if snapped.track == nil { snapTrack = nil }
                }
            }
            .onEnded { _ in
                guard let angle = armDrag else { return }
                armDrag = nil
                snapTrack = nil
                guard angle >= layout.arm.leadInAngle - 1 else { return }
                let timeline = playback.sideTimeline(playback.currentSide)
                let seconds = layout.arm.fraction(forAngle: angle) * timeline.total
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
        let side = playback.currentSide
        let target = playback.sidePosition + seconds
        Task { await playback.seek(side: side, to: target) }
    }

    private func nudge(_ seconds: Double) {
        jogBy(seconds)
    }

    private func tapTonearm() {
        guard !handoff.isRunning, playback.album != nil, !playback.isPlaying else { return }
        Task { await playback.dropNeedleOnCuedSide() }
    }

    private func tapRecord() {
        guard !playback.isPlaying, playback.album != nil else { return }
        playback.flipCuedSide()
        withAnimation(.spring(duration: 0.8, bounce: 0.1)) { flip += 360 }
    }

    // MARK: Text

    private func bands(_ layout: DeckLayout) -> [CGFloat] {
        layout.bands(for: playback.sideTimeline(playback.currentSide))
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

/// The deck's dot-matrix screen and what it says: track code, title, artist, time, and the rate and depth. A view of
/// its own because it reads the player's position, which changes ten times a second: only this screen redraws.
/// Tapping it unfolds the record's tracklist (plan 9 §3), when `open` is given.
struct DeckScreen: View {
    let playback: PlaybackController
    let theme: Theme
    let size: CGSize
    var open: (() -> Void)?

    /// Where the screen sits on a plinth of `size`: bottom right, under the platter. The unfolding tracklist grows
    /// out of this frame.
    static func frame(in size: CGSize) -> CGRect {
        let w = size.width * 0.5
        let h: CGFloat = 38
        return CGRect(x: size.width - w - size.width * 0.045, y: size.height - h - 12, width: w, height: h)
    }

    var body: some View {
        let lines = lcdLines
        let frame = Self.frame(in: size)
        DotMatrixScreen(lines: lines, ink: theme.lcdInk, back: theme.lcdBack)
            .frame(width: frame.width, height: frame.height)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { open?() }
            .position(x: frame.midX, y: frame.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lines.joined(separator: ", "))
            .accessibilityAddTraits(open == nil ? [] : .isButton)
            .accessibilityHint(open == nil ? "" : "Unfolds the record's tracklist")
            .accessibilityAction { open?() }
            .accessibilityIdentifier("deckDisplay")
    }

    private var sideLetter: String? {
        let sides = playback.layout.sides
        return sides.indices.contains(playback.currentSide) ? sides[playback.currentSide].letter : nil
    }

    private var lcdLines: [String] {
        guard let album = playback.album else { return ["NO RECORD", "—"] }
        let format = playback.player.signal.source.map { "\($0.sampleRate / 1000)K/\($0.bitsPerSample)" } ?? ""
        if let index = playback.trackIndex {
            let track = playback.tracks[index]
            return [
                "\(playback.layout.code(ofTrack: index)) \(track.title.uppercased())·\(track.artist.uppercased())",
                "\(ClockFormat.clock(playback.player.position.seconds))  33⅓  \(format)",
            ]
        }
        return ["\(album.title.uppercased())·\(album.artist.uppercased())", "CUE \(sideLetter ?? "A")1  33⅓"]
    }
}

/// A record: the art as a picture disc under fine grooves, lighter bands at the track gaps, a centre label and the
/// spindle hole. Its inputs are plain values, so SwiftUI redraws it only when the record changes, never per frame:
/// the spin is a rotation applied to it.
struct RecordDisc: View, Equatable {
    let albumID: String
    let artwork: Data?
    /// Track-gap radii, as fractions of the record's radius.
    let bands: [CGFloat]
    let grooveInk: Color

    var body: some View {
        ZStack {
            ArtworkView(albumID: albumID, artwork: artwork, pixels: 900)
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = size.width / 2
                var radius = r * 0.98
                while radius > r * 0.36 {
                    let ring = Path(
                        ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(ring, with: .color(grooveInk.opacity(0.22)), lineWidth: 0.7)
                    radius -= 2.4
                }
                for band in bands {
                    let b = r * band
                    let ring = Path(ellipseIn: CGRect(x: c.x - b, y: c.y - b, width: b * 2, height: b * 2))
                    context.stroke(ring, with: .color(.white.opacity(0.55)), lineWidth: 1.6)
                }
            }
            Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1.5).padding(0)
            // The label.
            GeometryReader { proxy in
                let s = proxy.size.width
                ZStack {
                    ArtworkView(albumID: albumID, artwork: artwork)
                        .frame(width: s * 0.3, height: s * 0.3)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                    Circle().fill(Color(white: 0.86)).frame(width: max(6, s * 0.03), height: max(6, s * 0.03))
                }
                .frame(width: s, height: s)
            }
        }
        .clipShape(Circle())
        .compositingGroup()
    }
}

/// The still light sheen on the record: it stays put while the record turns under it.
struct RecordSheen: View {
    var body: some View {
        AngularGradient(
            stops: [
                .init(color: .clear, location: 0), .init(color: .clear, location: 0.06),
                .init(color: .white.opacity(0.26), location: 0.08), .init(color: .clear, location: 0.12),
                .init(color: .clear, location: 0.52), .init(color: .white.opacity(0.16), location: 0.56),
                .init(color: .clear, location: 0.6), .init(color: .clear, location: 1),
            ], center: .center, angle: .degrees(300)
        )
        .clipShape(Circle())
        .allowsHitTesting(false)
    }
}

/// The S-shaped tonearm, hanging down from its pivot at the top centre of its frame, with the headshell at the
/// bottom. The deck rotates it about the pivot.
struct TonearmShape: Shape {
    func path(in rect: CGRect) -> Path {
        var tube = Path()
        let x = rect.midX
        let h = rect.height - 18
        tube.move(to: CGPoint(x: x, y: 8))
        tube.addCurve(
            to: CGPoint(x: x, y: h * 0.88), control1: CGPoint(x: x + 9, y: h * 0.45),
            control2: CGPoint(x: x - 11, y: h * 0.7))
        var path = tube.strokedPath(StrokeStyle(lineWidth: 5, lineCap: .round))
        // The headshell, angled as on a real S-arm.
        let head = CGRect(x: x - 6, y: h * 0.86, width: 12, height: 26)
        path.addPath(
            Path(roundedRect: head, cornerRadius: 3)
                .applying(
                    CGAffineTransform(translationX: head.midX, y: head.minY).rotated(by: -0.28)
                        .translatedBy(x: -head.midX, y: -head.minY)))
        // The counterweight behind the pivot.
        path.addPath(Path(roundedRect: CGRect(x: x - 7, y: -2, width: 14, height: 14), cornerRadius: 4))
        return path
    }
}

/// The deck's dot-matrix screen: SF Mono through a pixel grid, with a faint glow.
struct DotMatrixScreen: View {
    let lines: [String]
    let ink: Color
    let back: Color

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(back)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).lineLimit(1)
                }
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(ink)
            .shadow(color: ink.opacity(0.6), radius: 3)
            .padding(.horizontal, 8)
            DotGrid(back: back)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The pixel grid laid over the dot-matrix faces: dark lines between the dots break the glyphs into a matrix. It
/// stays put while what is under it scrolls, as a real display's pixels do.
struct DotGrid: View {
    let back: Color

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)), with: .color(back.opacity(0.75)))
                x += 1.6
            }
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)), with: .color(back.opacity(0.75)))
                y += 1.6
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The deck's display unfolded over the platter (plan 9 §3): the record's songs in the dot-matrix face, side by side,
/// as `A1  IGNITION  3:10`, with the playing song inverted. A song tapped plays and the display folds back; the header
/// folds it back without playing anything.
struct DeckTracklist: View {
    let playback: PlaybackController
    let theme: Theme
    let pick: (Int) -> Void
    let fold: () -> Void
    /// The rows' face, growing with Dynamic Type up to what the panel can hold.
    @ScaledMetric(relativeTo: .subheadline) private var face: CGFloat = 14
    /// The song just tapped: inverted at once, before the player has moved to it.
    @State private var picked: Int?

    private var playing: Int? { picked ?? playback.trackIndex }
    private var size: CGFloat { min(face, 22) }
    /// 34 pt at the 14 pt face, and in step with it: the rows keep their rhythm as the face grows.
    private var rowHeight: CGFloat { size * 34 / 14 }
    private var ink: Color { theme.lcdInk }
    private var back: Color { theme.lcdBack }

    var body: some View {
        let list = Tracklist(tracks: playback.tracks, layout: playback.layout)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(back)
            VStack(alignment: .leading, spacing: 0) {
                header(list)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(list.sides) { side in
                                Text("— SIDE \(side.letter) —")
                                    .font(.system(size: size * 0.8, weight: .bold, design: .monospaced))
                                    .tracking(1)
                                    .foregroundStyle(ink.opacity(0.6))
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .accessibilityLabel("Side \(side.letter)")
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(side.songs) { song in
                                    row(song, codeWidth: codeWidth(list)).id(song.index)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .onAppear {
                        if let playing { proxy.scrollTo(playing, anchor: .center) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            DotGrid(back: back)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ink.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.3), radius: 20, y: 12)
        .sensoryFeedback(.selection, trigger: picked)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { fold() }
        .accessibilityIdentifier("deckTracklist")
    }

    /// `NIGHT DRIVE   5 TRK 19:05`, a shade dimmer than the rows. Tapping it folds the display back.
    private func header(_ list: Tracklist) -> some View {
        let album = playback.album
        return Button(action: fold) {
            HStack(spacing: 12) {
                Text((album?.title ?? "").uppercased())
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(list.songCount) TRK \(Tracklist.clock(list.seconds))")
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: size * 0.82, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(ink.opacity(0.72))
            .shadow(color: ink.opacity(0.35), radius: 3)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(album?.title ?? ""), \(list.spokenSummary)")
        .accessibilityHint("Folds the display back")
        .accessibilityIdentifier("deckTracklistHeader")
    }

    /// The code column: as wide as the longest code in the face (SF Mono's glyphs are 0.6 em, plus the tracking), so
    /// the titles line up and an "A10" never pushes its title out of line.
    private func codeWidth(_ list: Tracklist) -> CGFloat {
        let longest = list.sides.flatMap(\.songs).map(\.code.count).max() ?? 2
        return CGFloat(longest) * (size * 0.6 + 1)
    }

    private func row(_ song: Tracklist.Song, codeWidth: CGFloat) -> some View {
        let current = song.index == playing
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { picked = song.index }
            pick(song.index)
        } label: {
            HStack(spacing: 14) {
                Text(song.code)
                    .fixedSize()
                    .frame(minWidth: codeWidth, alignment: .leading)
                Text(song.title.uppercased())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Tracklist.clock(song.seconds))
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(current ? back : ink)
            .shadow(color: current ? .clear : ink.opacity(0.5), radius: 3)
            .padding(.horizontal, 8)
            .frame(minHeight: rowHeight)
            .background {
                if current {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ink)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Tracklist.label(song))
        .accessibilityValue(current ? "Playing" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("deckTrack-\(song.index)")
    }
}

/// The unfolding display's in-between: scaled about `anchor` and faded.
private struct Unfold: ViewModifier {
    let scale: CGSize
    let anchor: UnitPoint
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scale.width, y: scale.height, anchor: anchor)
            .opacity(opacity)
    }
}

/// The dark loupe that follows a hand on the deck: what is under the needle, to the millisecond, over a waveform
/// hint. The waveform is a placeholder drawn from the track's index until the library supplies real peaks.
struct Loupe: View {
    let heading: String
    let value: String
    let detail: String?
    let seed: Int
    let phase: Double
    @Environment(\.isMonochrome) private var mono

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(heading).font(.system(size: 10, weight: .semibold, design: .monospaced)).lineLimit(1)
            Text(value).font(.system(size: 22, weight: .bold, design: .monospaced)).monospacedDigit()
                .accessibilityIdentifier("loupeValue")
            if let detail {
                Text(detail).font(.system(size: 11, design: .monospaced)).opacity(0.75)
            }
            Canvas { context, size in
                let bars = 44
                let w = size.width / CGFloat(bars)
                for i in 0..<bars {
                    let x = Double(i) + phase * 8
                    let h = 0.25 + 0.75 * abs(sin(x * 0.37 + Double(seed)) * cos(x * 0.11 + Double(seed) * 0.7))
                    let fade = 1 - abs(Double(i) - Double(bars) / 2) / Double(bars) * 1.4
                    let bar = CGRect(
                        x: CGFloat(i) * w, y: size.height * (1 - h) / 2, width: w * 0.55, height: size.height * h)
                    context.fill(
                        Path(bar),
                        with: .color(
                            (mono ? Color(white: 0.9) : Color(red: 0.49, green: 1, blue: 0.7)).opacity(max(0.2, fade))))
                }
                context.fill(
                    Path(CGRect(x: size.width / 2 - 0.75, y: -2, width: 1.5, height: size.height + 4)),
                    with: .color(.white))
            }
            .frame(width: 150, height: 20)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.07)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deckLoupe")
    }
}
