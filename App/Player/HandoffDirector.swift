import Observation
import PFDesign
import SwiftUI
import UIKit

/// Runs the crate → deck hand-off (spec §4.5) on `HandoffTimeline`'s clock: it schedules the beats (sink, land, spin,
/// needle drop) and answers "where is everything at time t" for the overlay and the deck, which draw from a
/// `TimelineView`. A second tap calls `finishNow()`, which jumps to the end: the record lands and plays at once.
@MainActor
@Observable
final class HandoffDirector {
    let timeline = HandoffTimeline()
    private(set) var isRunning = false
    /// The shelf has started to sink (animated by SwiftUI over the step's length).
    private(set) var sinking = false
    /// The record is on the spindle: the deck draws it from here on, the overlay stops.
    private(set) var landed = false
    /// The platter is spinning up for the hand-off, before the needle drops.
    private(set) var spinning = false
    private(set) var hidesTitle = false
    private(set) var album: AlbumCard?
    private(set) var palette = ArtPalette(seed: "")
    /// The front sleeve's frame when tapped, in the player's coordinate space.
    private(set) var source: CGRect = .zero
    /// The record's frame on the platter, in the player's coordinate space; the deck keeps it current.
    var platterRect: CGRect = .zero
    /// The incoming record's track gaps, drawn while it flies so it lands looking exactly like the deck's record.
    private(set) var incomingBands: [CGFloat] = []
    /// The side the incoming record will be cued on, for its label.
    private(set) var incomingSide = "A"
    /// How far the shelf travels as it sinks; the sleeve in flight sinks with it.
    private(set) var sinkDistance: CGFloat = 0
    @ObservationIgnored private var startInstant = ContinuousClock.now
    @ObservationIgnored private var beats: Task<Void, Never>?
    /// The needle drop in flight, held so a later run can cancel it.
    @ObservationIgnored private var needle: Task<Void, Never>?
    /// Which hand-off is current: late work from an older run checks it and stands down.
    @ObservationIgnored private var generation = 0
    /// The needle drop has been started for this run.
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var track: TrackRow.ID?
    @ObservationIgnored private weak var playback: PlaybackController?
    @ObservationIgnored private var closeShelf: (() -> Void)?

    /// The rotation the record lands at; the deck starts its spin from it, so the hand-over is seamless.
    static let landingAngle = -40.0

    /// Seconds into the hand-off, on the one monotonic clock everything here uses. (The `date` a `TimelineView`
    /// passes is wall-clock time, so it is ignored: the clock is read when the frame is built.)
    func elapsed(at date: Date = Date()) -> Double {
        isRunning ? (ContinuousClock.now - startInstant).seconds : timeline.duration
    }

    /// Starts a hand-off. A no-op while one runs: a tap during the flight belongs to the overlay, which finishes it.
    func start(
        album: AlbumCard, track: TrackRow.ID?, from rect: CGRect, sinkDistance: CGFloat, playback: PlaybackController,
        closeShelf: @escaping () -> Void
    ) {
        guard !isRunning else { return }
        beats?.cancel()
        generation += 1
        let run = generation
        self.album = album
        self.track = track
        self.playback = playback
        self.closeShelf = closeShelf
        palette = ArtPalette(seed: album.id)
        source = rect
        self.sinkDistance = sinkDistance
        let cue = playback.cueSide(of: album, startingAt: track)
        incomingBands = RecordFace.bands(for: cue.timeline)
        incomingSide = cue.letter
        landed = false
        spinning = false
        sinking = false
        finishing = false
        hidesTitle = true
        let begin = ContinuousClock.now
        startInstant = begin
        isRunning = true
        // The old record comes off the platter: lift the needle before the new one travels.
        if playback.isPlaying { playback.player.pause() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let t = timeline
        beats = Task { [weak self] in
            @MainActor func wait(_ seconds: Double) async -> Bool {
                try? await Task.sleep(until: begin + .seconds(seconds), clock: .continuous)
                return !Task.isCancelled && self?.generation == run
            }
            guard await wait(t.start(.sink)) else { return }
            withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: t.end(.sink) - t.start(.sink))) {
                self?.sinking = true
            }
            guard await wait(t.start(.title)) else { return }
            withAnimation(.easeOut(duration: t.end(.title) - t.start(.title))) { self?.hidesTitle = false }
            guard await wait(t.landTime) else { return }
            self?.land()
            guard await wait(t.spinTime) else { return }
            self?.spinning = true
            guard await wait(t.duration) else { return }
            self?.finish(run)
        }
    }

    /// The second tap: the clock jumps to the end, everything lands at once and the needle drops.
    func finishNow() {
        guard isRunning else { return }
        beats?.cancel()
        startInstant = ContinuousClock.now - .seconds(timeline.duration)
        withAnimation(.easeOut(duration: 0.2)) {
            sinking = true
            hidesTitle = false
        }
        if !landed { land() }
        spinning = true
        finish(generation)
    }

    /// Where the shelf sits during the hand-off: sunk away once the sink step starts.
    func shelfOffset(_ height: CGFloat) -> CGFloat {
        sinking ? height : 0
    }

    private func land() {
        guard let album else { return }
        playback?.cue(album, startingAt: track)
        landed = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.9)
    }

    /// Drops the needle exactly once per run, from the timeline's end or the second tap, whichever comes first.
    private func finish(_ run: Int) {
        guard run == generation, !finishing else { return }
        finishing = true
        needle?.cancel()
        needle = Task { [weak self] in await self?.dropNeedle(run) }
    }

    private func dropNeedle(_ run: Int) async {
        guard let playback, let album else { return }
        closeShelf?()
        let start = track.flatMap { id in playback.tracks.firstIndex { $0.id == id } } ?? 0
        if playback.album?.id != album.id { playback.cue(album, startingAt: track) }
        // The platter keeps spinning, and the arm holds the lead-in, until the player has the record: no stutter
        // between the hand-off's spin and the player's.
        await playback.play(fromTrack: start)
        // A newer hand-off owns the state now; a late finish from this one must leave it alone.
        guard run == generation else { return }
        isRunning = false
        spinning = false
        sinking = false
        finishing = false
    }
}

/// The travelling sleeve and record, drawn above everything (the shelf included) while the hand-off runs.
///
/// The record is drawn exactly as the deck draws it (same size, style, track gaps and light) and scaled down to the
/// sleeve at the start, so at the landing the deck's record replaces it pixel for pixel. The sleeve is the shelf's own
/// `Sleeve`, standing in for the front sleeve (which the shelf hides meanwhile) and sinking with the shelf.
struct HandoffOverlay: View {
    let director: HandoffDirector
    let palette: ArtPalette
    @AppStorage(DeckPreferences.recordStyleKey) private var recordStyle = RecordStyle.standard.rawValue

    var body: some View {
        TimelineView(.animation) { context in
            let t = director.elapsed(at: context.date)
            let timeline = director.timeline
            let src = director.source
            let dst = director.platterRect
            let size = src.width
            let lift = timeline.progress(.lift, at: t)
            let slide = timeline.progress(.slide, at: t)
            let arc = timeline.progress(.arc, at: t)
            let sink = timeline.progress(.sink, at: t)
            let lin = min(max(arc, 0), 1)
            // The record leaves the sleeve upward, then arcs to the spindle: y leads x, so it rises before it swings.
            let startCenter = CGPoint(x: src.midX, y: src.midY - size * 0.65 * slide)
            let dx = dst.midX - startCenter.x
            let dy = dst.midY - startCenter.y
            let px = arc - 0.08 * sin(.pi * lin)
            let py = arc + 0.16 * sin(.pi * lin)
            let center = CGPoint(x: startCenter.x + dx * px, y: startCenter.y + dy * py)
            // Sleeve-sized at the start, the platter's size on landing; a slight swell as it leaves the sleeve, gone by
            // the time it lands.
            let fit = size / max(dst.width, 1)
            let scale = (fit + (1 - fit) * arc) * (1 + 0.02 * slide * (1 - lin))
            ZStack {
                Color.black.opacity(0.001)
                if !director.landed, let album = director.album {
                    RecordView(
                        face: RecordFace(
                            album: album, side: director.incomingSide, bands: director.incomingBands,
                            style: RecordStyle(rawValue: recordStyle) ?? .standard),
                        diameter: dst.width, angle: HandoffDirector.landingAngle * arc
                    )
                    // Lifted off the shelf, it casts a soft shadow that fades as it settles, to nothing on landing:
                    // there the deck's record, with only its own contact shadow, replaces it exactly.
                    .shadow(color: .black.opacity(0.35 * (1 - lin)), radius: 8 * (1 - lin), y: 5 * (1 - lin))
                    .scaleEffect(scale)
                    .position(center)
                }
                if let album = director.album, sink < 1 {
                    // The sink rides the shelf's own animation (same state, same transaction), not this clock, so
                    // the sleeve and the shelf it stands in for move as one.
                    Sleeve(album: album)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 0.06 * lift * (1 - sink))
                        .position(x: src.midX, y: src.midY - 6 * lift)
                        .offset(y: director.shelfOffset(director.sinkDistance))
                }
            }
        }
        .accessibilityLabel("Loading the record. Tap to finish.")
        .accessibilityAddTraits(.isButton)
    }
}
