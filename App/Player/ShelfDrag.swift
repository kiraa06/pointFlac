import PFDesign
import SwiftUI

/// A finger moving the Shelf: up from the player, or by its grabber. The player moves the panel by it (`ShelfTravel`)
/// and settles it open or closed only when the finger lifts.
struct ShelfDrag: Equatable {
    /// The panel was open when the finger took it.
    let startsOpen: Bool
    /// The finger's vertical travel since the drag engaged, in points, positive down.
    var translation: CGFloat
}

/// What a shelf drag area tells the player: the finger moved, the finger lifted.
struct ShelfDragActions {
    /// Whether a drag that starts this way, in points (positive down), takes the shelf. Asked once, as it engages.
    var accepts: @MainActor (CGSize) -> Bool = { _ in false }
    /// The finger's vertical travel since the drag engaged, in points, positive down.
    var changed: @MainActor (CGFloat) -> Void = { _ in }
    /// The finger lifted, moving at this vertical speed in points per second (positive down); or the system cancelled
    /// the touch, reported at rest.
    var ended: @MainActor (CGFloat) -> Void = { _ in }
}

extension EnvironmentValues {
    /// The grabber's drag, set by the player round the Shelf. Without one (a Shelf on its own), the grabber does not
    /// drag; its close action still works.
    @Entry var shelfGrabberDrag: ShelfDragActions = ShelfDragActions()
}

/// A drag area for the Shelf. It engages only when the first movement is mostly vertical (and the actions accept its
/// direction), so a horizontal drag passing through is left alone; once engaged, every move reaches the actions,
/// measured from where it engaged, so the panel does not jump by the gesture's slop. Measured in the global space: the
/// grabber moves with the panel, and in its own space the finger would hardly move at all.
///
/// Every way the drag can stop ends it: the finger lifting (`onEnded`) or the system cancelling the touch, which
/// `onEnded` never reports but a `@GestureState` reset does (reported at rest; after a lift it repeats harmlessly).
struct ShelfDragArea: ViewModifier {
    let minimumDistance: CGFloat
    let actions: ShelfDragActions
    @GestureState private var touching = false
    @State private var phase = Phase.waiting

    private enum Phase: Equatable {
        case waiting
        /// Engaged at this vertical travel.
        case following(CGFloat)
        /// Not the shelf's: ignored until the finger lifts.
        case ignoring
    }

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { changed($0) }
                    .onEnded { end(velocity: $0.velocity.height) }
            )
            .onChange(of: touching) { _, touching in
                if !touching { end(velocity: 0) }
            }
    }

    private func changed(_ value: DragGesture.Value) {
        switch phase {
        case .ignoring:
            return
        case .waiting:
            let move = value.translation
            guard abs(move.height) > abs(move.width), actions.accepts(move) else {
                phase = .ignoring
                return
            }
            phase = .following(move.height)
            actions.changed(0)
        case .following(let origin):
            actions.changed(value.translation.height - origin)
        }
    }

    private func end(velocity: CGFloat) {
        if case .following = phase { actions.ended(velocity) }
        phase = .waiting
    }
}

/// The Shelf's grabber: drags the panel by the player's `shelfGrabberDrag`, either way (up, it stretches).
struct ShelfGrabberDrag: ViewModifier {
    @Environment(\.shelfGrabberDrag) private var actions

    func body(content: Content) -> some View {
        content.modifier(ShelfDragArea(minimumDistance: 10, actions: actions))
    }
}

/// Where the Shelf sits in the player: how tall it is, how far down it travels to be out of sight, and how far past
/// open it may stretch.
struct ShelfMetrics: Equatable {
    /// The panel's share of the player's height.
    static let share: CGFloat = 0.74

    let height: CGFloat
    /// From open to closed: the panel's height and the bottom inset (the tab bar), which its surface reaches into.
    let travel: CGFloat
    /// Stretched past open, the panel's surface in the bottom inset fills in under it: no further than that.
    let stretchLimit: CGFloat

    init(_ proxy: GeometryProxy) {
        height = proxy.size.height * Self.share
        let inset = proxy.safeAreaInsets.bottom
        travel = height + inset
        stretchLimit = min(ShelfTravel.stretchLimit, inset)
    }

    /// The panel's offset down from open under `drag`.
    func offset(_ drag: ShelfDrag) -> CGFloat {
        ShelfTravel.offset(
            start: drag.startsOpen ? 0 : travel, translation: drag.translation, travel: travel,
            stretchLimit: stretchLimit)
    }
}
