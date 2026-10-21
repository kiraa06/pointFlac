import Foundation

/// A real FLAC file of a generated stereo sine, written here (verbatim subframes, CRCs included) so loudness tests
/// need no bundled audio and can run long enough for the 400 ms gating blocks of EBU R128. 16-bit, 48 kHz.
enum ToneFlac {
    static let rate = 48_000
    static let block = 4096
    /// Whole blocks, so every frame has the same header: about 20 seconds.
    static let frames = block * 235

    /// The samples a file made with `rmsDbfs` holds, interleaved L R, as the decoder will give them back (16-bit
    /// quantised, scaled to ±1).
    static func samples(rmsDbfs: Double, hz: Double = 1000) -> [Int16] {
        let amp = pow(10, rmsDbfs / 20) * 2.0.squareRoot() * 32768
        var out = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Int16(max(-32768, min(32767, (amp * sin(2 * .pi * hz * Double(i) / Double(rate))).rounded())))
            out[2 * i] = v
            out[2 * i + 1] = v
        }
        return out
    }

    static func floats(_ samples: [Int16]) -> [Float] { samples.map { Float($0) / 32768 } }

    static func write(to url: URL, rmsDbfs: Double, tags: [(String, String)]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try make(samples(rmsDbfs: rmsDbfs), tags: tags).write(to: url)
    }

    static func make(_ samples: [Int16], tags: [(String, String)]) -> Data {
        var out: [UInt8] = [0x66, 0x4C, 0x61, 0x43]
        // STREAMINFO: block sizes, frame sizes (unknown), 48000 Hz / 2 channels / 16 bits / total frames, no MD5.
        var info: [UInt8] = TaggedFlac.be32(block).suffix(2) + TaggedFlac.be32(block).suffix(2) + [0, 0, 0, 0, 0, 0]
        let packed: UInt64 = UInt64(rate) << 44 | UInt64(1) << 41 | UInt64(15) << 36 | UInt64(frames)
        for shift in stride(from: 56, through: 0, by: -8) {
            info.append(UInt8(truncatingIfNeeded: packed >> UInt64(shift)))
        }
        info += [UInt8](repeating: 0, count: 16)
        out += [0x00, 0x00, 0x00, 0x22] + info
        let comment = TaggedFlac.comment(vendor: "pointFlac tests", tags: tags)
        let n = comment.count
        out += [0x84, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + comment
        for index in 0..<(frames / block) {
            var frame: [UInt8] = [0xFF, 0xF8, 0xCA, 0x18]  // fixed size, 4096, 48 kHz, stereo, 16 bits
            frame += utf8(index)
            frame.append(crc8(frame))
            for channel in 0..<2 {
                frame.append(0x02)  // verbatim subframe
                for i in 0..<block {
                    let v = UInt16(bitPattern: samples[(index * block + i) * 2 + channel])
                    frame += [UInt8(v >> 8), UInt8(v & 0xFF)]
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
