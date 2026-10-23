import PFDesign
import SwiftUI

/// The deck's layers, in the one order the player and the Customize deck previews both draw them. At the back is the
/// still furniture (plinth, controls, platter, the arm's base). Over it go what moves (`moving`), then the lamps and
/// the front panel (`front`: the start/stop key and the display). The radiogram's lid lies over everything. The still
/// layers are rasterised once per design and size.
struct DeckLayers<Moving: View, Front: View>: View {
    let paint: DeckPaint
    let layout: DeckLayout
    /// Live glass in the player; a flattened frosting in a preview.
    let live: Bool
    let playing: Bool
    let moving: Moving
    let front: Front

    init(
        paint: DeckPaint, layout: DeckLayout, live: Bool, playing: Bool, @ViewBuilder moving: () -> Moving,
        @ViewBuilder front: () -> Front
    ) {
        self.paint = paint
        self.layout = layout
        self.live = live
        self.playing = playing
        self.moving = moving()
        self.front = front()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DeckPlinth(paint: paint, layout: layout, live: live).equatable()
            DeckControls(paint: paint, layout: layout).equatable()
            DeckPlatter(paint: paint, layout: layout).equatable()
            ArmFurniture(paint: paint, layout: layout).equatable()
            moving
            DeckLamps(paint: paint, layout: layout, playing: playing).equatable()
            front
            if paint.design.plinth == .lacquer {
                LidReflection(paint: paint, layout: layout).equatable()
            }
        }
    }
}

/// What moves on the deck, drawn from plain values: the creeping 45 rpm strobe rows, the record (`record`, already
/// placed), the spindle over it, and the arm with its shadow. Per frame, only transforms and opacities change.
struct DeckMovingParts<Record: View>: View {
    let paint: DeckPaint
    let layout: DeckLayout
    let strobePhase: Double
    let armPosition: Double
    let lift: Double
    var armOpacity: Double = 1
    let record: Record

    init(
        paint: DeckPaint, layout: DeckLayout, strobePhase: Double, armPosition: Double, lift: Double,
        armOpacity: Double = 1, @ViewBuilder record: () -> Record
    ) {
        self.paint = paint
        self.layout = layout
        self.strobePhase = strobePhase
        self.armPosition = armPosition
        self.lift = lift
        self.armOpacity = armOpacity
        self.record = record()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            StrobeCreep(paint: paint, layout: layout, phase: strobePhase)
                .position(layout.recordCenter)
            record
            DeckSpindle(paint: paint, layout: layout).equatable()
            TonearmAssembly(paint: paint, layout: layout, position: armPosition, lift: lift)
                .opacity(armOpacity)
        }
    }
}

/// The arm at `position` along its travel, with its shadow. A pivoted arm brings its cue lever (riding with `lift`)
/// and the pivot's cap. A linear arm brings its rail and carriage. The arm and its two shadows (tight while the
/// stylus is down, soft as it lifts, crossfaded) are rasterised once and only turned or slid. Takes no touches: the
/// deck lays its own hit areas over it.
struct TonearmAssembly: View {
    let paint: DeckPaint
    let layout: DeckLayout
    let position: Double
    let lift: Double

    var body: some View {
        if let arm = layout.pivoted {
            pivoted(arm)
        } else if let arm = layout.linear {
            linear(arm)
        }
    }

    private func pivoted(_ arm: PivotedArm) -> some View {
        let m = ArmMetrics(arm: arm)
        let anchor = UnitPoint(x: 0.5, y: m.top / m.height)
        let center = CGPoint(x: arm.pivot.x, y: arm.pivot.y - m.top + m.height / 2)
        let shadowOffset = CGSize(width: 2 + lift * 7, height: 3 + lift * 9)
        return ZStack(alignment: .topLeading) {
            CueLever(paint: paint, arm: arm, lift: lift)
            ArmBody(paint: paint, arm: arm, silhouette: true, blur: 1.2).equatable()
                .opacity(0.5 * (1 - lift))
                .rotationEffect(.degrees(position), anchor: anchor)
                .offset(shadowOffset)
                .position(center)
            ArmBody(paint: paint, arm: arm, silhouette: true, blur: 4.5).equatable()
                .opacity(0.34 * lift)
                .rotationEffect(.degrees(position), anchor: anchor)
                .offset(shadowOffset)
                .position(center)
            ArmBody(paint: paint, arm: arm, silhouette: false).equatable()
                // Lifted, the arm comes a touch nearer.
                .scaleEffect(1 + lift * 0.012, anchor: anchor)
                .rotationEffect(.degrees(position), anchor: anchor)
                .position(center)
            ArmCap(paint: paint, arm: arm).equatable()
        }
        .allowsHitTesting(false)
    }

    private func linear(_ arm: LinearArm) -> some View {
        let stylus = layout.needle(at: position)
        let shadow = CGPoint(x: stylus.x + 2 + lift * 6, y: stylus.y + 3 + lift * 8)
        return ZStack(alignment: .topLeading) {
            LinearRailView(paint: paint, layout: layout).equatable()
            CarriageBody(paint: paint, arm: arm, silhouette: true, blur: 1.2).equatable()
                .opacity(0.5 * (1 - lift))
                .position(shadow)
            CarriageBody(paint: paint, arm: arm, silhouette: true, blur: 4.5).equatable()
                .opacity(0.34 * lift)
                .position(shadow)
            CarriageBody(paint: paint, arm: arm, silhouette: false).equatable()
                .scaleEffect(1 + lift * 0.02)
                .position(stylus)
        }
        .allowsHitTesting(false)
    }
}
