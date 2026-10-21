import Foundation
import PFCore

/// A track in the player's queue: what the pipeline needs to play it, and what Now Playing shows for it.
public struct QueueItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var url: URL
    public var title: String
    public var artist: String
    public var album: String
    /// The format recorded at import, until the track starts: then the player replaces it with the decoder's own, which
    /// is authoritative. Positions convert between frames and time at its sample rate.
    public var format: AudioFormat
    /// Total frames, or 0 when unknown.
    public var totalFrames: Int64
    /// Cover art as image file data (JPEG or PNG), when the file has any.
    public var artwork: Data?
    /// What the library knows about the track's loudness (its ReplayGain tags and the R128 scan), from which the
    /// player works out its ReplayGain (`Player.replayGainDb(for:settings:)`); nil when nothing is known. As it was
    /// when the item was made: a scan that measures the track later reaches the queues made after it.
    public var loudness: TrackLoudness?

    public init(
        id: String, url: URL, title: String, artist: String, album: String, format: AudioFormat, totalFrames: Int64,
        artwork: Data? = nil, loudness: TrackLoudness? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.format = format
        self.totalFrames = totalFrames
        self.artwork = artwork
        self.loudness = loudness
    }

    /// The item as the pipeline plays it, at no gain: the player sets `gainDb` from its ReplayGain settings.
    public var playbackItem: PlaybackItem {
        PlaybackItem(id: id, url: url, format: format, totalFrames: totalFrames)
    }

    /// The track's length; zero when its frame count is unknown.
    public var duration: Duration {
        duration(ofFrames: totalFrames)
    }

    /// `frames` of this track as time, to the nearest nanosecond.
    ///
    /// Integer arithmetic, so a frame count maps to the same `Duration` every time, and `frame(at:)` maps it back to
    /// the same frame: the player and its tests compare positions exactly.
    func duration(ofFrames frames: Int64) -> Duration {
        let rate = Int64(format.sampleRate)
        guard frames > 0, rate > 0 else { return .zero }
        let nanoseconds = ((frames % rate) * 1_000_000_000 + rate / 2) / rate
        return .seconds(frames / rate) + .nanoseconds(nanoseconds)
    }

    /// The frame at `time` in this track, to the nearest frame, clamped to the track when its length is known.
    func frame(at time: Duration) -> Int64 {
        let rate = Int64(format.sampleRate)
        guard time > .zero, rate > 0 else { return 0 }
        let (seconds, attoseconds) = time.components
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: rate)
        guard !overflow else { return totalFrames > 0 ? totalFrames : .max }
        let frame = whole + (attoseconds / 1_000_000_000 * rate + 500_000_000) / 1_000_000_000
        return totalFrames > 0 ? min(frame, totalFrames) : frame
    }
}
