import Foundation

/// A real FLAC file of a generated sine, written here (verbatim subframes, CRCs included) so loudness tests need no
/// bundled audio and run long enough for several 400 ms gating blocks of EBU R128: about 3.2 seconds.
enum ToneFlac {
    struct Spec {
        var rate = 48_000
        var bits = 16
        var channels = 2
        static let block = 4096

        /// Whole blocks, so every frame has the same header.
        var frames: Int { Self.block * Int((3.2 * Double(rate) / Double(Self.block)).rounded(.up)) }
        static let stereo16 = Spec()
    }

    /// The samples of a sine at `rmsDbfs` (per channel), interleaved, in native range, as the decoder gives them back.
    static func samples(rmsDbfs: Double, hz: Double = 1000, _ spec: Spec = .stereo16) -> [Int32] {
        let full = pow(2.0, Double(spec.bits - 1))
        let amp = pow(10, rmsDbfs / 20) * 2.0.squareRoot() * full
        var out = [Int32](repeating: 0, count: spec.frames * spec.channels)
        for i in 0..<spec.frames {
            let v = Int32(
                max(-full, min(full - 1, (amp * sin(2 * .pi * hz * Double(i) / Double(spec.rate))).rounded())))
            for c in 0..<spec.channels { out[i * spec.channels + c] = v }
        }
        return out
    }

    static func floats(_ samples: [Int32], _ spec: Spec = .stereo16) -> [Float] {
        let full = Float(pow(2.0, Double(spec.bits - 1)))
        return samples.map { Float($0) / full }
    }

    static func write(
        to url: URL, rmsDbfs: Double, _ spec: Spec = .stereo16, tags: [(String, String)]
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try make(samples(rmsDbfs: rmsDbfs, spec), spec, tags: tags).write(to: url)
    }

    static func make(_ samples: [Int32], _ spec: Spec, tags: [(String, String)]) -> Data {
        let block = Spec.block
        var out: [UInt8] = [0x66, 0x4C, 0x61, 0x43]
        // STREAMINFO: block sizes, frame sizes (unknown), rate / channels / bits / total frames, no MD5.
        var info: [UInt8] = TaggedFlac.be32(block).suffix(2) + TaggedFlac.be32(block).suffix(2) + [0, 0, 0, 0, 0, 0]
        let packed: UInt64 =
            UInt64(spec.rate) << 44 | UInt64(spec.channels - 1) << 41 | UInt64(spec.bits - 1) << 36
            | UInt64(spec.frames)
        for shift in stride(from: 56, through: 0, by: -8) {
            info.append(UInt8(truncatingIfNeeded: packed >> UInt64(shift)))
        }
        info += [UInt8](repeating: 0, count: 16)
        out += [0x00, 0x00, 0x00, 0x22] + info
        let comment = TaggedFlac.comment(vendor: "pointFlac tests", tags: tags)
        let n = comment.count
        out += [0x84, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + comment
        // Any other rate is 0b0000: the rate is in STREAMINFO.
        let rateCode: UInt8 = spec.rate == 96_000 ? 0b1011 : spec.rate == 48_000 ? 0b1010 : 0
        let sizeCode: UInt8 = spec.bits == 24 ? 0b110 : 0b100
        let bytes = spec.bits / 8
        for index in 0..<(spec.frames / block) {
            // Fixed size, 4096 frames, rate, independent channels, bit depth.
            var frame: [UInt8] = [0xFF, 0xF8, 0xC0 | rateCode, UInt8(spec.channels - 1) << 4 | sizeCode << 1]
            frame += utf8(index)
            frame.append(crc8(frame))
            for channel in 0..<spec.channels {
                frame.append(0x02)  // verbatim subframe
                for i in 0..<block {
                    let v = UInt32(bitPattern: samples[(index * block + i) * spec.channels + channel])
                    for byte in stride(from: bytes - 1, through: 0, by: -1) {
                        frame.append(UInt8(truncatingIfNeeded: v >> UInt32(8 * byte)))
                    }
                }
            }
            let crc = crc16(frame)
            out += frame + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        }
        return Data(out)
    }

    private static func utf8(_ n: Int) -> [UInt8] {
        n < 128 ? [UInt8(n)] : [UInt8(0xC0 | n >> 6), UInt8(0x80 | n & 0x3F)]
    }

    private static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? crc << 1 ^ 0x07 : crc << 1 }
        }
        return crc
    }

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x8005 : crc << 1 }
        }
        return crc
    }
}
