import AVFAudio

/// Mastering-quality sample-rate converter for interleaved Float32 audio, used when the DAC refuses the
/// file's rate (pointFlac never lets iOS resample silently).
///
/// Wraps `AVAudioConverter` (Mastering algorithm, maximum quality). The converter keeps filter state across
/// `process` calls so a stream can be fed in chunks; `flush` drains the tail at end of stream.
///
/// Thread safety: `AVAudioConverter` is not `Sendable`, so this class is deliberately not `Sendable`. Use
/// each instance from one thread only: the decode thread, never the render thread (it allocates).
public final class SampleRateConverter {
    public enum Failure: Error, Equatable {
        case invalidParameters
        case converterUnavailable
    }

    /// Hands one buffer to the converter's input block. `AVAudioConverter.convert(to:error:withInputFrom:)`
    /// invokes the block synchronously on the calling thread, so the unchecked `Sendable` is safe.
    private final class InputFeed: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let channels: Int
    private let ratio: Double

    public init(inputRate: Int, outputRate: Int, channels: Int) throws {
        guard inputRate > 0, outputRate > 0, channels > 0,
            let inFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(inputRate),
                channels: AVAudioChannelCount(channels), interleaved: true),
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(outputRate),
                channels: AVAudioChannelCount(channels), interleaved: true)
        else { throw Failure.invalidParameters }
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw Failure.converterUnavailable }
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter = conv
        inputFormat = inFmt
        outputFormat = outFmt
        self.channels = channels
        ratio = Double(outputRate) / Double(inputRate)
    }

    /// Converts `frames` interleaved frames from `input`, appending the result to `output`.
    /// - Returns: the number of output frames appended.
    public func process(_ input: UnsafeBufferPointer<Float>, frames: Int, into output: inout [Float]) -> Int {
        guard frames > 0, input.count >= frames * channels,
            let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
            let dst = inBuf.floatChannelData?[0], let src = input.baseAddress
        else { return 0 }
        dst.update(from: src, count: frames * channels)
        inBuf.frameLength = AVAudioFrameCount(frames)

        let feed = InputFeed(buffer: inBuf)
        return drain(into: &output, extra: frames) { _, status in
            if feed.supplied {
                status.pointee = .noDataNow
                return nil
            }
            feed.supplied = true
            status.pointee = .haveData
            return feed.buffer
        }
    }

    /// Drains the converter's tail with end-of-stream. Call once after the last `process`.
    /// - Returns: the number of output frames appended.
    public func flush(into output: inout [Float]) -> Int {
        drain(into: &output, extra: 0) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func drain(
        into output: inout [Float], extra: Int,
        input: @escaping AVAudioConverterInputBlock
    ) -> Int {
        // Headroom covers filter-tail frames released by this call.
        let capacity = AVAudioFrameCount(Double(extra) * ratio) + 8192
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity),
            let data = outBuf.floatChannelData?[0]
        else { return 0 }
        var total = 0
        while true {
            outBuf.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error, withInputFrom: input)
            let n = Int(outBuf.frameLength)
            if n > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: data, count: n * channels))
                total += n
            }
            // Keep going only while the output buffer came back full (more may be pending).
            if status == .error || n < Int(capacity) { break }
        }
        return total
    }
}
