import Observation
import PFCore
import PFDesign
import QuartzCore
import SwiftUI

/// What the galaxy draws in one frame, in the canvas's own points, back to front.
struct GalaxyFrame {
    struct Item {
        /// The album, which is also its symbol's tag.
        let id: AlbumCard.ID
        /// Its sleeve's frame, unlifted.
        let rect: CGRect
        let opacity: Double
        /// Its rank, for a touch; nil for a sleeve that is only fading out.
        let rank: Int?
    }

    var items: [Item] = []
    /// The sleeve under the finger, drawn last and lifted by `lift` (0…1).
    var raised: Item?
    var lift: Double = 0

    /// How much a lifted sleeve grows on each side, as a share of its side: 3%, so 6% in all.
    static let liftGrowth = 0.03
}

/// The Shelf galaxy (spec §2): every album a sleeve around the centre, the top of the sort biggest in the middle. It
/// lays the albums out, flies them on a re-sort, runs the collision physics while a sleeve is dragged, and keeps the
/// camera, then says where everything is at any time for the view's `TimelineView`.
///
/// Why most of the state is `@ObservationIgnored`: positions change every frame (drift, flights, physics, a pan), and
/// the timeline asks for them every frame anyway. Were they observed, each change would invalidate the Shelf's body
/// and its accessibility tree 120 times a second. Only discrete events are observed: a new layout, a settled drag or
/// camera (`restRevision`, which moves the accessibility frames), the press timer, and whether anything is moving
/// (`isLive`, which under Reduce Motion is all that keeps the timeline running).
///
/// Why a resting frame costs no physics: a resting sleeve is its home plus `Drift.offset`, a pure function of the
/// clock. `GalaxyPhysics` runs only from a drag's start until everything it pushed has settled; then the bodies'
/// centres become the homes, and the galaxy is analytic again.
@MainActor
@Observable
final class GalaxyModel {
    nonisolated static let metrics = GalaxyMetrics()

    // MARK: Observed

    /// The albums in rank order, as last laid out.
    private(set) var albums: [AlbumCard] = []
    /// Every album that has a sleeve on screen: `albums`, plus any still fading out of the last layout.
    private(set) var symbols: [AlbumCard] = []
    /// Something moves besides the idle drift: a flight, a fade, a drag and its settle, a pan, a pinch.
    private(set) var isLive = false
    /// Bumped when the resting places or the camera settle, so the accessibility frames follow.
    private(set) var restRevision = 0
    /// Bumped on each touch that lands on a sleeve, and zeroed when it ends: the view's hold timer is keyed by it.
    private(set) var pressToken = 0
    /// Bumped when a drag picks a sleeve up, for its haptic.
    private(set) var pickUps = 0
    /// The area's size in points.
    private(set) var size: CGSize = .zero

    // MARK: Per frame (not observed)

    @ObservationIgnored private var stars: [Star] = []
    @ObservationIgnored private var leaving: [Star] = []
    @ObservationIgnored private var motion: Motion?
    @ObservationIgnored private var fade: Fade?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var camera = Camera()
    @ObservationIgnored private var tween: CameraTween?
    /// A pan's coast after the finger lifts, in world points per second.
    @ObservationIgnored private var glide: CGVector?
    @ObservationIgnored private var touch: Touch = .idle
    @ObservationIgnored private var pinch: Pinch?
    @ObservationIgnored private var lift: Lift?
    /// The user moved the camera since the last layout, so a resize keeps it instead of refitting.
    @ObservationIgnored private var cameraTouched = false
    /// Where sleeves may go and the camera may look: the layout, and at least the area as first fitted.
    @ObservationIgnored private var bounds = CGRect.zero
    @ObservationIgnored private var slots: [GalaxySlot] = []
    @ObservationIgnored private var lastTime: Double?
    @ObservationIgnored private var lastFrame = GalaxyFrame()
    /// The area's frame in the player's coordinate space, for the hand-off.
    @ObservationIgnored private var origin: CGPoint = .zero
    /// Space kept clear at the top of the area (the fallback note), in points.
    @ObservationIgnored private var topInset: CGFloat = 0
    /// Bumped by every layout, so a placement finishing off the main actor after a newer one stands down.
    @ObservationIgnored private var generation = 0
    /// `updateSway`'s buffers, kept so a frame allocates nothing: the bodies in x order, and each one's drift limit.
    @ObservationIgnored private var swayOrder: [Int] = []
    @ObservationIgnored private var swayLimit: [Double] = []
    @ObservationIgnored private var reduceMotion = false

    /// Placements are a pure function of the count, so one per count serves every sort.
    private static var placements: [Int: [GalaxySlot]] = [:]

    // MARK: Constants

    /// A re-sort (spec §2): in-out cubic over 1.1 s, staggered by rank, each side dipping up to 38% mid-flight.
    private static let flightDuration = 1.1
    private static let flightDip = 0.38
    /// The galaxy forming each time it appears: sleeves rush out from near the centre and grow into place.
    private static let entranceDuration = 0.8
    /// Reduce Motion's cross-fade into a new layout.
    private static let fadeDuration = 0.25
    /// A touch that moves less than this is a tap or a hold; more, a drag or a pan.
    static let slop: CGFloat = 8
    static let holdDelay = 0.45
    /// The smallest target a touch looks for, in screen points: tiny sleeves at a small zoom are still easy to hit.
    private static let minimumTarget: CGFloat = 44
    private static let zoomRange = 0.5...2.0
    private static let fitRange = 0.55...1.0
    /// Physics runs at 120 steps a second, the screen's rate. `GalaxyPhysics`'s damping (0.90 a step) was tuned at 60
    /// steps a second, so before each step the free bodies' velocities are scaled by √0.9 / 0.9: a shove and a throw
    /// then coast exactly as far, and as long, as at 60.
    private static let stepsPerSecond = 120.0
    private static let carry = 0.9.squareRoot() / 0.9
    /// The fastest throw, in points per second, so a flick can't send a sleeve far out of reach.
    private static let maxThrow = 1600.0
    /// A drag's settle gives up after this long and keeps what it has.
    private static let settleLimit = 6.0

    // MARK: Layout

    /// Lays `albums` (in rank order) out. `fresh` is the galaxy appearing: a new arrangement with the entrance;
    /// otherwise everything flies from where it is to its new place, dropped positions discarded. Above 200 albums the
    /// placement runs off the main actor, and the previous layout stays until it is ready.
    func arrange(_ albums: [AlbumCard], fresh: Bool, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        generation += 1
        let run = generation
        let count = albums.count
        if let cached = Self.placements[count] {
            apply(albums, slots: cached, fresh: fresh)
        } else if count <= 200 {
            let placed = GalaxyLayout.place(count: count, metrics: Self.metrics)
            Self.placements[count] = placed
            apply(albums, slots: placed, fresh: fresh)
        } else {
            Task { [weak self] in
                let placed = await Task.detached(priority: .userInitiated) {
                    GalaxyLayout.place(count: count, metrics: GalaxyModel.metrics)
                }.value
                Self.placements[count] = placed
                guard let self, self.generation == run else { return }
                self.apply(albums, slots: placed, fresh: fresh)
            }
        }
    }

    /// New details for the same albums in the same order (a listen counted, artwork arrived): no movement.
    func refresh(_ albums: [AlbumCard]) {
        guard albums.map(\.id) == self.albums.map(\.id) else { return }
        self.albums = albums
        for index in stars.indices { stars[index].album = albums[index] }
        symbols = albums + leaving.map(\.album)
    }

    private func apply(_ albums: [AlbumCard], slots: [GalaxySlot], fresh: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        let first = fresh || stars.isEmpty
        // Where everything is drawn right now, so the new motion starts from exactly there.
        var current: [AlbumCard.ID: Pose] = [:]
        if !first {
            if let session { commit(session) }
            for star in stars { current[star.album.id] = pose(star, at: now) }
            for star in leaving where current[star.album.id] == nil { current[star.album.id] = pose(star, at: now) }
        }
        let ghosts = reduceMotion && !first ? lastFrame.items.filter { $0.rank != nil } : []
        let fromCamera = camera
        self.slots = slots
        let fitted = fit(slots)
        bounds = worldBounds(slots, camera: fitted)
        let n = Double(max(albums.count, 1))
        let stagger = min(0.014, 0.6 / n)
        var next: [Star] = []
        next.reserveCapacity(albums.count)
        for (rank, album) in albums.enumerated() {
            let slot = slots[rank]
            var star = Star(album: album, seed: Drift.seed(for: album.id), home: slot.center, side: slot.side)
            star.delay = Double(rank) * stagger
            if first {
                // The entrance: from a third of the way out, small and clear, into place.
                star.from = CGPoint(x: slot.center.x * 0.3, y: slot.center.y * 0.3)
                star.fromSide = slot.side * 0.35
                star.fromSway = 0
                star.fromOpacity = 0
            } else if let was = current[album.id] {
                star.from = was.base
                star.fromSide = was.side
                star.fromSway = was.sway
                star.fromOpacity = was.opacity
            } else {
                // New to the galaxy (a filter widened, an import): it blooms in at its place.
                star.from = slot.center
                star.fromSide = slot.side * 0.2
                star.fromSway = 0
                star.fromOpacity = 0
            }
            next.append(star)
        }
        let kept = Set(albums.map(\.id))
        var known: [AlbumCard.ID: AlbumCard] = [:]
        for star in stars + leaving { known[star.album.id] = star.album }
        leaving =
            first
            ? []
            : current.compactMap { id, was -> Star? in
                guard !kept.contains(id), let album = known[id] else { return nil }
                var star = Star(album: album, seed: Drift.seed(for: id), home: was.base, side: was.side * 0.2)
                star.from = was.base
                star.fromSide = was.side
                star.fromSway = was.sway
                star.fromOpacity = was.opacity
                star.sway = 0
                star.opacity = 0
                return star
            }
        stars = next
        session = nil
        lift = nil
        glide = nil
        cameraTouched = false
        let maxDelay = Double(max(albums.count - 1, 0)) * stagger
        if reduceMotion {
            motion = nil
            leaving = []
            camera = fitted
            tween = nil
            fade = Fade(start: now, ghosts: ghosts)
        } else if first {
            camera = fitted
            tween = nil
            motion = Motion(kind: .entrance, start: now, duration: Self.entranceDuration, dip: 0, delay: maxDelay)
        } else {
            motion = Motion(
                kind: .flight, start: now, duration: Self.flightDuration, dip: Self.flightDip, delay: maxDelay)
            tween = CameraTween(from: fromCamera, to: fitted, start: now, duration: Self.flightDuration)
        }
        self.albums = albums
        symbols = albums + leaving.map(\.album)
        restRevision += 1
        updateLive()
    }

    /// The camera that shows the whole layout: centred on the origin, as large as fits, within 0.55…1.0.
    private func fit(_ slots: [GalaxySlot]) -> Camera {
        guard size.width > 0, size.height > topInset else { return Camera() }
        var extentX = 1.0
        var extentY = 1.0
        for slot in slots {
            extentX = max(extentX, abs(Double(slot.center.x)) + slot.side / 2)
            extentY = max(extentY, abs(Double(slot.center.y)) + slot.side / 2)
        }
        let margin = 14.0
        let zoom = min((size.width / 2 - margin) / extentX, ((size.height - topInset) / 2 - margin) / extentY)
        return Camera(center: .zero, zoom: min(max(zoom, Self.fitRange.lowerBound), Self.fitRange.upperBound))
    }

    /// The layout's extent, and at least what `camera` shows: sleeves thrown or shoved stay on a screen that fits
    /// the galaxy, and a big galaxy can be explored to its edge.
    private func worldBounds(_ slots: [GalaxySlot], camera: Camera) -> CGRect {
        let halfWidth = size.width / 2 / camera.zoom
        let halfHeight = (size.height - topInset) / 2 / camera.zoom
        var rect = CGRect(x: -halfWidth, y: -halfHeight, width: 2 * halfWidth, height: 2 * halfHeight)
            .insetBy(dx: 6 / camera.zoom, dy: 6 / camera.zoom)
        for slot in slots {
            rect = rect.union(
                CGRect(
                    x: slot.center.x - slot.side / 2, y: slot.center.y - slot.side / 2, width: slot.side,
                    height: slot.side))
        }
        return rect
    }

    // MARK: Geometry

    /// The canvas's frame in the player's space (its size refits an untouched camera), and the space at its top.
    func place(frame: CGRect, topInset inset: CGFloat) {
        origin = frame.origin
        guard frame.size != size || inset != topInset else { return }
        size = frame.size
        topInset = inset
        refit()
    }

    /// Keeps `top` points clear at the top of the area (the fallback note came or went).
    func keepClear(top: CGFloat) {
        guard top != topInset else { return }
        topInset = top
        refit()
    }

    private func refit() {
        guard !slots.isEmpty, !cameraTouched else { return }
        camera = fit(slots)
        tween = nil
        bounds = worldBounds(slots, camera: camera)
        restRevision += 1
    }

    /// Where the world point `p` is on screen.
    private func screen(_ p: CGPoint, _ camera: Camera) -> CGPoint {
        CGPoint(
            x: (p.x - camera.center.x) * camera.zoom + size.width / 2,
            y: (p.y - camera.center.y) * camera.zoom + topInset + (size.height - topInset) / 2)
    }

    private func world(_ s: CGPoint, _ camera: Camera) -> CGPoint {
        CGPoint(
            x: (s.x - size.width / 2) / camera.zoom + camera.center.x,
            y: (s.y - topInset - (size.height - topInset) / 2) / camera.zoom + camera.center.y)
    }

    /// The resting frame of the sleeve at `rank` on screen, no drift: for its accessibility element.
    func restingRect(rank: Int) -> CGRect {
        guard stars.indices.contains(rank) else { return .zero }
        let star = stars[rank]
        let home = session.map { $0.physics.bodies[rank].center } ?? star.home
        let center = screen(home, camera)
        let side = star.side * camera.zoom
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// `rect` in the canvas, in the player's space.
    func playerRect(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: Frames

    /// Everything at `date`, advancing the physics, the flights and the camera to it first. `drift` is off under
    /// Reduce Motion; `hidden` is the album the hand-off is flying, which is not drawn.
    func frame(at date: Date, drift: Bool, hidden: AlbumCard.ID?) -> GalaxyFrame {
        let t = date.timeIntervalSinceReferenceDate
        advance(to: t)
        var frame = GalaxyFrame()
        frame.items.reserveCapacity(stars.count + leaving.count + (fade?.ghosts.count ?? 0))
        let camera = camera
        let margin: CGFloat = 24
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -margin, dy: -margin)
        func item(_ star: Star, rank: Int?, pose: Pose, opacity: Double) -> GalaxyFrame.Item? {
            let offset = drift ? Drift.offset(seed: star.seed, time: t) : .zero
            let center = screen(
                CGPoint(x: pose.base.x + offset.dx * pose.sway, y: pose.base.y + offset.dy * pose.sway), camera)
            let side = pose.side * camera.zoom
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            guard opacity > 0.001, side > 0.5, rect.intersects(visible) else { return nil }
            return GalaxyFrame.Item(id: star.album.id, rect: rect, opacity: opacity, rank: rank)
        }
        var fadeIn = 1.0
        if let fade {
            fadeIn = min(max((t - fade.start) / Self.fadeDuration, 0), 1)
            for ghost in fade.ghosts {
                frame.items.append(
                    GalaxyFrame.Item(id: ghost.id, rect: ghost.rect, opacity: ghost.opacity * (1 - fadeIn), rank: nil))
            }
        }
        for star in leaving {
            let pose = pose(star, at: t)
            if let made = item(star, rank: nil, pose: pose, opacity: pose.opacity) { frame.items.append(made) }
        }
        let raised = lift?.rank
        // Big last: rank 0 is drawn on top of everything but the sleeve under the finger.
        for rank in stars.indices.reversed() where rank != raised && stars[rank].album.id != hidden {
            let pose = pose(rank, at: t)
            if let made = item(stars[rank], rank: rank, pose: pose, opacity: pose.opacity * fadeIn) {
                frame.items.append(made)
            }
        }
        if let raised, let lift, stars.indices.contains(raised), stars[raised].album.id != hidden {
            let pose = pose(raised, at: t)
            frame.raised = item(stars[raised], rank: raised, pose: pose, opacity: pose.opacity * fadeIn)
            frame.lift = lift.amount(at: t)
        }
        lastFrame = frame
        return frame
    }

    /// Where a star is drawn from (before drift): the physics while a drag runs, else its flight or its home.
    private func pose(_ rank: Int, at t: Double) -> Pose {
        if let session {
            let body = session.physics.bodies[rank]
            return Pose(base: body.center, side: body.side, sway: stars[rank].sway, opacity: 1)
        }
        return pose(stars[rank], at: t)
    }

    private func pose(_ star: Star, at t: Double) -> Pose {
        guard let motion else { return Pose(base: star.home, side: star.side, sway: star.sway, opacity: star.opacity) }
        let p = min(max((t - motion.start - star.delay) / motion.duration, 0), 1)
        let move: Double
        let grow: Double
        switch motion.kind {
        case .flight:
            move = Ease.inOutCubic(p)
            grow = move
        case .entrance:
            move = Ease.outBack(p)
            grow = Ease.outCubic(p)
        }
        let dip = 1 - motion.dip * sin(.pi * p)
        return Pose(
            base: CGPoint(
                x: star.from.x + (star.home.x - star.from.x) * move, y: star.from.y + (star.home.y - star.from.y) * move
            ),
            side: (star.fromSide + (star.side - star.fromSide) * grow) * dip,
            sway: star.fromSway + (star.sway - star.fromSway) * grow,
            opacity: star.fromOpacity + (star.opacity - star.fromOpacity) * min(grow, 1))
    }

    // MARK: Advancing

    private func advance(to t: Double) {
        let dt = lastTime.map { min(max(t - $0, 0), 0.1) } ?? 0
        lastTime = max(lastTime ?? t, t)
        advanceCamera(t, dt: dt)
        if var session {
            let settled = advance(&session, to: t)
            self.session = settled ? nil : session
        }
        if let motion, t >= motion.end {
            self.motion = nil
            for index in stars.indices {
                stars[index].from = stars[index].home
                stars[index].opacity = 1
            }
            if !leaving.isEmpty {
                leaving = []
                later { $0.symbols = $0.albums }
            }
            later { $0.updateLive() }
        }
        if let fade, t >= fade.start + Self.fadeDuration {
            self.fade = nil
            later { $0.updateLive() }
        }
        if let lift, !lift.rising, t >= lift.since + Lift.fall {
            self.lift = nil
            later { $0.updateLive() }
        }
    }

    private func advanceCamera(_ t: Double, dt: Double) {
        if let tween {
            let p = min(max((t - tween.start) / tween.duration, 0), 1)
            let e = Ease.inOutCubic(p)
            camera = Camera(
                center: CGPoint(
                    x: tween.from.center.x + (tween.to.center.x - tween.from.center.x) * e,
                    y: tween.from.center.y + (tween.to.center.y - tween.from.center.y) * e),
                zoom: tween.from.zoom + (tween.to.zoom - tween.from.zoom) * e)
            if p >= 1 {
                self.tween = nil
                later {
                    $0.restRevision += 1
                    $0.updateLive()
                }
            }
        }
        if var glide, dt > 0 {
            camera.center.x += glide.dx * dt
            camera.center.y += glide.dy * dt
            // UIScrollView's normal deceleration: 0.998 a millisecond.
            let decay = pow(0.998, dt * 1000)
            glide.dx *= decay
            glide.dy *= decay
            let range = panRange(camera.zoom)
            let clamped = CGPoint(
                x: min(max(camera.center.x, range.minX), range.maxX),
                y: min(max(camera.center.y, range.minY), range.maxY))
            let stopped = hypot(glide.dx, glide.dy) * camera.zoom < 6 || clamped != camera.center
            camera.center = clamped
            if stopped {
                self.glide = nil
                later {
                    $0.restRevision += 1
                    $0.updateLive()
                }
            } else {
                self.glide = glide
            }
        }
    }

    /// Steps the drag's physics up to `t`. True once the settle is over and the homes are the bodies' centres.
    private func advance(_ session: inout Session, to t: Double) -> Bool {
        let step = 1 / Self.stepsPerSecond
        var steps = Int(((t - session.clock) / step).rounded())
        guard steps > 0 else { return false }
        if steps > 8 {
            steps = 8
            session.clock = t
        } else {
            session.clock += Double(steps) * step
        }
        for _ in 0..<steps {
            for index in session.physics.bodies.indices where !session.physics.bodies[index].held {
                session.physics.bodies[index].velocity.dx *= Self.carry
                session.physics.bodies[index].velocity.dy *= Self.carry
            }
            var target: CGPoint?
            if let held = session.held {
                // The finger says where the sleeve is drawn; the body is that minus its drift.
                let offset = Drift.offset(seed: stars[held].seed, time: t)
                let sway = reduceMotion ? 0 : stars[held].sway
                let side = session.physics.bodies[held].side
                target = confine(
                    CGPoint(x: session.target.x - offset.dx * sway, y: session.target.y - offset.dy * sway), side: side)
            }
            session.physics.step(holdTarget: target)
            confine(&session.physics)
        }
        updateSway(session.physics.bodies)
        guard session.held == nil, let released = session.released,
            session.physics.isSettled || t - released > Self.settleLimit
        else { return false }
        commit(session)
        later {
            $0.restRevision += 1
            $0.updateLive()
        }
        return true
    }

    /// The drag is over: the bodies' centres are the homes now. Nothing drifts back (spec §2).
    private func commit(_ session: Session) {
        for index in stars.indices where session.physics.bodies.indices.contains(index) {
            stars[index].home = session.physics.bodies[index].center
            stars[index].from = stars[index].home
        }
    }

    /// Keeps a point inside the bounds, for a sleeve of `side`.
    private func confine(_ p: CGPoint, side: Double) -> CGPoint {
        let half = side / 2
        guard bounds.width > side, bounds.height > side else { return p }
        return CGPoint(
            x: min(max(p.x, bounds.minX + half), bounds.maxX - half),
            y: min(max(p.y, bounds.minY + half), bounds.maxY - half))
    }

    /// Free bodies stop at the bounds and bounce off at half speed, as in the prototype.
    private func confine(_ physics: inout GalaxyPhysics) {
        for index in physics.bodies.indices where !physics.bodies[index].held {
            let body = physics.bodies[index]
            let kept = confine(body.center, side: body.side)
            if kept.x != body.center.x { physics.bodies[index].velocity.dx = -body.velocity.dx * 0.5 }
            if kept.y != body.center.y { physics.bodies[index].velocity.dy = -body.velocity.dy * 0.5 }
            physics.bodies[index].center = kept
        }
    }

    /// How much drift each sleeve may show. The physics leaves shoved sleeves 6 pt apart, less than two drifts
    /// (2 × 4 pt) need, so a sleeve close to a neighbour drifts less: two sleeves `c` apart on their clear axis may
    /// each drift `(c − 0.5) / 8` of the way, which keeps them apart whichever way both drift. It is recomputed each
    /// frame from the bodies, so it changes as smoothly as they move.
    ///
    /// A sweep along x finds the close pairs. The order is kept from frame to frame and re-sorted by insertion:
    /// bodies move a few points a frame, so it is nearly sorted already and the sort is close to linear.
    private func updateSway(_ bodies: [GalaxyPhysics.Body]) {
        let count = bodies.count
        guard count > 0 else { return }
        let reach = 2 * Self.metrics.driftAmplitude
        if swayOrder.count != count { swayOrder = Array(0..<count) }
        if swayLimit.count != count { swayLimit = [Double](repeating: 1, count: count) }
        bodies.withUnsafeBufferPointer { body in
            var largest = 0.0
            for b in body { largest = max(largest, b.side) }
            swayOrder.withUnsafeMutableBufferPointer { order in
                for k in 1..<count {
                    let moving = order[k]
                    let x = body[moving].center.x
                    var m = k - 1
                    while m >= 0, body[order[m]].center.x > x {
                        order[m + 1] = order[m]
                        m -= 1
                    }
                    order[m + 1] = moving
                }
                swayLimit.withUnsafeMutableBufferPointer { limit in
                    for k in 0..<count { limit[k] = 1 }
                    for position in 0..<count {
                        let i = order[position]
                        let a = body[i]
                        let window = (a.side + largest) / 2 + reach
                        var next = position + 1
                        while next < count {
                            let j = order[next]
                            let b = body[j]
                            let dx = Double(b.center.x - a.center.x)
                            if dx > window { break }
                            let half = (a.side + b.side) / 2
                            let clearance = max(abs(dx) - half, abs(Double(b.center.y - a.center.y)) - half)
                            if clearance < reach + 0.5 {
                                let allowed = max(0, (clearance - 0.5) / reach)
                                limit[i] = min(limit[i], allowed)
                                limit[j] = min(limit[j], allowed)
                            }
                            next += 1
                        }
                    }
                }
            }
        }
        for index in stars.indices where index < count { stars[index].sway = swayLimit[index] }
    }

    // MARK: Touch

    /// A touch moved (or landed). Returns the album pressed, on the touch's first event, so its art can be decoded
    /// before a tap asks for it.
    @discardableResult
    func touchChanged(location: CGPoint, start: CGPoint, time: Date) -> AlbumCard? {
        let t = time.timeIntervalSinceReferenceDate
        switch touch {
        case .idle:
            // A touch catches the camera where it is: a coast, a spring back or a re-sort's refit stops under the
            // finger.
            glide = nil
            tween = nil
            if let rank = hit(start) {
                touch = .pressing(rank: rank, start: start, time: t)
                lift = Lift(rank: rank, since: t, rising: true)
                pressToken += 1
                updateLive()
                return stars[rank].album
            }
            touch = .panning(origin: camera.center, start: start)
            cameraTouched = true
            updateLive()
            panTo(location, from: start, origin: camera.center)
        case .pressing(let rank, let begin, _):
            guard hypot(location.x - begin.x, location.y - begin.y) >= Self.slop else { return nil }
            pressToken = 0
            if motion == nil, fade == nil, stars.indices.contains(rank) {
                beginDrag(rank, at: begin, time: t)
                dragTo(location)
            } else {
                // Mid-flight, collisions are off (spec §2): the touch looks around instead.
                lift = lift.map { Lift(rank: $0.rank, since: t, rising: false) }
                touch = .panning(origin: camera.center, start: location)
                cameraTouched = true
            }
        case .dragging:
            dragTo(location)
        case .panning(let origin, let begin):
            panTo(location, from: begin, origin: origin)
        case .spent:
            break
        }
        return nil
    }

    /// The touch lifted. A tap returns its album and the sleeve's frame in the player's space.
    func touchEnded(location: CGPoint, velocity: CGSize, time: Date) -> (album: AlbumCard, rect: CGRect)? {
        let t = time.timeIntervalSinceReferenceDate
        defer {
            touch = .idle
            pressToken = 0
            updateLive()
        }
        switch touch {
        case .pressing(let rank, let begin, let at):
            lift = Lift(rank: rank, since: t, rising: false)
            let still = hypot(location.x - begin.x, location.y - begin.y) < Self.slop
            guard still, t - at < Self.holdDelay, stars.indices.contains(rank) else { return nil }
            return (stars[rank].album, playerRect(drawnRect(rank)))
        case .dragging(let rank, _):
            release(rank, velocity: velocity, time: t)
        case .panning:
            endPan(velocity: velocity)
        case .idle, .spent:
            break
        }
        return nil
    }

    /// The touch ended or was cancelled (a dialog took over): anything it left half done is finished.
    func touchFinished(time: Date) {
        let t = time.timeIntervalSinceReferenceDate
        switch touch {
        case .pressing(let rank, _, _):
            lift = Lift(rank: rank, since: t, rising: false)
        case .dragging(let rank, _):
            release(rank, velocity: .zero, time: t)
        case .panning:
            endPan(velocity: .zero)
        case .idle, .spent:
            break
        }
        if case .idle = touch { return }
        touch = .idle
        pressToken = 0
        updateLive()
    }

    /// The press timer fired for `token`: a hold, if that touch is still down and has not moved. Returns the album
    /// and its sleeve's frame in the area and in the player's space.
    func hold(token: Int, time: Date) -> (album: AlbumCard, local: CGRect, rect: CGRect)? {
        guard token == pressToken, case .pressing(let rank, _, _) = touch, stars.indices.contains(rank) else {
            return nil
        }
        touch = .spent
        lift = Lift(rank: rank, since: time.timeIntervalSinceReferenceDate, rising: false)
        let rect = drawnRect(rank)
        return (stars[rank].album, rect, playerRect(rect))
    }

    /// The sleeve at `rank` as the last frame drew it, lift included (the hand-off's copy starts exactly there), or
    /// its resting frame if it was not drawn.
    private func drawnRect(_ rank: Int) -> CGRect {
        if let raised = lastFrame.raised, raised.rank == rank {
            let grow = raised.rect.width * GalaxyFrame.liftGrowth * lastFrame.lift
            return raised.rect.insetBy(dx: -grow, dy: -grow)
        }
        return lastFrame.items.first { $0.rank == rank }?.rect ?? restingRect(rank: rank)
    }

    /// The topmost sleeve at `point` (the lifted one, then big to small), else the nearest whose target, grown to
    /// 44 pt, holds the point.
    private func hit(_ point: CGPoint) -> Int? {
        if let raised = lastFrame.raised, let rank = raised.rank, raised.rect.contains(point) { return rank }
        for item in lastFrame.items.reversed() where item.rank != nil && item.opacity > 0.3 {
            if item.rect.contains(point) { return item.rank }
        }
        var best: Int?
        var nearest = CGFloat.infinity
        for item in lastFrame.items where item.opacity > 0.3 {
            guard let rank = item.rank, item.rect.width < Self.minimumTarget else { continue }
            let grow = (Self.minimumTarget - item.rect.width) / 2
            guard item.rect.insetBy(dx: -grow, dy: -grow).contains(point) else { continue }
            let distance = hypot(point.x - item.rect.midX, point.y - item.rect.midY)
            if distance < nearest {
                nearest = distance
                best = rank
            }
        }
        return best
    }

    private func beginDrag(_ rank: Int, at start: CGPoint, time t: Double) {
        // The bodies start at the homes; the drawn sleeve (home plus drift) stays under the finger by an offset.
        var bodies = stars.map { GalaxyPhysics.Body(center: $0.home, side: $0.side) }
        bodies[rank].held = true
        let drawn = drawnRect(rank)
        let centre = world(CGPoint(x: drawn.midX, y: drawn.midY), camera)
        let finger = world(start, camera)
        let grab = CGVector(dx: centre.x - finger.x, dy: centre.y - finger.y)
        session = Session(
            physics: GalaxyPhysics(bodies: bodies, metrics: Self.metrics), held: rank, target: centre, clock: t)
        touch = .dragging(rank: rank, grab: grab)
        pickUps += 1
        updateLive()
    }

    private func dragTo(_ location: CGPoint) {
        guard case .dragging(_, let grab) = touch, var session else { return }
        let finger = world(location, camera)
        session.target = CGPoint(x: finger.x + grab.dx, y: finger.y + grab.dy)
        self.session = session
    }

    /// Lets go: the sleeve keeps the finger's speed (a flick throws it) and the settle runs.
    private func release(_ rank: Int, velocity: CGSize, time t: Double) {
        lift = Lift(rank: rank, since: t, rising: false)
        guard var session, session.physics.bodies.indices.contains(rank) else { return }
        session.physics.bodies[rank].held = false
        var throwX = Double(velocity.width) / camera.zoom
        var throwY = Double(velocity.height) / camera.zoom
        let speed = hypot(throwX, throwY)
        if speed > Self.maxThrow {
            throwX *= Self.maxThrow / speed
            throwY *= Self.maxThrow / speed
        }
        session.physics.bodies[rank].velocity = CGVector(
            dx: throwX / Self.stepsPerSecond, dy: throwY / Self.stepsPerSecond)
        session.held = nil
        session.released = t
        self.session = session
    }

    // MARK: Camera

    /// Where the camera's centre may go at `zoom`: the bounds stay on screen, or the screen stays in the bounds.
    private func panRange(_ zoom: Double) -> CGRect {
        let halfWidth = size.width / 2 / zoom
        let halfHeight = (size.height - topInset) / 2 / zoom
        let a = bounds.minX + halfWidth
        let b = bounds.maxX - halfWidth
        let c = bounds.minY + halfHeight
        let d = bounds.maxY - halfHeight
        return CGRect(x: min(a, b), y: min(c, d), width: abs(b - a), height: abs(d - c))
    }

    private func panTo(_ location: CGPoint, from start: CGPoint, origin: CGPoint) {
        let zoom = camera.zoom
        let wanted = CGPoint(x: origin.x - (location.x - start.x) / zoom, y: origin.y - (location.y - start.y) / zoom)
        let range = panRange(zoom)
        camera.center = CGPoint(
            x: Self.rubberBand(wanted.x, range.minX, range.maxX, size.width / zoom),
            y: Self.rubberBand(wanted.y, range.minY, range.maxY, size.height / zoom))
    }

    private func endPan(velocity: CGSize) {
        let range = panRange(camera.zoom)
        let clamped = CGPoint(
            x: min(max(camera.center.x, range.minX), range.maxX), y: min(max(camera.center.y, range.minY), range.maxY))
        if clamped != camera.center {
            tween = CameraTween(
                from: camera, to: Camera(center: clamped, zoom: camera.zoom),
                start: Date().timeIntervalSinceReferenceDate,
                duration: 0.45)
        } else if !reduceMotion, hypot(velocity.width, velocity.height) > 60 {
            glide = CGVector(dx: -velocity.width / camera.zoom, dy: -velocity.height / camera.zoom)
        } else {
            restRevision += 1
        }
    }

    /// UIScrollView's rubber band: past the edge, the content follows the finger less and less.
    private static func rubberBand(_ value: Double, _ low: Double, _ high: Double, _ dimension: Double) -> Double {
        func band(_ x: Double) -> Double { (1 - 1 / (x * 0.55 / max(dimension, 1) + 1)) * dimension }
        if value < low { return low - band(low - value) }
        if value > high { return high + band(value - high) }
        return value
    }

    /// A pinch: zooms 0.5…2.0 about where it started. It takes over the touch: a held sleeve is let go.
    func zoomChanged(magnification: CGFloat, anchor: CGPoint, time: Date) {
        if pinch == nil {
            let t = time.timeIntervalSinceReferenceDate
            switch touch {
            case .dragging(let rank, _): release(rank, velocity: .zero, time: t)
            case .pressing(let rank, _, _): lift = Lift(rank: rank, since: t, rising: false)
            default: break
            }
            if case .idle = touch {} else { touch = .spent }
            pressToken = 0
            glide = nil
            if let tween { camera = tween.to }
            tween = nil
            cameraTouched = true
            pinch = Pinch(zoom: camera.zoom, anchor: world(anchor, camera), screen: anchor)
            updateLive()
        }
        guard let pinch else { return }
        let zoom = min(max(pinch.zoom * Double(magnification), Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        camera.zoom = zoom
        let focus = CGPoint(x: size.width / 2, y: topInset + (size.height - topInset) / 2)
        camera.center = CGPoint(
            x: pinch.anchor.x - (pinch.screen.x - focus.x) / zoom, y: pinch.anchor.y - (pinch.screen.y - focus.y) / zoom
        )
    }

    func zoomEnded() {
        pinch = nil
        endPan(velocity: .zero)
        updateLive()
    }

    // MARK: Liveness

    /// Recomputes `isLive` from what is running.
    private func updateLive() {
        var touching = true
        if case .idle = touch { touching = false }
        let live =
            touching || pinch != nil || motion != nil || fade != nil || session != nil || tween != nil
            || glide != nil || lift != nil
        if live != isLive { isLive = live }
    }

    /// Runs `work` after the current view update: frames are built inside one, where observed state must not change.
    private func later(_ work: @escaping @MainActor (GalaxyModel) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            work(self)
        }
    }
}

// MARK: - Pieces

/// One album in the galaxy: where it rests, and the motion carrying it there.
private struct Star {
    var album: AlbumCard
    let seed: UInt64
    /// Where it rests, in world points, and its side there.
    var home: CGPoint
    var side: Double
    /// How much of the idle drift it shows: 1 in a fresh layout, less where a drag left it close to a neighbour.
    var sway = 1.0
    var opacity = 1.0
    /// Where the current motion started from, and how long after the motion's start this star sets off.
    var from: CGPoint
    var fromSide: Double
    var fromSway = 1.0
    var fromOpacity = 1.0
    var delay = 0.0

    init(album: AlbumCard, seed: UInt64, home: CGPoint, side: Double) {
        self.album = album
        self.seed = seed
        self.home = home
        self.side = side
        from = home
        fromSide = side
    }
}

/// Where a star is drawn from at some instant, before its drift.
private struct Pose {
    var base: CGPoint
    var side: Double
    var sway: Double
    var opacity: Double
}

/// A layout change in progress: the galaxy forming, or a re-sort's flight.
private struct Motion {
    enum Kind { case entrance, flight }
    let kind: Kind
    let start: Double
    let duration: Double
    let dip: Double
    /// When the last (most delayed) star lands.
    let end: Double

    init(kind: Kind, start: Double, duration: Double, dip: Double, delay: Double) {
        self.kind = kind
        self.start = start
        self.duration = duration
        self.dip = dip
        end = start + delay + duration
    }
}

/// Reduce Motion's cross-fade: the old sleeves, where they were, fading out as the new layout fades in.
private struct Fade {
    let start: Double
    let ghosts: [GalaxyFrame.Item]
}

/// A drag and its settle.
private struct Session {
    var physics: GalaxyPhysics
    var held: Int?
    /// Where the finger wants the held sleeve drawn, in world points.
    var target: CGPoint
    /// The physics' own clock: the time its last step stood for.
    var clock: Double
    var released: Double?

    init(physics: GalaxyPhysics, held: Int? = nil, target: CGPoint, clock: Double) {
        self.physics = physics
        self.held = held
        self.target = target
        self.clock = clock
    }
}

private struct Camera: Equatable {
    /// The world point at the middle of the area.
    var center = CGPoint.zero
    var zoom = 1.0
}

private struct CameraTween {
    let from: Camera
    let to: Camera
    let start: Double
    let duration: Double
}

private struct Pinch {
    let zoom: Double
    /// The world point under the pinch when it began, and where on screen it began.
    let anchor: CGPoint
    let screen: CGPoint
}

/// The sleeve under the finger rising (scale 1.06, a deeper shadow) or settling back down.
private struct Lift {
    let rank: Int
    let since: Double
    let rising: Bool

    static let rise = 0.14
    static let fall = 0.22

    func amount(at t: Double) -> Double {
        let p = min(max((t - since) / (rising ? Self.rise : Self.fall), 0), 1)
        return rising ? Ease.outCubic(p) : 1 - Ease.outCubic(p)
    }
}

private enum Touch {
    case idle
    /// On a sleeve, not yet moved past the slop: a tap, a hold or the start of a drag.
    case pressing(rank: Int, start: CGPoint, time: Double)
    /// Dragging a sleeve, held `grab` from its centre (world points).
    case dragging(rank: Int, grab: CGVector)
    /// Looking around: the camera's centre when the pan began, and the touch it began from.
    case panning(origin: CGPoint, start: CGPoint)
    /// A hold fired or a pinch took over: the rest of this touch does nothing.
    case spent
}

private enum Ease {
    static func inOutCubic(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
    static func outCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    /// Out with a little overshoot: the forming galaxy swells a few per cent past its rest and settles back.
    static func outBack(_ p: Double) -> Double {
        let c1 = 0.9
        let c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }
}
