import Foundation
import PFCore
import PFTestSupport
import Testing

@testable import PFFlac

/// Reads from the decoder's current position to the end of the stream in `chunk`-frame reads.
private func decodeToEnd(_ d: FlacDecoder, chunk: Int) throws -> [Int32] {
    let channels = d.format.channels
    var out: [Int32] = []
    var scratch = [Int32](repeating: 0, count: chunk * channels)
    while true {
        let n = try scratch.withUnsafeMutableBufferPointer { try d.read(into: $0, maxFrames: chunk) }
        if n == 0 { break }
        out += scratch[0..<(n * channels)]
    }
    return out
}

/// One read of up to `frames` frames.
private func readFrames(_ d: FlacDecoder, _ frames: Int) throws -> [Int32] {
    var out = [Int32](repeating: 0, count: frames * d.format.channels)
    let n = try out.withUnsafeMutableBufferPointer { try d.read(into: $0, maxFrames: frames) }
    return Array(out[0..<(n * d.format.channels)])
}

@Suite struct FlacDecoderTests {
    @Test(arguments: Fixtures.all.filter { $0.expect == .accept && $0.name != "corrupt-mid-s16-44100" })
    func decodesBitExactly(_ f: Fixture) throws {
        let d = try FlacDecoder(url: Fixtures.url(f))
        var out = [Int32](repeating: 0, count: Int(f.frames) * f.channels)
        var written = 0
        try out.withUnsafeMutableBufferPointer { buf in
            while true {
                let n = try d.read(
                    into: UnsafeMutableBufferPointer(rebasing: buf[(written * f.channels)...]), maxFrames: 1000)
                if n == 0 { break }
                written += n
            }
        }
        #expect(Int64(written) == f.frames && out == Fixtures.rawSamples(f))
        #expect(d.decodeErrorCount == 0)
        #expect(d.currentFrame == f.frames)
    }

    @Test func exposesStreamInfo() throws {
        let f = Fixtures.named("s32-192000")
        let d = try FlacDecoder(url: Fixtures.url(f))
        #expect(d.format == AudioFormat(sampleRate: 192_000, bitsPerSample: 32, channels: 2))
        #expect(d.totalFrames == f.frames && d.streamInfo.totalFrames == f.frames)
        #expect(d.streamInfo.hasMD5 && d.streamInfo.maxBlockSize >= d.streamInfo.minBlockSize)
        #expect(d.currentFrame == 0)
    }

    @Test func thirtyTwoBitSamplesKeepTheFullInt32Range() throws {
        let f = Fixtures.named("s32-44100")
        let raw = Fixtures.rawSamples(f)
        // The fixture must reach beyond 24 bits for this test to mean anything.
        #expect(raw.contains { $0 > (1 << 30) } && raw.contains { $0 < -(1 << 30) })
        let d = try FlacDecoder(url: Fixtures.url(f))
        #expect(try decodeToEnd(d, chunk: 4096) == raw)
    }

    @Test func readsInOddChunkSizesBitExactly() throws {
        let f = Fixtures.named("s24-96000")
        let d = try FlacDecoder(url: Fixtures.url(f))
        #expect(try decodeToEnd(d, chunk: 7) == Fixtures.rawSamples(f))
    }

    @Test func seeksToExactFrame() throws {
        let f = Fixtures.named("s24-96000")
        let d = try FlacDecoder(url: Fixtures.url(f))
        try d.seek(toFrame: 1234)
        #expect(d.currentFrame == 1234)
        #expect(try readFrames(d, 100) == Array(Fixtures.rawSamples(f)[(1234 * 2)..<(1334 * 2)]))
        #expect(d.currentFrame == 1334)
    }

    @Test func seekToEndThenReadReturnsZero() throws {
        let f = Fixtures.named("s24-96000")
        let d = try FlacDecoder(url: Fixtures.url(f))
        _ = try readFrames(d, 500)
        try d.seek(toFrame: d.totalFrames)
        #expect(d.currentFrame == d.totalFrames)
        #expect(try readFrames(d, 64).isEmpty)
        #expect(try readFrames(d, 64).isEmpty)
        // Seeking back from the end resumes normal decoding.
        try d.seek(toFrame: 0)
        #expect(try decodeToEnd(d, chunk: 1000) == Fixtures.rawSamples(f))
    }

    @Test func seekOutsideTheStreamFailsAndLeavesTheDecoderUsable() throws {
        let f = Fixtures.named("s24-96000")
        let d = try FlacDecoder(url: Fixtures.url(f))
        #expect(throws: FlacDecodeError.seekFailed) { try d.seek(toFrame: d.totalFrames + 1) }
        #expect(throws: FlacDecodeError.seekFailed) { try d.seek(toFrame: -1) }
        try d.seek(toFrame: 4000)
        #expect(try decodeToEnd(d, chunk: 1000) == Array(Fixtures.rawSamples(f)[(4000 * 2)...]))
    }

    @Test func seeksAcrossBlocksOfAMultiBlockFile() throws {
        // corrupt-mid holds four 4096-frame blocks; only the third (frames 8192..<12288) is damaged.
        let f = Fixtures.named("corrupt-mid-s16-44100")
        let raw = Fixtures.rawSamples(f)
        let d = try FlacDecoder(url: Fixtures.url(f))
        try d.seek(toFrame: 13_000)
        #expect(try decodeToEnd(d, chunk: 333) == Array(raw[(13_000 * 2)...]))
        try d.seek(toFrame: 100)
        #expect(try readFrames(d, 5000) == Array(raw[(100 * 2)..<(5100 * 2)]))  // crosses the 4096 boundary
        try d.seek(toFrame: 4096)
        #expect(try readFrames(d, 10) == Array(raw[(4096 * 2)..<(4106 * 2)]))
        #expect(d.currentFrame == 4106)
    }

    /// libFLAC 1.5.0 (verified against stream_decoder.c and by this test) does not output the frame whose CRC-16
    /// fails: it reports `FRAME_CRC_MISMATCH`, drops the frame and resynchronises. When the next good frame
    /// arrives, its sample number exposes the gap, libFLAC reports `MISSING_FRAME` and writes silent frames
    /// to fill it. The caller therefore sees silence in place of the damaged block, and the total sample count
    /// is preserved.
    @Test(arguments: [1000, 7, 4096, 16384])
    func reportsMidstreamDamageAndContinues(chunk: Int) throws {
        let f = Fixtures.named("corrupt-mid-s16-44100")
        let raw = Fixtures.rawSamples(f)
        let d = try FlacDecoder(url: Fixtures.url(f))
        let out = try decodeToEnd(d, chunk: chunk)
        #expect(out.count == 16384 * 2)
        #expect(d.decodeErrorCount >= 1)
        #expect(d.currentFrame == 16384)
        let damaged = (8192 * 2)..<(12288 * 2)
        guard out.count == raw.count else { return }
        #expect(out[damaged].allSatisfy { $0 == 0 })
        #expect(out[..<damaged.lowerBound] == raw[..<damaged.lowerBound])
        #expect(out[damaged.upperBound...] == raw[damaged.upperBound...])
    }

    @Test func refusesFilesThatAreNotDecodableFlac() {
        for name in ["renamed-mp3", "empty"] {
            #expect(throws: FlacDecodeError.openFailed) { try FlacDecoder(url: Fixtures.url(Fixtures.named(name))) }
        }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID()).flac")
        #expect(throws: FlacDecodeError.openFailed) { try FlacDecoder(url: missing) }
    }

    @Test func leftoverGrowsWhenAFrameExceedsMaxBlockSize() {
        // STREAMINFO claims 16-frame blocks, then a 100-frame block arrives.
        let context = FlacDecodeContext(discardsOutput: false)
        context.configure(channels: 2, bitsPerSample: 16, maxBlockSize: 16)
        let left = (0..<100).map { Int32($0) }
        let right = (0..<100).map { -Int32($0) - 1 }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                let planes: [UnsafePointer<Int32>?] = [l.baseAddress, r.baseAddress]
                planes.withUnsafeBufferPointer {
                    context.receive(blockSize: 100, channels: 2, bitsPerSample: 16, planes: $0.baseAddress!)
                }
            }
        }
        #expect(context.leftoverCapacityFrames >= 100)
        var out = [Int32](repeating: 0, count: 200)
        let n = out.withUnsafeMutableBufferPointer { context.drainLeftover(into: $0.baseAddress!, maxFrames: 100) }
        #expect(n == 100)
        #expect(out == (0..<100).flatMap { [left[$0], right[$0]] })
        #expect(context.decodeErrorCount == 0)
    }

    @Test func framesThatContradictStreamInfoBecomeSilenceAndCountAsErrors() {
        let context = FlacDecodeContext(discardsOutput: false)
        context.configure(channels: 2, bitsPerSample: 16, maxBlockSize: 16)
        let mono = [Int32](repeating: 7, count: 16)
        mono.withUnsafeBufferPointer { m in
            let planes: [UnsafePointer<Int32>?] = [m.baseAddress]
            planes.withUnsafeBufferPointer {
                context.receive(blockSize: 16, channels: 1, bitsPerSample: 16, planes: $0.baseAddress!)
            }
        }
        var out = [Int32](repeating: 1, count: 32)
        let n = out.withUnsafeMutableBufferPointer { context.drainLeftover(into: $0.baseAddress!, maxFrames: 16) }
        #expect(n == 16 && out.allSatisfy { $0 == 0 })
        #expect(context.decodeErrorCount == 1)
    }
}
