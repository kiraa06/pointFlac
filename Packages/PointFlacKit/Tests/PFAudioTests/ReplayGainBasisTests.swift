import Foundation
import PFCore
import PFDSP
import Testing

@testable import PFAudio

/// `Player.replayGain(for:settings:)`'s basis: where a gain comes from, by the same rule that makes it, so the Sound
/// tab's "From" never disagrees with what plays.
@Suite("ReplayGain basis")
struct ReplayGainBasisTests {
    private func item(_ loudness: TrackLoudness?) -> QueueItem {
        QueueItem(
            id: "basis", url: URL(fileURLWithPath: "/dev/null"), title: "", artist: "", album: "",
            format: AudioFormat(sampleRate: 48_000, bitsPerSample: 24, channels: 2), totalFrames: 48_000,
            loudness: loudness)
    }

    private func check(
        _ loudness: TrackLoudness?, _ mode: ReplayGainMode, _ basis: ReplayGainBasis,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let settings = ReplayGainSettings(mode: mode, preventClipping: false)
        let result = Player.replayGain(for: item(loudness), settings: settings)
        #expect(result.basis == basis, sourceLocation: sourceLocation)
        // The gain is replayGainDb's, exactly.
        #expect(
            result.gainDb == Player.replayGainDb(for: item(loudness), settings: settings),
            sourceLocation: sourceLocation)
    }

    @Test("album mode: the album tag, else the album scan")
    func album() {
        let all = TrackLoudness(
            trackGainDb: -3, albumGainDb: -7, measuredLufs: -12, measuredPeak: 0.5, albumMeasuredLufs: -10,
            albumMeasuredPeak: 0.6)
        check(all, .album, .albumTag)
        check(TrackLoudness(trackGainDb: -3, albumMeasuredLufs: -10, albumMeasuredPeak: 0.6), .album, .albumScan)
        #expect(
            Player.replayGain(for: item(TrackLoudness(albumMeasuredLufs: -10)), settings: .init(mode: .album)) == (
                -8, .albumScan
            ))
    }

    @Test("album mode with no album value falls back to the track's tag, then its scan")
    func albumFallsBackToTrack() {
        check(TrackLoudness(trackGainDb: -3, measuredLufs: -12, measuredPeak: 0.5), .album, .trackTag)
        check(TrackLoudness(measuredLufs: -12, measuredPeak: 0.5), .album, .trackScan)
        // An album measurement with no usable loudness is no album value.
        check(TrackLoudness(measuredLufs: -12, albumMeasuredLufs: -80, albumMeasuredPeak: 0.6), .album, .trackScan)
    }

    @Test("track mode: the track tag, else the track scan, ignoring album values")
    func track() {
        check(TrackLoudness(trackGainDb: -3, albumGainDb: -7, measuredLufs: -12), .track, .trackTag)
        check(TrackLoudness(albumGainDb: -7, measuredLufs: -12, measuredPeak: 0.5), .track, .trackScan)
    }

    @Test("nothing usable: no basis, and only the preamp")
    func none() {
        check(nil, .track, .none)
        check(TrackLoudness(), .album, .none)
        // Measured as silent, or a level below the −70 LUFS gate, or not finite: no usable loudness.
        check(TrackLoudness(measuredPeak: 0), .track, .none)
        check(TrackLoudness(measuredLufs: -75, measuredPeak: 0.1), .track, .none)
        check(TrackLoudness(trackGainDb: .nan, measuredLufs: -.infinity), .track, .none)
        let preamp = Player.replayGain(for: item(nil), settings: ReplayGainSettings(mode: .track, preampDb: 2))
        #expect(preamp == (2, .none))
    }

    @Test("off: no gain, no basis")
    func off() {
        let result = Player.replayGain(
            for: item(TrackLoudness(trackGainDb: -3)), settings: ReplayGainSettings(mode: .off, preampDb: 3))
        #expect(result == (0, .none))
    }
}
