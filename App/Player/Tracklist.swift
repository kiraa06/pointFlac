import PFDesign

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
        /// Whose song it is, for a playlist's: "Lumen Arcade · Night Drive". Nil for an album's, all its own.
        var source: String? = nil
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

    /// `playlist`: the songs are a playlist's, from many records, and each says whose it is.
    init(tracks: [TrackRow], layout: SideLayout, playlist: Bool = false) {
        sides = layout.sides.map { side in
            Side(
                letter: side.letter, seconds: side.duration,
                songs: side.tracks.compactMap { index in
                    guard tracks.indices.contains(index) else { return nil }
                    let track = tracks[index]
                    let length = track.durationSeconds
                    return Song(
                        index: index, code: layout.code(ofTrack: index), title: track.title,
                        seconds: length.isFinite && length > 0 ? length : 0,
                        source: playlist ? "\(track.artist) · \(track.album)" : nil)
                })
        }
        songCount = tracks.count
        seconds = layout.sides.reduce(0) { $0 + $1.duration }
    }

    /// The record on the deck's songs; a playlist's each with whose it is.
    @MainActor
    init(of playback: PlaybackController) {
        self.init(tracks: playback.tracks, layout: playback.layout, playlist: playback.album?.pressing != nil)
    }

    /// "5 SONGS · 19:05 · 2 SIDES", as the sleeve's back prints it.
    var summary: String { summaryParts.joined(separator: " · ") }

    /// The summary's three parts, for stacking when one line is too narrow for them.
    var summaryParts: [String] {
        [
            "\(songCount) \(songCount == 1 ? "SONG" : "SONGS")", Self.clock(seconds),
            "\(sides.count) \(sides.count == 1 ? "SIDE" : "SIDES")",
        ]
    }

    /// The summary as VoiceOver reads it: "5 songs, 19 minutes 5 seconds, 2 sides".
    var spokenSummary: String {
        "\(Self.count(songCount, "song")), \(Self.spoken(seconds)), \(Self.count(sides.count, "side"))"
    }

    /// A row as VoiceOver reads it: "A1, Ignition, 3 minutes 10 seconds"; a playlist's song with whose it is, as its
    /// row shows it: "A1, Ignition, Lumen Arcade · Night Drive, 3 minutes 10 seconds".
    static func label(_ song: Song) -> String {
        [song.code, song.title, song.source, spoken(song.seconds)].compactMap(\.self).joined(separator: ", ")
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
