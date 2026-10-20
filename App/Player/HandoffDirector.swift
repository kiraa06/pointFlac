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
    @ObservationIgnored private(set) var startDate = Date()
    @ObservationIgnored private var beats: Task<Void, Never>?
    @ObservationIgnored private var track: TrackRow.ID?
    @ObservationIgnored private weak var playback: PlaybackController?
    @ObservationIgnored private var closeShelf: (() -> Void)?

    /// The rotation the record lands at; the deck starts its spin from it, so the hand-over is seamless.
    static let landingAngle = -40.0

    func elapsed(at date: Date) -> Double {
        isRunning ? date.timeIntervalSince(startDate) : timeline.duration
    }

    func start(
        album: AlbumCard, track: TrackRow.ID?, from rect: CGRect, playback: PlaybackController,
        closeShelf: @escaping () -> Void
    ) {
        beats?.cancel()
        self.album = album
        self.track = track
        self.playback = playback
        self.closeShelf = closeShelf
        palette = ArtPalette(seed: album.id)
        source = rect
        landed = false
        spinning = false
        sinking = false
        hidesTitle = true
        startDate = Date()
        isRunning = true
        // The old record comes off the platter: lift the needle before the new one travels.
        if playback.isPlaying { playback.player.pause() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let t = timeline
        let begin = ContinuousClock.now
        beats = Task { [weak self] in
            func wait(_ seconds: Double) async -> Bool {
                try? await Task.sleep(until: begin + .seconds(seconds), clock: .continuous)
                return !Task.isCancelled
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
            await self?.dropNeedle()
        }
    }

    /// The second tap: everything lands at once and the needle drops.
    func finishNow() {
        guard isRunning else { return }
        beats?.cancel()
        hidesTitle = false
        if !landed { land() }
        spinning = true
        Task { await dropNeedle() }
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

    private func dropNeedle() async {
        guard let playback, let album else { return }
        closeShelf?()
        let start = track.flatMap { id in playback.tracks.firstIndex { $0.id == id } } ?? 0
        if playback.album?.id != album.id { playback.cue(album, startingAt: track) }
        // The platter keeps spinning, and the arm holds the lead-in, until the player has the record: no stutter
        // between the hand-off's spin and the player's.
        await playback.play(fromTrack: start)
        isRunning = false
        spinning = false
        sinking = false
    }
}

/// The travelling sleeve and record, drawn above everything while the hand-off runs.
struct HandoffOverlay: View {
    let director: HandoffDirector
    let palette: ArtPalette

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
            let scale = 1 + (dst.width / max(size, 1) - 1) * arc
            ZStack {
                Color.black.opacity(0.001)
                if !director.landed, let album = director.album {
                    RecordDisc(albumID: album.id, artwork: album.artwork, bands: [], grooveInk: .black)
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(HandoffDirector.landingAngle * arc))
                        .scaleEffect(scale * (1 + 0.02 * slide))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                        .position(center)
                }
                if let album = director.album, sink < 1 {
                    ArtworkView(albumID: album.id, artwork: album.artwork)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 6)
                        .scaleEffect(1 + 0.06 * lift * (1 - sink))
                        .position(x: src.midX, y: src.midY - 6 * lift + 640 * sink)
                }
            }
        }
        .accessibilityLabel("Loading the record. Tap to finish.")
        .accessibilityAddTraits(.isButton)
    }
}
