import PFCore

/// The decoded contents of a FLAC STREAMINFO metadata block.
public struct FlacStreamInfo: Sendable, Hashable {
    public var minBlockSize: Int
    public var maxBlockSize: Int
    public var minFrameSize: Int
    public var maxFrameSize: Int
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var totalFrames: Int64
    public var md5: [UInt8]

    public init(
        minBlockSize: Int, maxBlockSize: Int, minFrameSize: Int, maxFrameSize: Int,
        sampleRate: Int, channels: Int, bitsPerSample: Int, totalFrames: Int64, md5: [UInt8]
    ) {
        self.minBlockSize = minBlockSize
        self.maxBlockSize = maxBlockSize
        self.minFrameSize = minFrameSize
        self.maxFrameSize = maxFrameSize
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.totalFrames = totalFrames
        self.md5 = md5
    }

    /// False when the encoder left the MD5 signature all zero.
    public var hasMD5: Bool { md5.contains { $0 != 0 } }

    public var format: AudioFormat {
        AudioFormat(sampleRate: sampleRate, bitsPerSample: bitsPerSample, channels: channels)
    }
}
