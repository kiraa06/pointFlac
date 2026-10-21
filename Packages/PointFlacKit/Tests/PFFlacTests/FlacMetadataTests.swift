import Foundation
import PFTestSupport
import Testing

@testable import PFFlac

@Test func readsTagsAndCover() throws {
    let m = try FlacMetadataReader.read(fileAt: Fixtures.url(Fixtures.named("s24-48000")), includePictures: true)
    #expect(m.title == "Fixture Title" && m.artist == "Fixture Artist" && m.album == "Fixture Album")
    #expect(m.trackNumber == 2 && m.year == 2023 && m.trackGainDb == -6.2)
    #expect(m.frontCover?.mimeType == "image/png" && (m.frontCover?.data.count ?? 0) > 0)
    #expect(m.streamInfo.sampleRate == 48_000 && m.streamInfo.bitsPerSample == 24)
}

@Test func skipsPicturesWhenNotRequested() throws {
    let m = try FlacMetadataReader.read(fileAt: Fixtures.url(Fixtures.named("s24-48000")), includePictures: false)
    #expect(m.pictures.isEmpty && m.frontCover == nil)
    #expect(m.title == "Fixture Title")
}

@Test func untaggedFileHasNoScalars() throws {
    let m = try FlacMetadataReader.read(fileAt: Fixtures.url(Fixtures.named("s16-44100")), includePictures: true)
    #expect(m.title == nil && m.trackNumber == nil && m.year == nil && m.trackGainDb == nil)
    #expect(m.pictures.isEmpty)
}

@Test func id3PrefixedFileInheritsTags() throws {
    let m = try FlacMetadataReader.read(fileAt: Fixtures.url(Fixtures.named("id3-s24-48000")), includePictures: true)
    #expect(m.title == "Fixture Title" && m.frontCover != nil)
}

@Test func rejectsWhatTheValidatorRejects() {
    #expect(throws: FlacRejection.badMagic) {
        try FlacMetadataReader.read(fileAt: Fixtures.url(Fixtures.named("renamed-mp3")), includePictures: true)
    }
}

@Test func scalarParsingRules() {
    let streamInfo = FlacStreamInfo(
        minBlockSize: 16, maxBlockSize: 16, minFrameSize: 0, maxFrameSize: 0, sampleRate: 44_100, channels: 2,
        bitsPerSample: 16, totalFrames: 0, md5: [])
    let m = FlacMetadata(
        streamInfo: streamInfo,
        tags: [
            "TRACKNUMBER": ["2/12", "9"], "DISCNUMBER": ["1/2"], "YEAR": ["1999-05-01"],
            "REPLAYGAIN_ALBUM_GAIN": [" +3.5 DB "], "REPLAYGAIN_TRACK_GAIN": ["junk"],
        ],
        pictures: [])
    #expect(m.trackNumber == 2 && m.discNumber == 1 && m.year == 1999)
    #expect(m.albumGainDb == 3.5 && m.trackGainDb == nil)
}

/// Ledger T5: a gain that is not a finite number is treated as absent, like a missing tag, so ReplayGain (Plan 4) can
/// never scale audio by NaN or infinity. Finite values, with or without "dB", still parse.
@Test func nonFiniteGainsAreAbsent() {
    let streamInfo = FlacStreamInfo(
        minBlockSize: 16, maxBlockSize: 16, minFrameSize: 0, maxFrameSize: 0, sampleRate: 44_100, channels: 2,
        bitsPerSample: 16, totalFrames: 0, md5: [])
    func gains(_ raw: String) -> (track: Double?, album: Double?) {
        let m = FlacMetadata(
            streamInfo: streamInfo, tags: ["REPLAYGAIN_TRACK_GAIN": [raw], "REPLAYGAIN_ALBUM_GAIN": [raw]],
            pictures: [])
        return (m.trackGainDb, m.albumGainDb)
    }
    for raw in ["nan", "NaN", "-nan", "inf", "-inf", "+inf", "infinity", "-Infinity", "inf dB", "nan dB", " NAN DB "] {
        let (track, album) = gains(raw)
        #expect(track == nil && album == nil, "\"\(raw)\" read as \(String(describing: track))")
    }
    #expect(gains("-7.5 dB").track == -7.5)
    #expect(gains("+0.00 dB").album == 0)
    #expect(gains("12").track == 12)
}

private func replayGain(_ tags: [String: [String]]) -> FlacMetadata {
    FlacMetadata(
        streamInfo: FlacStreamInfo(
            minBlockSize: 16, maxBlockSize: 16, minFrameSize: 0, maxFrameSize: 0, sampleRate: 44_100, channels: 2,
            bitsPerSample: 16, totalFrames: 0, md5: []),
        tags: tags, pictures: [])
}

@Test func replayGainPeaksAndTolerantGains() {
    let m = replayGain([
        "replaygain_track_gain": ["-6.2dB"], "ReplayGain_Album_Gain": ["+1.5 dB"],
        "REPLAYGAIN_TRACK_PEAK": ["0.977"], "REPLAYGAIN_ALBUM_PEAK": [" 1.02 "],
    ])
    #expect(m.trackGainDb == -6.2 && m.albumGainDb == 1.5)
    #expect(m.trackPeak == 0.977 && m.albumPeak == 1.02)
    #expect(replayGain(["REPLAYGAIN_TRACK_GAIN": ["-6.20 dB"]]).trackGainDb == -6.2)
}

@Test func absurdReplayGainValuesAreAbsent() {
    for raw in ["-61 dB", "60.5", "1e9", "nan"] {
        #expect(replayGain(["REPLAYGAIN_TRACK_GAIN": [raw]]).trackGainDb == nil, "\(raw)")
    }
    #expect(replayGain(["REPLAYGAIN_TRACK_GAIN": ["-60 dB"]]).trackGainDb == -60)
    for raw in ["0", "-0.5", "nan", "inf", "-inf", "loud", "0,9"] {
        #expect(replayGain(["REPLAYGAIN_TRACK_PEAK": [raw]]).trackPeak == nil, "\(raw)")
    }
    #expect(replayGain([:]).albumPeak == nil)
}
