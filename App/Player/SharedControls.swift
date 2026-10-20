import PFAudio
import PFCore
import PFDesign
import SwiftUI

/// What both views share under the stage (spec §4.2): the title and artist, the side and track line, the signal
/// strip, the progress bar with elapsed and remaining time, and the transport, with Up Next and repeat.
struct SharedControls: View {
    let playback: PlaybackController
    let theme: Theme
    @Binding var upNextOpen: Bool
    let hidden: Bool

    private var player: Player { playback.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBlock
                .opacity(hidden ? 0 : 1)
            SignalCells(signal: player.signal, theme: theme)
            ProgressRow(playback: playback, theme: theme)
            transport
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .foregroundStyle(theme.ink)
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if playback.album == nil {
                Text("pointFlac")
                    .font(Typeface.display(30))
                    .tracking(-0.6)
                Text("Swipe up for the shelf, or get music to fill it.")
                    .font(Typeface.artist)
                    .foregroundStyle(theme.inkSecondary)
            } else {
                Text(title)
                    .font(Typeface.display(30))
                    .tracking(-0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("nowPlayingTitle")
                Text(subtitle)
                    .font(Typeface.artist)
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("nowPlayingSubtitle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.3), value: title)
    }

    private var title: String {
        playback.currentTrack?.title ?? playback.album?.title ?? ""
    }

    private var subtitle: String {
        guard let album = playback.album else { return "" }
        let sides = playback.layout.sides
        let side = sides.indices.contains(playback.currentSide) ? sides[playback.currentSide] : nil
        if let index = playback.trackIndex, let side {
            let artist = playback.tracks[index].artist
            return "\(artist) · Side \(side.letter) · Track \(index - side.tracks.lowerBound + 1)"
        }
        return "\(album.artist) · Side \(side?.letter ?? "A") · Needle up"
    }

    // MARK: Transport

    private var transport: some View {
        HStack {
            Button {
                playback.repeatMode = playback.repeatMode.next
            } label: {
                Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(playback.repeatMode == .off ? theme.inkSecondary : theme.ok)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(repeatLabel)
            .accessibilityIdentifier("repeatButton")
            Spacer()
            Button {
                Task { await playback.previous() }
            } label: {
                Image(systemName: "backward.fill").frame(width: 52, height: 52)
            }
            .accessibilityLabel("Previous")
            .accessibilityIdentifier("previousButton")
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(theme.playGlyph)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(theme.playFill))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("playButton")
            .padding(.horizontal, 18)
            Button {
                Task { await playback.next() }
            } label: {
                Image(systemName: "forward.fill").frame(width: 52, height: 52)
            }
            .accessibilityLabel("Next")
            .accessibilityIdentifier("nextButton")
            Spacer()
            Button {
                upNextOpen = true
            } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(playback.upNext.isEmpty ? theme.inkSecondary : theme.ink)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if !playback.upNext.isEmpty {
                            Text("\(playback.upNext.count)").font(.caption2.bold()).padding(3)
                                .background(Circle().fill(theme.ok)).foregroundStyle(.black)
                        }
                    }
            }
            .accessibilityLabel("Up Next")
            .accessibilityIdentifier("upNextButton")
        }
        .font(.title3)
        .buttonStyle(.plain)
        .disabled(playback.album == nil)
    }

    private var repeatLabel: String {
        switch playback.repeatMode {
        case .off: "Off"
        case .album: "Album"
        case .one: "One track"
        }
    }
}

/// The progress bar with elapsed and remaining time. Its own view because it reads the position, which changes ten
/// times a second: only this row redraws then, not the whole block. Drag it to seek (on release).
struct ProgressRow: View {
    let playback: PlaybackController
    let theme: Theme
    @State private var scrubbing: Double?

    private var player: Player { playback.player }

    var body: some View { progress }

    private var length: Double { playback.currentTrack?.durationSeconds ?? 0 }

    private var elapsed: Double { scrubbing ?? player.position.seconds }

    private var progress: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let fraction = length > 0 ? min(max(elapsed / length, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.hairline)
                    Capsule().fill(theme.ink).frame(width: proxy.size.width * fraction)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard length > 0 else { return }
                            scrubbing = min(max(value.location.x / proxy.size.width, 0), 1) * length
                        }
                        .onEnded { _ in
                            guard let target = scrubbing else { return }
                            Task {
                                await player.seek(to: .seconds(target))
                                scrubbing = nil
                            }
                        })
            }
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue("\(ClockFormat.clock(elapsed)) of \(ClockFormat.clock(length))")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 10.0 : -10.0
                Task { await player.seek(to: .seconds(max(0, min(length, elapsed + step)))) }
            }
            .accessibilityIdentifier("progressBar")
            HStack {
                Text(ClockFormat.clock(elapsed)).accessibilityIdentifier("elapsedTime")
                Spacer()
                Text(ClockFormat.remaining(max(0, length - elapsed))).accessibilityIdentifier("remainingTime")
            }
            .font(Typeface.mono.monospacedDigit())
            .foregroundStyle(theme.inkSecondary)
        }
    }
}

/// The signal strip as the mockups draw it: FORMAT · DEPTH · DAC · SIGNAL cells, from `SignalStrip.text`, so the
/// words are exactly the strip's and its honesty rules hold. The whole strip is one accessibility element whose
/// label is the strip text, with the id the UI tests read.
struct SignalCells: View {
    let signal: SignalState
    let theme: Theme
    @State private var details = false

    var body: some View {
        let text = SignalStrip.text(signal)
        cells(text)
            .contentShape(Rectangle())
            .onTapGesture { details = true }
            .sheet(isPresented: $details) {
                SignalDetailsSheet(signal: signal).presentationDetents([.medium, .large])
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityHint("Opens the signal details")
            .accessibilityAction { details = true }
            .accessibilityIdentifier("signalStrip")
    }

    @ViewBuilder
    private func cells(_ text: String) -> some View {
        let parts = text.components(separatedBy: " · ")
        if parts.count >= 4, parts[0] == "FLAC" {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    cell("FORMAT", parts[0])
                    cell("DEPTH", parts[1])
                    cell("DAC", parts[2])
                    cell("SIGNAL", parts[3], tint: tint(parts[3]), fixed: true)
                }
                if parts.count > 4 {
                    Text(parts[4...].joined(separator: " · "))
                        .font(Typeface.cellLabel)
                        .foregroundStyle(theme.warn)
                }
            }
        } else {
            HStack {
                cell("SIGNAL", text)
            }
        }
    }

    /// One cell. The signal cell keeps its full width (`fixed`): its words are the claim, so they never truncate;
    /// the other three shrink to fit beside it.
    private func cell(_ label: String, _ value: String, tint: Color? = nil, fixed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(theme.hairline).frame(height: 1)
            Text(label).font(Typeface.cellLabel).tracking(1.2).foregroundStyle(theme.inkSecondary)
            Text(value).font(Typeface.cellValue).foregroundStyle(tint ?? theme.ink).lineLimit(1)
                .minimumScaleFactor(fixed ? 1 : 0.6)
                .fixedSize(horizontal: fixed, vertical: false)
        }
        .frame(maxWidth: fixed ? nil : .infinity, alignment: .leading)
        .fixedSize(horizontal: fixed, vertical: false)
    }

    private func tint(_ value: String) -> Color? {
        if value.contains("Pure") { return theme.ok }
        if value.contains("Starting") { return nil }
        return theme.warn
    }
}

/// Up Next (spec §2): the records queued after this one, reorderable, with repeat.
struct UpNextSheet: View {
    let playback: PlaybackController

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(
                        "Repeat",
                        selection: Binding(get: { playback.repeatMode }, set: { playback.repeatMode = $0 })
                    ) {
                        Text("Off").tag(PlaybackController.RepeatMode.off)
                        Text("Album").tag(PlaybackController.RepeatMode.album)
                        Text("One").tag(PlaybackController.RepeatMode.one)
                    }
                    .pickerStyle(.segmented)
                }
                if let album = playback.album {
                    Section("On the deck") {
                        AlbumLine(album: album)
                    }
                }
                Section("Up Next") {
                    if playback.upNext.isEmpty {
                        Text("Nothing queued. In the shelf, hold a record and choose Play Next or Add to Up Next.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(playback.upNext) { entry in
                        AlbumLine(album: entry.album)
                            .swipeActions {
                                Button("Remove", role: .destructive) { playback.removeUpNext(entry) }
                            }
                    }
                    .onMove { playback.moveUpNext(from: $0, to: $1) }
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
        }
    }
}

struct AlbumLine: View {
    let album: AlbumCard

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(albumID: album.id, artwork: album.artwork)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.body.weight(.semibold))
                Text("\(album.artist) · \(album.trackCount) tracks").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(album.bestFormat.replacingOccurrences(of: "FLAC ", with: ""))
                .font(Typeface.mono).foregroundStyle(.green)
        }
    }
}
