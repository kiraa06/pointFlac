@preconcurrency import CFLAC
import Foundation
import PFCore

/// Why a FLAC file could not be decoded.
public enum FlacDecodeError: Error, Sendable, Equatable {
    /// The file could not be opened as a FLAC stream: it is missing or unreadable, or it has no usable STREAMINFO.
    case openFailed
    /// libFLAC entered a fatal state. The payload is libFLAC's name for that state.
    case decodeFailed(String)
    /// The target frame is outside the stream, or libFLAC could not seek to it.
    case seekFailed
    /// Reading the file failed after it was opened (libFLAC aborted on a read error).
    case ioError
}

/// A streaming libFLAC decoder that produces interleaved integer PCM in native range, −2^(b−1) … 2^(b−1)−1.
///
/// Use it from one thread at a time. It is deliberately not `Sendable`.
public final class FlacDecoder {
    public let streamInfo: FlacStreamInfo
    public var format: AudioFormat { streamInfo.format }
    /// Total frames according to STREAMINFO; 0 when the encoder did not record it.
    public var totalFrames: Int64 { streamInfo.totalFrames }
    /// The frame the next `read` returns first.
    public private(set) var currentFrame: Int64 = 0
    /// Errors libFLAC reported so far (CRC mismatches, lost sync, missing frames, …). Decoding continues past them.
    public var decodeErrorCount: Int { context.decodeErrorCount }

    private let decoder: UnsafeMutablePointer<FLAC__StreamDecoder>
    /// Handed to libFLAC as an unretained pointer. Held here so it lives exactly as long as `decoder`.
    private let context: FlacDecodeContext
    private let channels: Int
    /// libFLAC has nothing more to deliver: end of stream, or a seek to `totalFrames`.
    private var exhausted = false

    public convenience init(url: URL) throws(FlacDecodeError) {
        try self.init(url: url, verifyingMD5: false)
    }

    /// With `verifyingMD5`, libFLAC checks the audio against the STREAMINFO signature and no PCM is produced.
    init(url: URL, verifyingMD5: Bool) throws(FlacDecodeError) {
        guard let decoder = FLAC__stream_decoder_new() else { throw .openFailed }
        let context = FlacDecodeContext(discardsOutput: verifyingMD5)
        let info: FlacStreamInfo
        do {
            info = try withExtendedLifetime(context) { () throws(FlacDecodeError) -> FlacStreamInfo in
                try Self.open(decoder, url: url, context: context, verifyingMD5: verifyingMD5)
            }
        } catch {
            FLAC__stream_decoder_delete(decoder)
            throw error
        }
        self.decoder = decoder
        self.context = context
        self.streamInfo = info
        self.channels = info.channels
    }

    deinit {
        withExtendedLifetime(context) { FLAC__stream_decoder_delete(decoder) }
    }

    /// Fills `buffer` with up to `maxFrames` interleaved frames (fewer only if the buffer is smaller) and returns
    /// how many it wrote. Returns 0 at the end of the stream, or when the buffer cannot hold a single frame.
    public func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws(FlacDecodeError) -> Int {
        let capacity = min(maxFrames, buffer.count / channels)
        guard capacity > 0, let base = buffer.baseAddress else { return 0 }
        var filled = context.drainLeftover(into: base, maxFrames: capacity)
        while filled < capacity && !exhausted {
            // The leftover is empty here, so libFLAC may write straight into the caller's buffer.
            context.beginDirect(base + filled * channels, frames: capacity - filled)
            let ok = FLAC__stream_decoder_process_single(decoder) != 0
            filled += context.endDirect()
            try checkState(afterProcessing: ok)
            filled += context.drainLeftover(into: base + filled * channels, maxFrames: capacity - filled)
        }
        currentFrame += Int64(filled)
        return filled
    }

    /// Positions the decoder so the next `read` starts exactly at `frame`. `seek(toFrame: totalFrames)` positions
    /// it at the end. After a `seekFailed` thrown by libFLAC, the position is unspecified until the next successful
    /// seek.
    public func seek(toFrame frame: Int64) throws(FlacDecodeError) {
        let total = totalFrames
        guard frame >= 0, total == 0 || frame <= total else { throw .seekFailed }
        // libFLAC delivers the target block through the write callback during the seek, so clear first.
        context.discardLeftover()
        if total > 0 && frame == total {
            // libFLAC refuses seek_absolute(total_samples); the end of the stream needs no decoding.
            exhausted = true
            currentFrame = frame
            return
        }
        guard FLAC__stream_decoder_seek_absolute(decoder, UInt64(frame)) != 0 else {
            if FLAC__stream_decoder_get_state(decoder) == FLAC__STREAM_DECODER_SEEK_ERROR {
                _ = FLAC__stream_decoder_flush(decoder)
            }
            context.discardLeftover()
            throw .seekFailed
        }
        exhausted = false
        currentFrame = frame
    }

    // MARK: Integrity support

    /// Decodes everything that is left without producing PCM. Used with `verifyingMD5`.
    func decodeRemainder() throws(FlacDecodeError) {
        let ok = FLAC__stream_decoder_process_until_end_of_stream(decoder) != 0
        try checkState(afterProcessing: ok)
    }

    /// Ends decoding. Returns false when MD5 checking was on and the audio did not match the signature.
    func finish() -> Bool {
        exhausted = true
        return FLAC__stream_decoder_finish(decoder) != 0
    }

    // MARK: Private

    private func checkState(afterProcessing ok: Bool) throws(FlacDecodeError) {
        let state = FLAC__stream_decoder_get_state(decoder)
        switch state {
        case FLAC__STREAM_DECODER_END_OF_STREAM, FLAC__STREAM_DECODER_END_OF_LINK:
            exhausted = true
        case FLAC__STREAM_DECODER_ABORTED:
            throw .ioError
        case FLAC__STREAM_DECODER_SEARCH_FOR_METADATA, FLAC__STREAM_DECODER_READ_METADATA,
            FLAC__STREAM_DECODER_SEARCH_FOR_FRAME_SYNC, FLAC__STREAM_DECODER_READ_FRAME:
            if !ok { throw .decodeFailed(stateName) }
        default:
            throw .decodeFailed(stateName)
        }
    }

    private var stateName: String {
        String(cString: FLAC__stream_decoder_get_resolved_state_string(decoder))
    }

    private static func open(
        _ decoder: UnsafeMutablePointer<FLAC__StreamDecoder>, url: URL, context: FlacDecodeContext,
        verifyingMD5: Bool
    ) throws(FlacDecodeError) -> FlacStreamInfo {
        _ = FLAC__stream_decoder_set_md5_checking(decoder, verifyingMD5 ? 1 : 0)
        let client = Unmanaged.passUnretained(context).toOpaque()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return FLAC__STREAM_DECODER_INIT_STATUS_ERROR_OPENING_FILE }
            return FLAC__stream_decoder_init_file(decoder, path, flacWrite, flacMetadata, flacError, client)
        }
        guard status == FLAC__STREAM_DECODER_INIT_STATUS_OK else { throw .openFailed }
        guard FLAC__stream_decoder_process_until_end_of_metadata(decoder) != 0, let info = context.streamInfo,
            (1...8).contains(info.channels), (4...32).contains(info.bitsPerSample), info.sampleRate > 0
        else { throw .openFailed }
        context.configure(channels: info.channels, bitsPerSample: info.bitsPerSample, maxBlockSize: info.maxBlockSize)
        return info
    }
}

// MARK: - libFLAC callbacks

private let flacWrite: FLAC__StreamDecoderWriteCallback = { _, frame, buffer, client in
    guard let frame, let buffer, let client else { return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT }
    let context = Unmanaged<FlacDecodeContext>.fromOpaque(client).takeUnretainedValue()
    let header = frame.pointee.header
    context.receive(
        blockSize: Int(header.blocksize), channels: Int(header.channels),
        bitsPerSample: Int(header.bits_per_sample), planes: buffer)
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
}

private let flacMetadata: FLAC__StreamDecoderMetadataCallback = { _, metadata, client in
    guard let metadata, let client, metadata.pointee.type == FLAC__METADATA_TYPE_STREAMINFO else { return }
    let context = Unmanaged<FlacDecodeContext>.fromOpaque(client).takeUnretainedValue()
    let s = metadata.pointee.data.stream_info
    context.recordStreamInfo(
        FlacStreamInfo(
            minBlockSize: Int(s.min_blocksize), maxBlockSize: Int(s.max_blocksize),
            minFrameSize: Int(s.min_framesize), maxFrameSize: Int(s.max_framesize),
            sampleRate: Int(s.sample_rate), channels: Int(s.channels), bitsPerSample: Int(s.bits_per_sample),
            totalFrames: Int64(clamping: s.total_samples), md5: withUnsafeBytes(of: s.md5sum) { Array($0) }))
}

private let flacError: FLAC__StreamDecoderErrorCallback = { _, _, client in
    guard let client else { return }
    Unmanaged<FlacDecodeContext>.fromOpaque(client).takeUnretainedValue().recordError()
}

// MARK: - Callback state

/// State shared with the libFLAC callbacks: the STREAMINFO, the error count, and decoded samples on their way to the
/// caller. A frame goes straight into the caller's buffer while there is room; the rest of it waits in the leftover.
final class FlacDecodeContext {
    let discardsOutput: Bool
    private(set) var streamInfo: FlacStreamInfo?
    private(set) var decodeErrorCount = 0
    private var channels = 0
    private var bitsPerSample = 0

    /// Interleaved samples decoded but not yet returned live in `leftover[leftoverStart..<leftoverEnd]`.
    private var leftover = UnsafeMutableBufferPointer<Int32>(start: nil, count: 0)
    private var leftoverStart = 0
    private var leftoverEnd = 0

    /// The caller's buffer, set only for the duration of one `process_single`.
    private var direct: UnsafeMutablePointer<Int32>?
    private var directCapacity = 0
    private var directFilled = 0

    init(discardsOutput: Bool) {
        self.discardsOutput = discardsOutput
    }

    deinit {
        leftover.deallocate()
    }

    var leftoverCapacityFrames: Int { channels > 0 ? leftover.count / channels : 0 }

    /// Sizes the leftover for one block of `maxBlockSize` frames. It grows later if a block is larger.
    func configure(channels: Int, bitsPerSample: Int, maxBlockSize: Int) {
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        guard !discardsOutput else { return }
        makeLeftoverRoom(forAppending: max(maxBlockSize, 1) * channels)
    }

    func recordStreamInfo(_ info: FlacStreamInfo) {
        if streamInfo == nil { streamInfo = info }
    }

    func recordError() {
        decodeErrorCount += 1
    }

    func discardLeftover() {
        leftoverStart = 0
        leftoverEnd = 0
    }

    func beginDirect(_ out: UnsafeMutablePointer<Int32>, frames: Int) {
        direct = out
        directCapacity = frames
        directFilled = 0
    }

    /// Returns how many frames went straight into the caller's buffer.
    func endDirect() -> Int {
        let filled = directFilled
        direct = nil
        directCapacity = 0
        directFilled = 0
        return filled
    }

    /// Moves up to `maxFrames` leftover frames to `out` and returns how many it moved.
    func drainLeftover(into out: UnsafeMutablePointer<Int32>, maxFrames: Int) -> Int {
        guard leftoverEnd > leftoverStart, let base = leftover.baseAddress else { return 0 }
        let frames = min((leftoverEnd - leftoverStart) / channels, maxFrames)
        out.update(from: base + leftoverStart, count: frames * channels)
        leftoverStart += frames * channels
        if leftoverStart == leftoverEnd { discardLeftover() }
        return frames
    }

    /// Takes one decoded block of planar samples. A block whose channel count or bit depth contradicts STREAMINFO
    /// cannot be represented in the stream's format: it becomes silence of the same length and counts as an error.
    func receive(
        blockSize: Int, channels blockChannels: Int, bitsPerSample blockBits: Int,
        planes: UnsafePointer<UnsafePointer<Int32>?>
    ) {
        guard !discardsOutput, blockSize > 0, channels > 0 else { return }
        var usable = blockChannels == channels && blockBits == bitsPerSample
        if usable {
            for c in 0..<channels where planes[c] == nil { usable = false }
        }
        if !usable { decodeErrorCount += 1 }
        var done = 0
        if let direct, leftoverEnd == leftoverStart, directFilled < directCapacity {
            done = min(blockSize, directCapacity - directFilled)
            interleave(planes, usable, from: 0, frames: done, into: direct + directFilled * channels)
            directFilled += done
        }
        let rest = blockSize - done
        guard rest > 0 else { return }
        makeLeftoverRoom(forAppending: rest * channels)
        guard let base = leftover.baseAddress else { return }
        interleave(planes, usable, from: done, frames: rest, into: base + leftoverEnd)
        leftoverEnd += rest * channels
    }

    private func interleave(
        _ planes: UnsafePointer<UnsafePointer<Int32>?>, _ usable: Bool, from first: Int, frames: Int,
        into out: UnsafeMutablePointer<Int32>
    ) {
        let channels = self.channels
        guard usable else {
            out.update(repeating: 0, count: frames * channels)
            return
        }
        switch channels {
        case 1:
            out.update(from: planes[0].unsafelyUnwrapped + first, count: frames)
        case 2:
            let left = planes[0].unsafelyUnwrapped + first
            let right = planes[1].unsafelyUnwrapped + first
            for i in 0..<frames {
                out[2 * i] = left[i]
                out[2 * i + 1] = right[i]
            }
        default:
            for c in 0..<channels {
                let source = planes[c].unsafelyUnwrapped + first
                let target = out + c
                for i in 0..<frames {
                    target[i * channels] = source[i]
                }
            }
        }
    }

    private func makeLeftoverRoom(forAppending samples: Int) {
        guard leftoverEnd + samples > leftover.count else { return }
        let live = leftoverEnd - leftoverStart
        let grown = UnsafeMutableBufferPointer<Int32>.allocate(capacity: max(live + samples, leftover.count * 2))
        if live > 0, let old = leftover.baseAddress, let new = grown.baseAddress {
            new.initialize(from: old + leftoverStart, count: live)
        }
        leftover.deallocate()
        leftover = grown
        leftoverStart = 0
        leftoverEnd = live
    }
}
