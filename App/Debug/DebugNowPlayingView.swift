import PFAudio
import PFCore
import SwiftUI

/// Plan 1's stand-in for Now Playing: the current track, the honest signal strip, a seek slider and the transport.
struct DebugNowPlayingView: View {
    let player: Player
    /// The slider's value while the user drags it. The seek goes out on release, not on every step of the drag.
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Text(current?.title ?? "Nothing playing").font(.headline)
                Text(current?.artist ?? "").font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Text(SignalStrip.text(player.signal))
                .font(.footnote.monospaced())
                .accessibilityIdentifier("signalStrip")
            Slider(
                value: Binding(get: { scrubbing ?? player.position.seconds }, set: { scrubbing = $0 }),
                in: 0...max(length, 0.001),
                onEditingChanged: { editing in
                    guard !editing, let target = scrubbing else { return }
                    Task {
                        await player.seek(to: .seconds(target))
                        scrubbing = nil
                    }
                }
            )
            .disabled(current == nil)
            HStack {
                Text(Self.clock(scrubbing ?? player.position.seconds))
                Spacer()
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Text(Self.clock(length))
            }
            .font(.caption.monospacedDigit())
            HStack(spacing: 40) {
                Button("Previous", systemImage: "backward.fill") { Task { await player.previous() } }
                Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                    player.togglePlayPause()
                }
                .accessibilityIdentifier("playPauseButton")
                Button("Next", systemImage: "forward.fill") { Task { await player.next() } }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .disabled(current == nil)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var current: QueueItem? {
        guard let index = player.currentIndex, player.queue.indices.contains(index) else { return nil }
        return player.queue[index]
    }

    private var length: Double {
        current?.duration.seconds ?? 0
    }

    private var isPlaying: Bool {
        player.status == .playing || player.status == .preparing
    }

    private var status: String {
        switch player.status {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .playing: "Playing"
        case .paused: "Paused"
        case .ended: "Ended"
        case .failed(let message): "Failed: \(message)"
        }
    }

    /// m:ss, from whole seconds.
    private static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

extension Duration {
    fileprivate var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
