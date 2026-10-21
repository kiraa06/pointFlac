import Foundation

/// An embedded FLAC PICTURE block.
public struct FlacPicture: Sendable, Hashable {
    /// The ID3v2 APIC picture type; 3 is the front cover.
    public var type: Int
    public var mimeType: String
    public var data: Data

    public init(type: Int, mimeType: String, data: Data) {
        self.type = type
        self.mimeType = mimeType
        self.data = data
    }
}

/// Tags and pictures read from a FLAC file's metadata blocks.
public struct FlacMetadata: Sendable {
    public var streamInfo: FlacStreamInfo
    /// Vorbis comments, keyed by uppercased field name, values in file order.
    public var tags: [String: [String]]
    public var pictures: [FlacPicture]

    public init(streamInfo: FlacStreamInfo, tags: [String: [String]], pictures: [FlacPicture]) {
        self.streamInfo = streamInfo
        self.tags = tags
        self.pictures = pictures
    }

    private func first(_ key: String) -> String? { tags[key]?.first }

    public var title: String? { first("TITLE") }
    public var artist: String? { first("ARTIST") }
    public var album: String? { first("ALBUM") }
    public var albumArtist: String? { first("ALBUMARTIST") }
    public var trackNumber: Int? { first("TRACKNUMBER").flatMap(Self.leadingInt) }
    public var discNumber: Int? { first("DISCNUMBER").flatMap(Self.leadingInt) }

    public var year: Int? {
        guard let raw = first("DATE") ?? first("YEAR") else { return nil }
        let digits = raw.prefix(4)
        return digits.count == 4 && digits.allSatisfy(\.isASCIIDigit) ? Int(digits) : nil
    }

    public var trackGainDb: Double? { first("REPLAYGAIN_TRACK_GAIN").flatMap(Self.gain) }
    public var albumGainDb: Double? { first("REPLAYGAIN_ALBUM_GAIN").flatMap(Self.gain) }

    /// The front cover (type 3), else the first picture.
    public var frontCover: FlacPicture? { pictures.first { $0.type == 3 } ?? pictures.first }

    private static func leadingInt(_ s: String) -> Int? {
        let digits = s.drop { $0 == " " }.prefix { $0.isASCIIDigit }
        return Int(digits)
    }

    /// A ReplayGain value in dB, with or without its "dB" unit. `Double` also parses "nan" and "inf"; a gain that is
    /// not finite is treated as absent, like a missing tag, so playback can never scale audio by it (ledger T5).
    private static func gain(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasSuffix("db") { t = String(t.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        guard let value = Double(t), value.isFinite else { return nil }
        return value
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

public enum FlacMetadataReader {
    private static let vorbisComment: UInt8 = 4
    private static let picture: UInt8 = 6

    /// Validates the file, then reads its Vorbis comments and, when asked, its pictures.
    /// With `includePictures: false` PICTURE bodies are skipped by seeking and never read.
    public static func read(fileAt url: URL, includePictures: Bool) throws(FlacRejection) -> FlacMetadata {
        guard url.lastPathComponent.lowercased().hasSuffix(".flac") else { throw .notFlacName }
        var reader = try FileHandleReader(url: url)
        defer { reader.close() }

        var tags: [String: [String]] = [:]
        var pictures: [FlacPicture] = []
        let info = try FlacValidator.validate(
            reader: &reader,
            wants: { $0 == vorbisComment || (includePictures && $0 == picture) },
            collect: { type, body in
                if type == vorbisComment {
                    parseVorbisComment(body, into: &tags)
                } else if let p = parsePicture(body) {
                    pictures.append(p)
                }
            })
        return FlacMetadata(streamInfo: info, tags: tags, pictures: pictures)
    }

    /// Little-endian lengths. A malformed block keeps whatever parsed before the fault.
    static func parseVorbisComment(_ b: [UInt8], into tags: inout [String: [String]]) {
        var pos = 0
        func u32() -> Int? {
            guard pos + 4 <= b.count else { return nil }
            defer { pos += 4 }
            return Int(b[pos]) | Int(b[pos + 1]) << 8 | Int(b[pos + 2]) << 16 | Int(b[pos + 3]) << 24
        }
        guard let vendor = u32(), vendor <= b.count - pos else { return }
        pos += vendor
        guard let count = u32() else { return }
        for _ in 0..<count {
            guard let len = u32(), len <= b.count - pos else { return }
            let entry = String(decoding: b[pos..<pos + len], as: UTF8.self)
            pos += len
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<eq].uppercased()
            tags[key, default: []].append(String(entry[entry.index(after: eq)...]))
        }
    }

    /// Big-endian lengths. Returns nil for a malformed block.
    static func parsePicture(_ b: [UInt8]) -> FlacPicture? {
        var pos = 0
        func u32() -> Int? {
            guard pos + 4 <= b.count else { return nil }
            defer { pos += 4 }
            return Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
        }
        func bytes(_ n: Int) -> ArraySlice<UInt8>? {
            guard n <= b.count - pos else { return nil }
            defer { pos += n }
            return b[pos..<pos + n]
        }
        guard let type = u32(), let mimeLen = u32(), let mime = bytes(mimeLen),
            let descLen = u32(), bytes(descLen) != nil,
            u32() != nil, u32() != nil, u32() != nil, u32() != nil,  // width, height, depth, colours
            let dataLen = u32(), let data = bytes(dataLen)
        else { return nil }
        return FlacPicture(type: type, mimeType: String(decoding: mime, as: UTF8.self), data: Data(data))
    }
}
