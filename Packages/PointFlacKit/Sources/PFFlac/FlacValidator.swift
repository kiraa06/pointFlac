import Foundation

/// Why a file was refused admission as FLAC.
public enum FlacRejection: Error, Equatable, Sendable {
    case notFlacName
    case badMagic
    case badID3
    case missingStreamInfo
    case invalidStreamInfo(String)
    case tooManyBlocks
    case blockTooLarge
    case badFrameHeader
    case frameCRCMismatch
    case truncated
    case unreadable
}

/// Minimal sequential byte source the validator runs over.
protocol FlacByteReader {
    /// The real file name, used for the `.flac` rule.
    var name: String { get }
    /// Total size in bytes.
    var size: Int { get }
    /// Reads up to `count` bytes; returns fewer only at end of file.
    mutating func read(_ count: Int) throws(FlacRejection) -> [UInt8]
    /// Advances by `count` bytes without reading them.
    mutating func skip(_ count: Int) throws(FlacRejection)
}

struct FileHandleReader: FlacByteReader {
    let name: String
    let size: Int
    private let handle: FileHandle

    init(url: URL) throws(FlacRejection) {
        do {
            handle = try FileHandle(forReadingFrom: url)
            size = Int(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
        } catch {
            throw .unreadable
        }
        name = url.lastPathComponent
    }

    func close() { try? handle.close() }

    mutating func read(_ count: Int) throws(FlacRejection) -> [UInt8] {
        do {
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        } catch {
            throw .unreadable
        }
    }

    mutating func skip(_ count: Int) throws(FlacRejection) {
        do {
            let position = try handle.offset()
            try handle.seek(toOffset: position + UInt64(count))
        } catch {
            throw .unreadable
        }
    }
}

public enum FlacValidator {
    public static let maxBlocks = 1024
    public static let maxBlockBytes = 16 * 1024 * 1024

    /// Decides whether the file is real FLAC by inspecting only its metadata and first frame header.
    public static func validate(fileAt url: URL) throws(FlacRejection) -> FlacStreamInfo {
        // Cheap name check first so wrongly named files are never opened.
        guard url.lastPathComponent.lowercased().hasSuffix(".flac") else { throw .notFlacName }
        var reader = try FileHandleReader(url: url)
        defer { reader.close() }
        return try validate(reader: &reader)
    }

    static func validate<R: FlacByteReader>(reader: inout R) throws(FlacRejection) -> FlacStreamInfo {
        try validate(reader: &reader, wants: { _ in false }, collect: { _, _ in })
    }

    /// Validates like `validate(reader:)`, and hands the bodies of the blocks `wants` selects (by type) to
    /// `collect`. Unselected blocks are skipped by seeking, never read.
    static func validate<R: FlacByteReader>(
        reader: inout R, wants: (UInt8) -> Bool, collect: (UInt8, [UInt8]) -> Void
    ) throws(FlacRejection) -> FlacStreamInfo {
        guard reader.name.lowercased().hasSuffix(".flac") else { throw .notFlacName }

        var offset = 0
        func take(_ count: Int, from reader: inout R) throws(FlacRejection) -> [UInt8] {
            let bytes = try reader.read(count)
            offset += bytes.count
            guard bytes.count == count else { throw .truncated }
            return bytes
        }
        func skip(_ count: Int, from reader: inout R) throws(FlacRejection) {
            guard offset + count <= reader.size else { throw .truncated }
            try reader.skip(count)
            offset += count
        }

        var magic = try take(4, from: &reader)
        if magic[0] == 0x49, magic[1] == 0x44, magic[2] == 0x33 {  // "ID3"
            let rest = try take(6, from: &reader)
            let header = [magic[3]] + rest
            // header = version major, revision, flags, 4 synchsafe size bytes
            guard header[0] != 0xFF, header[1] != 0xFF else { throw .badID3 }
            guard header[3...6].allSatisfy({ $0 < 0x80 }) else { throw .badID3 }
            var tagSize = 0
            for b in header[3...6] { tagSize = (tagSize << 7) | Int(b) }
            if header[2] & 0x10 != 0 { tagSize += 10 }  // footer
            try skip(tagSize, from: &reader)
            magic = try take(4, from: &reader)
        }
        guard magic == [0x66, 0x4C, 0x61, 0x43] else { throw .badMagic }  // "fLaC"

        var info: FlacStreamInfo?
        var blockCount = 0
        while true {
            let header = try take(4, from: &reader)
            blockCount += 1
            guard blockCount <= maxBlocks else { throw .tooManyBlocks }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if blockCount == 1 {
                guard type == 0 else { throw .missingStreamInfo }
                guard length == 34 else { throw .invalidStreamInfo("STREAMINFO length \(length), expected 34") }
                info = try parseStreamInfo(try take(34, from: &reader))
            } else {
                guard length <= maxBlockBytes else { throw .blockTooLarge }
                if wants(type) {
                    guard offset + length <= reader.size else { throw .truncated }
                    collect(type, try take(length, from: &reader))
                } else {
                    try skip(length, from: &reader)
                }
            }
            if isLast { break }
        }
        guard let info else { throw .missingStreamInfo }

        try checkFirstFrameHeader(try reader.read(16))
        return info
    }

    private static func parseStreamInfo(_ b: [UInt8]) throws(FlacRejection) -> FlacStreamInfo {
        func be(_ range: Range<Int>) -> Int { b[range].reduce(0) { $0 << 8 | Int($1) } }
        let minBlock = be(0..<2)
        let maxBlock = be(2..<4)
        let minFrame = be(4..<7)
        let maxFrame = be(7..<10)
        let packed = b[10..<18].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let sampleRate = Int(packed >> 44)
        let channels = Int((packed >> 41) & 0x7) + 1
        let bits = Int((packed >> 36) & 0x1F) + 1
        let total = Int64(packed & 0xF_FFFF_FFFF)

        guard minBlock >= 16 else { throw .invalidStreamInfo("min block size \(minBlock) < 16") }
        guard maxBlock >= minBlock else { throw .invalidStreamInfo("max block size < min block size") }
        guard maxFrame == 0 || minFrame <= maxFrame else { throw .invalidStreamInfo("min frame size > max frame size") }
        guard (1...655_350).contains(sampleRate) else { throw .invalidStreamInfo("sample rate \(sampleRate)") }
        guard (4...32).contains(bits) else { throw .invalidStreamInfo("bits per sample \(bits)") }

        return FlacStreamInfo(
            minBlockSize: minBlock, maxBlockSize: maxBlock, minFrameSize: minFrame, maxFrameSize: maxFrame,
            sampleRate: sampleRate, channels: channels, bitsPerSample: bits, totalFrames: total,
            md5: Array(b[18..<34]))
    }

    /// Validates the first frame header: sync, reserved codes, coded number, extension bytes and CRC-8.
    private static func checkFirstFrameHeader(_ h: [UInt8]) throws(FlacRejection) {
        guard h.count >= 6 else { throw .truncated }
        guard h[0] == 0xFF, h[1] & 0xFE == 0xF8 else { throw .badFrameHeader }
        let blockCode = h[2] >> 4
        let rateCode = h[2] & 0x0F
        let channelCode = h[3] >> 4
        let sizeCode = (h[3] >> 1) & 0x07
        guard blockCode != 0, rateCode != 15, channelCode <= 10, sizeCode != 3, h[3] & 1 == 0 else {
            throw .badFrameHeader
        }

        // UTF-8 style coded frame/sample number.
        let lead = h[4]
        let extra: Int
        switch lead {
        case 0x00...0x7F: extra = 0
        case 0xC0...0xDF: extra = 1
        case 0xE0...0xEF: extra = 2
        case 0xF0...0xF7: extra = 3
        case 0xF8...0xFB: extra = 4
        case 0xFC...0xFD: extra = 5
        case 0xFE: extra = 6
        default: throw .badFrameHeader
        }
        var end = 5 + extra
        guard h.count > end else { throw .truncated }
        guard h[5..<end].allSatisfy({ $0 & 0xC0 == 0x80 }) else { throw .badFrameHeader }

        switch blockCode {
        case 6: end += 1
        case 7: end += 2
        default: break
        }
        switch rateCode {
        case 12: end += 1
        case 13, 14: end += 2
        default: break
        }
        guard h.count > end else { throw .truncated }

        var crc: UInt8 = 0
        for byte in h[0..<end] {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        guard crc == h[end] else { throw .frameCRCMismatch }
    }
}
