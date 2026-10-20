import PFCore
import PFFlac

/// A source of interleaved integer PCM in native range, −2^(b−1) … 2^(b−1)−1, as `FlacDecoder` produces it.
///
/// `PlaybackPipeline` decodes through this protocol rather than through `FlacDecoder` directly, so tests can inject a
/// decoder that fails on cue (a file deleted or evicted mid-playback). The pipeline uses each instance from its decode
/// thread only, so conformers need not be `Sendable`.
public protocol PCMDecoding: AnyObject {
    var format: AudioFormat { get }
    /// Total frames, or 0 when unknown.
    var totalFrames: Int64 { get }
    /// Fills `buffer` with up to `maxFrames` interleaved frames and returns how many it wrote; 0 at the end.
    func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int
    /// Positions the decoder so the next `read` starts exactly at `frame`.
    func seek(toFrame frame: Int64) throws
}

/// `FlacDecoder`'s typed-throws methods satisfy the untyped `throws` requirements.
extension FlacDecoder: PCMDecoding {}
