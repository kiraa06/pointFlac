@preconcurrency import CFLAC
import Foundation
import PFTestSupport
import Testing

private final class StreamInfoBox {
    var sampleRate: UInt32 = 0
    var bitsPerSample: UInt32 = 0
    var channels: UInt32 = 0
    var totalSamples: UInt64 = 0
    var sawStreamInfo = false
}

@Test func libflacVersionAndOpensFixture() throws {
    #expect(String(cString: FLAC__VERSION_STRING) == "1.5.0")

    let dec = try #require(FLAC__stream_decoder_new())
    defer { FLAC__stream_decoder_delete(dec) }

    let box = StreamInfoBox()
    let context = Unmanaged.passUnretained(box).toOpaque()

    let writeCallback: FLAC__StreamDecoderWriteCallback = { _, _, _, _ in
        FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
    }
    let metadataCallback: FLAC__StreamDecoderMetadataCallback = { _, metadata, client in
        guard let metadata, let client, metadata.pointee.type == FLAC__METADATA_TYPE_STREAMINFO else { return }
        let box = Unmanaged<StreamInfoBox>.fromOpaque(client).takeUnretainedValue()
        let info = metadata.pointee.data.stream_info
        box.sampleRate = info.sample_rate
        box.bitsPerSample = info.bits_per_sample
        box.channels = info.channels
        box.totalSamples = info.total_samples
        box.sawStreamInfo = true
    }
    let errorCallback: FLAC__StreamDecoderErrorCallback = { _, _, _ in }

    let path = Fixtures.url(Fixtures.named("s32-96000")).path
    let status = FLAC__stream_decoder_init_file(dec, path, writeCallback, metadataCallback, errorCallback, context)
    #expect(status == FLAC__STREAM_DECODER_INIT_STATUS_OK)

    #expect(FLAC__stream_decoder_process_until_end_of_metadata(dec) != 0)
    #expect(box.sawStreamInfo)
    #expect(box.sampleRate == 96_000)
    #expect(box.bitsPerSample == 32)
    #expect(box.channels == 2)
    #expect(box.totalSamples == UInt64(Fixtures.named("s32-96000").frames))
    #expect(FLAC__stream_decoder_finish(dec) != 0)
}
