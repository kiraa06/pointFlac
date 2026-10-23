import PFDesign
import SwiftUI
import UIKit

/// The record's songs as the back of its sleeve lists them (plan 9 §3): side by side, each with its code, title and
/// exact time, and each side's total. The sheet and the deck's unfolded display both read from it, so they never
/// disagree about a time or a code.
struct Tracklist {
    struct Song: Identifiable {
        /// The album track index, which `PlaybackController.jump(toTrack:)` takes.
        let index: Int
        /// "A1", "B2": side letter and place on the side.
        let code: String
        let title: String
        let seconds: Double
        var id: Int { index }
    }

    struct Side: Identifiable {
        let letter: String
        let seconds: Double
        let songs: [Song]
        var id: String { letter }
    }

    let sides: [Side]
    let songCount: Int
    let seconds: Double

    init(tracks: [TrackRow], layout: SideLayout) {
        sides = layout.sides.map { side in
            Side(
                letter: side.letter, seconds: side.duration,
                songs: side.tracks.compactMap { index in
                    guard tracks.indices.contains(index) else { return nil }
                    let length = tracks[index].durationSeconds
                    return Song(
                        index: index, code: layout.code(ofTrack: index), title: tracks[index].title,
                        seconds: length.isFinite && length > 0 ? length : 0)
                })
        }
        songCount = tracks.count
        seconds = layout.sides.reduce(0) { $0 + $1.duration }
    }

    /// "5 SONGS · 19:05 · 2 SIDES", as the sleeve's back prints it.
    var summary: String {
        "\(songCount) \(songCount == 1 ? "SONG" : "SONGS") · \(Self.clock(seconds)) · \(sides.count) "
            + (sides.count == 1 ? "SIDE" : "SIDES")
    }

    /// The summary as VoiceOver reads it: "5 songs, 19 minutes 5 seconds, 2 sides".
    var spokenSummary: String {
        "\(Self.count(songCount, "song")), \(Self.spoken(seconds)), \(Self.count(sides.count, "side"))"
    }

    /// A row as VoiceOver reads it: "A1, Ignition, 3 minutes 10 seconds".
    static func label(_ song: Song) -> String {
        "\(song.code), \(song.title), \(spoken(song.seconds))"
    }

    /// m:ss to the nearest second. A length, not a position: a 3:09.998 song is a 3:10 song, so the sheet and the
    /// display print what VoiceOver says.
    static func clock(_ seconds: Double) -> String {
        ClockFormat.clock(seconds.rounded())
    }

    /// "3 minutes 10 seconds", "4 minutes", "45 seconds".
    static func spoken(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let minutes = whole / 60
        let rest = whole % 60
        if minutes == 0 { return count(rest, "second") }
        if rest == 0 { return count(minutes, "minute") }
        return "\(count(minutes, "minute")) \(count(rest, "second"))"
    }

    private static func count(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}

/// The back-cover tracklist (plan 9 §3), opened from the song line under the title in Deck and Cover alike: the
/// sleeve, title, artist and year, and format, then the record's songs by side. The playing song is tinted in the
/// record's colour, with moving bars in place of its code. Tapping a song plays the record from it, and the sheet
/// drops a moment later, so the tint is seen to move first.
struct TracklistSheet: View {
    let playback: PlaybackController
    let theme: Theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The code column, wide enough for "A10" in the row's caption face, growing with Dynamic Type.
    @ScaledMetric(relativeTo: .footnote) private var codeWidth: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 46
    /// The song just tapped: tinted at once, before the player has moved to it.
    @State private var picked: Int?

    private var playing: Int? { picked ?? playback.trackIndex }

    /// The record's colours, in greys under Monochrome (the sleeve keeps its own).
    private var palette: ArtPalette { ArtPalette(seed: playback.album?.id ?? "pointflac").tint(for: theme) }

    /// The tint's colour: `line` is the record's hue deep enough for a light page, `base` its bright twin for a dark
    /// one, as the progress wave draws them.
    private var accent: Color { theme.isDark ? palette.base : palette.line }

    /// The playing row's wash.
    private var wash: Color { accent.opacity(0.12) }

    /// The playing title: the accent, darkened (or, on a dark sheet, lightened) until it reads at 4.5:1 on the wash.
    private var tint: Color { accent.readable(on: theme.background, under: wash) }

    var body: some View {
        let list = Tracklist(tracks: playback.tracks, layout: playback.layout)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let album = playback.album {
                        header(album)
                            .padding(.horizontal, 12)
                    }
                    Text(list.summary)
                        .font(.caption2.monospaced().weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(theme.inkSecondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 18)
                        .accessibilityLabel(list.spokenSummary)
                    ForEach(list.sides) { side in
                        sideHeader(side)
                            .padding(.horizontal, 12)
                        ForEach(side.songs) { song in
                            row(song)
                                .id(song.index)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 26)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear {
                // No anchor: only as far as it takes to show the playing row, so the header stays when it can.
                if let playing { proxy.scrollTo(playing) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: picked)
        .accessibilityIdentifier("tracklistSheet")
    }

    // MARK: Pieces

    /// The sleeve, title, artist and year, and the format; at the accessibility sizes the format moves under the
    /// artist, so the title keeps the width.
    private func header(_ album: AlbumCard) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ArtworkView(albumID: album.id, artwork: album.artwork)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 8, y: 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                Text(album.year.map { "\(album.artist) · \($0)" } ?? album.artist)
                    .font(.subheadline)
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(2)
                if typeSize.isAccessibilitySize {
                    format(album)
                }
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 10)
                format(album)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func format(_ album: AlbumCard) -> some View {
        Text(album.bestFormat)
            .font(.caption.monospaced())
            .foregroundStyle(theme.inkSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// "SIDE A  10:05", then a hairline across the rest of the row.
    private func sideHeader(_ side: Tracklist.Side) -> some View {
        HStack(spacing: 10) {
            Text("SIDE \(side.letter)")
            Text(Tracklist.clock(side.seconds))
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
        .font(.caption2.monospaced().weight(.semibold))
        .tracking(1.2)
        .foregroundStyle(theme.inkSecondary)
        .lineLimit(1)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Side \(side.letter), \(Tracklist.spoken(side.seconds))")
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ song: Tracklist.Song) -> some View {
        let current = song.index == playing
        return Button {
            pick(song.index)
        } label: {
            HStack(spacing: 14) {
                ZStack(alignment: .leading) {
                    if current {
                        PlayingBars(colour: tint, moving: playback.isPlaying && !reduceMotion)
                            .transition(.opacity)
                    } else {
                        Text(song.code)
                            .font(.footnote.monospaced().weight(.semibold))
                            .foregroundStyle(theme.inkSecondary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .frame(width: codeWidth, alignment: .leading)
                Text(song.title)
                    .font(current ? .body.weight(.semibold) : .body)
                    .foregroundStyle(current ? tint : theme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Tracklist.clock(song.seconds))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: rowHeight)
            .background {
                if current {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(wash)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(RowPress(wash: theme.ink.opacity(0.05)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Tracklist.label(song))
        .accessibilityValue(current ? "Playing" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tracklistTrack-\(song.index)")
    }

    /// The tint moves to the song at once, the record plays from it, and the sheet drops a beat later.
    private func pick(_ index: Int) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { picked = index }
        playback.jump(toTrack: index)
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            dismiss()
        }
    }
}

/// A row under a finger: a faint wash in the playing row's shape, so a press reads before the jump.
private struct RowPress: ButtonStyle {
    let wash: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(wash)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
    }
}

/// The playing song's three bars, in place of its code: 3.5 pt wide, rising from 4 to 14 pt and back once a second,
/// each a third of a beat behind the last. They stand still at mid height while the record is paused, and under
/// Reduce Motion.
struct PlayingBars: View {
    let colour: Color
    let moving: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !moving)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<3, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(colour)
                        .frame(width: 3.5, height: height(bar, at: now))
                }
            }
            .frame(height: 14, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    /// 4 pt at the start and end of each one-second cycle, 14 pt halfway, eased in and out (the mockup's keyframes).
    private func height(_ bar: Int, at now: Double) -> CGFloat {
        guard moving else { return 9 }
        let phase = (now + Double(bar) * 0.35).truncatingRemainder(dividingBy: 1)
        let rise = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        let eased = rise * rise * (3 - 2 * rise)
        return 4 + 10 * eased
    }
}

extension Color {
    /// This colour as seen through a `wash` laid over `background`, pushed towards black on a light page or white on a
    /// dark one, keeping its hue, until its WCAG contrast reaches `ratio`. Unchanged when it already does.
    fileprivate func readable(on background: Color, under wash: Color, ratio: Double = 4.5) -> Color {
        let page = Self.components(background)
        let tint = Self.components(wash)
        // The wash composited over the page: what the text actually sits on.
        let ground = (0..<3).map { page[$0] * (1 - tint[3]) + tint[$0] * tint[3] }
        let groundLuminance = Self.luminance(ground)
        let darken = groundLuminance > 0.18
        let base = Self.components(self)
        var colour = Array(base.prefix(3))
        for step in 0...50 {
            let t = Double(step) / 50
            colour = (0..<3).map { darken ? base[$0] * (1 - t) : base[$0] + (1 - base[$0]) * t }
            let lighter = max(Self.luminance(colour), groundLuminance)
            let darker = min(Self.luminance(colour), groundLuminance)
            if (lighter + 0.05) / (darker + 0.05) >= ratio { break }
        }
        return Color(red: colour[0], green: colour[1], blue: colour[2])
    }

    /// Red, green, blue and alpha, gamma-encoded sRGB.
    private static func components(_ colour: Color) -> [Double] {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        UIColor(colour).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { min(max(Double($0), 0), 1) }
    }

    /// WCAG relative luminance of gamma-encoded sRGB.
    private static func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
