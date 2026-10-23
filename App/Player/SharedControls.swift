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
    /// The shelf is empty: the first run, when getting music must be the obvious next step (spec §4.1).
    var libraryEmpty = false
    var addFromFiles: () -> Void = {}
    var getMusic: () -> Void = {}
    /// Shows the Sound tab, from the signal details.
    var openSound: () -> Void = {}
    @State private var tracklistOpen = false

    private var player: Player { playback.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBlock
                .opacity(hidden ? 0 : 1)
            SignalCells(signal: player.signal, theme: theme, openSound: openSound)
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
                if libraryEmpty {
                    Text("Your shelf is empty. Bring in a record to start.")
                        .font(Typeface.artist)
                        .foregroundStyle(theme.inkSecondary)
                    HStack(spacing: 10) {
                        Button("Add music from Files", systemImage: "folder", action: addFromFiles)
                            .buttonStyle(.glassProminent)
                            .accessibilityIdentifier("emptyAddFiles")
                        Button("Browse online", systemImage: "globe", action: getMusic)
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("emptyGetMusic")
                    }
                    .padding(.top, 6)
                } else {
                    Text("Swipe up for the shelf and pick a record.")
                        .font(Typeface.artist)
                        .foregroundStyle(theme.inkSecondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(Typeface.display(30))
                        .tracking(-0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("nowPlayingTitle")
                    if let note = SignalStrip.titleNote(player.signal) {
                        // Fixed size and a higher priority: a long title truncates first, the note never.
                        Text(note)
                            .font(Typeface.monoSmall)
                            .foregroundStyle(player.signal.scrubbing ? theme.inkSecondary : theme.altered)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                            .accessibilityLabel("Signal note: \(SignalStrip.titleNoteSpoken(player.signal) ?? note)")
                            .accessibilityIdentifier("titleNote")
                    }
                }
                songLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.3), value: title)
    }

    /// The song line, which opens the back-cover tracklist (plan 9 §3): the same words, with a small chevron saying
    /// there is more. Its touch area reaches above and below the line, without moving anything.
    private var songLine: some View {
        Button {
            tracklistOpen = true
        } label: {
            HStack(spacing: 5) {
                Text(subtitle)
                    .font(Typeface.artist)
                    .lineLimit(1)
                    .accessibilityIdentifier("nowPlayingSubtitle")
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(theme.inkSecondary)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tracklist")
        .accessibilityValue(subtitle)
        .accessibilityHint("Shows the record's songs")
        .accessibilityIdentifier("tracklistButton")
        .sheet(isPresented: $tracklistOpen) {
            TracklistSheet(playback: playback, theme: theme)
        }
        #if DEBUG
            .task {
                // `-PFTracklist sheet`: opens the back-cover tracklist once a record plays, for screenshots.
                guard UserDefaults.standard.string(forKey: "PFTracklist") == "sheet" else { return }
                for _ in 0..<100 where playback.trackIndex == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .milliseconds(500))
                tracklistOpen = true
            }
        #endif
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
                                .background(Circle().fill(theme.ok)).foregroundStyle(
                                    theme.isMonochrome ? theme.playGlyph : .black)
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

    /// The playing record's colours: the played part of the bar is drawn in them.
    private var palette: ArtPalette { ArtPalette(seed: playback.album?.id ?? "pointflac").tint(for: theme) }

    var body: some View { progress }

    private var length: Double { playback.currentTrack?.durationSeconds ?? 0 }

    private var elapsed: Double { scrubbing ?? player.position.seconds }

    private var progress: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let fraction = length > 0 ? min(max(elapsed / length, 0), 1) : 0
                WaveProgress(
                    fraction: fraction, flowing: player.status == .playing,
                    played: theme.isDark ? palette.base : palette.line, rest: theme.hairline
                )
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
                                await playback.seek(to: target)
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
                Task { await playback.seek(to: max(0, min(length, elapsed + step))) }
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

/// The progress bar's line: the played part a wave in the record's colour, flowing while the music plays (still while
/// paused, and under Reduce Motion), easing flat into the playhead; the rest a plain line.
struct WaveProgress: View {
    let fraction: Double
    let flowing: Bool
    let played: Color
    let rest: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One wave every this many points, this tall either side of the line, flowing a wavelength in this many seconds.
    static let wavelength: CGFloat = 16
    static let amplitude: CGFloat = 3.5
    static let secondsPerWave = 1.1
    static let lineWidth: CGFloat = 3.5

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !flowing || reduceMotion)) { context in
            Canvas { canvas, size in
                let mid = size.height / 2
                let head = size.width * min(max(fraction, 0), 1)
                var restLine = Path()
                restLine.move(to: CGPoint(x: head, y: mid))
                restLine.addLine(to: CGPoint(x: size.width, y: mid))
                canvas.stroke(restLine, with: .color(rest), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                guard head > 0 else { return }
                let seconds = context.date.timeIntervalSinceReferenceDate
                let phase = reduceMotion ? 0 : 2 * Double.pi * seconds / Self.secondsPerWave
                var wave = Path()
                var x: CGFloat = 0
                while x <= head {
                    // The wave settles flat over its last half-wavelength, so it meets the playhead on the line.
                    let taper = min(1, (head - x) / (Self.wavelength / 2))
                    let y =
                        mid + Self.amplitude * taper * CGFloat(sin(2 * Double.pi * Double(x / Self.wavelength) - phase))
                    if x == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
                    x += 1
                }
                wave.addLine(to: CGPoint(x: head, y: mid))
                canvas.stroke(
                    wave, with: .color(played),
                    style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                let dot = CGRect(x: head - 4, y: mid - 4, width: 8, height: 8)
                canvas.fill(Path(ellipseIn: dot), with: .color(played))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The signal strip as the mockups draw it: FORMAT · DEPTH · DAC · SIGNAL cells, from `SignalStrip.text`, so the
/// words are exactly the strip's and its honesty rules hold. When the delivered resolution is known, the SIGNAL cell
/// shows its text (HI-RES / LOSSLESS, PURE) where the indicator words would be; the altered states are noted beside
/// the title instead. The whole strip is one accessibility element with the id the UI tests read.
struct SignalCells: View {
    let signal: SignalState
    let theme: Theme
    var openSound: (() -> Void)?
    @State private var details = false

    var body: some View {
        strip(SignalStrip.text(signal))
    }

    /// The strip's spoken label: the plain text, with the resolution's meaning in place of the indicator words.
    private func spoken(_ text: String) -> String {
        let badges = SignalStrip.signalBadges(signal)
        let parts = text.components(separatedBy: " · ")
        guard SignalStrip.showsResolution(signal), parts.count >= 4, parts[0] == "FLAC" else { return text }
        var spoken = parts[0...2].joined(separator: ", ")
        spoken += ". Signal: " + badges.map(\.accessibilityLabel).joined(separator: ", ")
        if parts.count > 4 { spoken += ". " + parts[4...].joined(separator: " ") }
        return spoken
    }

    /// The SIGNAL cell's text when the delivered resolution is known: plain words in the cell's own font, tinted by
    /// meaning (Hi-Res gold, Lossless neutral, Pure green, speaker tuning quiet), joined by a quiet " · ". One Text, so it baselines with
    /// the other cells.
    private var resolutionText: Text {
        let badges = SignalStrip.signalBadges(signal)
        let dot = Text(" · ").foregroundStyle(theme.inkSecondary)
        var result = Text("")
        for (index, badge) in badges.enumerated() {
            result = Text(
                "\(result)\(index > 0 ? dot : Text(""))\(Text(badge.displayText).foregroundStyle(color(badge)))")
        }
        return result
    }

    private func color(_ badge: SignalBadge) -> Color {
        switch badge {
        case .pure: theme.ok
        case .hiRes: theme.hiRes
        case .lossless: theme.ink
        case .speakerTuning: theme.inkSecondary
        }
    }

    private func strip(_ text: String) -> some View {
        cells(text)
            .contentShape(Rectangle())
            .onTapGesture { details = true }
            .sheet(isPresented: $details) {
                SignalDetailsSheet(signal: signal, openSound: sheetOpenSound)
                    .presentationDetents([.medium, .large])
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(text))
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
                    // With the resolution text the first three cells size to their content, so the SIGNAL cell gets
                    // the leftover width.
                    let hugging = SignalStrip.showsResolution(signal)
                    cell("FORMAT", parts[0], fixed: hugging)
                    cell("DEPTH", parts[1], fixed: hugging)
                    cell("DAC", parts[2], fixed: hugging)
                    if hugging {
                        resolutionCell
                    } else {
                        cell("SIGNAL", parts[3], tint: tint(parts[3]), fixed: true)
                    }
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

    /// The SIGNAL cell with the resolution text in place of the indicator words, laid out like `cell`.
    private var resolutionCell: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(theme.hairline).frame(height: 1)
            Text("SIGNAL").font(Typeface.cellLabel).tracking(1.2).foregroundStyle(theme.inkSecondary)
            resolutionText.font(Typeface.cellValue).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Open Sound in the details: the sheet closes as the tab changes.
    private var sheetOpenSound: (() -> Void)? {
        guard let openSound else { return nil }
        return {
            details = false
            openSound()
        }
    }

    private func tint(_ value: String) -> Color? {
        if value.contains("Pure") { return theme.ok }
        if value.contains("Starting") { return nil }
        return theme.altered
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
                                    .monoDestructive()
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
                .font(Typeface.mono).monoForeground(.green)
        }
    }
}
