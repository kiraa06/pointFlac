import PFAudio
import SwiftUI

/// The hold-to-compare button pinned at the foot of the Sound tab (Task 14): touch and hold to hear the original,
/// brought to the processed sound's loudness and lined up with it; let go for the processed sound. Each switch is a
/// 20 ms crossfade on the render thread, so neither a level jump nor a click gives the answer away.
///
/// Held, it says so in the processing tint ("Original · level-matched") with the gain the original gets, and a haptic
/// marks the press and the release. Every way a press can end releases it (`CompareHold`): the finger lifting, the
/// system cancelling the touch (a `@GestureState` reset, which `onEnded` never reports), the app leaving the
/// foreground, the tab going away. VoiceOver users, who can't hold, switch it with a double-tap.
///
/// The Sound tab shows it only while a chain runs (Pure off, a block on); it is disabled until a track plays.
struct CompareBar: View {
    let store: SoundStore
    let meters: MeterBallistics
    let player: Player
    let theme: Theme
    /// Whether the meters are being read: the match's gain is read with them.
    let polling: Bool
    @GestureState private var pressing = false
    @Environment(\.scenePhase) private var scenePhase

    private static let hint =
        "Touch and hold to hear the original at the processed loudness. With VoiceOver, double-tap to switch."

    private var held: Bool { store.compare.isHeld }
    private var available: Bool { store.canCompare }

    var body: some View {
        HStack(spacing: 12) {
            ABLamp(held: held, theme: theme)
            VStack(alignment: .leading, spacing: 3) {
                Text(held ? "Original · level-matched" : "Hold to compare")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(held ? theme.processingTint : theme.ink)
                    .contentTransition(.opacity)
                detail
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Image(systemName: held ? "hand.point.up.left.fill" : "hand.point.up.left")
                .font(.title3)
                .foregroundStyle(held ? theme.processingTint : theme.inkSecondary)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
        // Only the contents dim while nothing plays: the glass stays whole, so the list never shows through.
        .opacity(available || held ? 1 : 0.5)
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background {
            // Backed, under the glass, so the list scrolling behind never reads through the words.
            ZStack {
                Capsule().fill(theme.background.opacity(0.72))
                Capsule().fill(theme.processingTint.opacity(held ? (theme.isDark ? 0.22 : 0.14) : 0))
            }
        }
        .overlay {
            Capsule().strokeBorder(held ? theme.processingTint.opacity(0.7) : theme.hairline, lineWidth: 1)
        }
        .glassEffect(.regular, in: .capsule)
        .scaleEffect(held ? 0.985 : 1)
        .animation(.snappy(duration: 0.18), value: held)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressing) { _, active, _ in active = true }
                .onChanged { _ in store.compareTouched() }
                .onEnded { _ in store.compareLifted() }
        )
        // The flag resets on a cancel as well as on an end; after an end the release is done and repeats harmlessly.
        .onChange(of: pressing) { _, active in
            if !active { store.compareLifted() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.interruptCompare() }
        }
        .onChange(of: available) { _, now in
            if !now { store.interruptCompare() }
        }
        .onDisappear { store.interruptCompare() }
        .sensoryFeedback(trigger: held) { _, now in
            now ? .impact(weight: .medium, intensity: 0.9) : .impact(weight: .light, intensity: 0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Compare with the original")
        .accessibilityValue(held ? "Original, level-matched" : "Processed")
        .accessibilityHint(available ? Self.hint : "Play a track to compare.")
        .accessibilityAction { store.toggleCompare() }
        .accessibilityIdentifier("compareButton")
    }

    /// What the press does, or, held, the gain the original gets to match; why it can't, while nothing plays.
    @ViewBuilder
    private var detail: some View {
        if held {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let _ = polling ? meters.poll(player, at: context.date) : ()
                Text("\(SoundFormat.gain(meters.matchGainDb)) to match · let go for processed")
            }
        } else if available {
            Text("Hear the original at the processed loudness")
        } else {
            Text("Play a track to compare")
        }
    }
}

/// The A/B lamp: two cells, A for the processed sound and B for the original, the one playing lit.
private struct ABLamp: View {
    let held: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 2) {
            cell("A", lit: !held)
            cell("B", lit: held)
        }
        .padding(3)
        .background(Capsule().fill(theme.ink.opacity(theme.isDark ? 0.10 : 0.06)))
        .accessibilityHidden(true)
    }

    private func cell(_ letter: String, lit: Bool) -> some View {
        Text(letter)
            .font(.caption.monospaced().weight(.bold))
            .frame(width: 24, height: 24)
            .foregroundStyle(lit ? theme.background : theme.inkSecondary)
            .background(Circle().fill(lit ? theme.processingTint : Color.clear))
    }
}
