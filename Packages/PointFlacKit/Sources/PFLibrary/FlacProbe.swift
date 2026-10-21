import Foundation
import PFCore
import PFFlac

/// What the library reads from one FLAC file: its tags, its identity and its cover.
struct ProbedTrack: Sendable, Equatable {
    var contentID: String
    var title: String?
    var artist: String
    var albumArtist: String
    var album: String
    var compilation: Bool
    var discNumber: Int?
    var trackNumber: Int?
    var year: Int?
    var format: AudioFormat
    var totalFrames: Int64
    /// The front cover's image bytes (type 3, else the first picture), at most `ArtworkStore.maxSourceBytes`.
    var cover: Data?
    /// ReplayGain tags: gains in dB, peaks linear. Nil when absent or not plausible (`FlacMetadata`).
    var trackGainDb: Double?
    var trackPeak: Double?
    var albumGainDb: Double?
    var albumPeak: Double?
}

/// Reads a library file in two passes: `FlacMetadataReader` validates it against the admission rule (spec §5.3) and
/// reads its tags with pictures skipped; then one walk over the block headers finds the cover and the audio for
/// `ContentIdentity`.
///
/// The cover is read here rather than with `includePictures: true`, which would read every PICTURE block: a hostile
/// file may carry a thousand 16 MiB pictures. This reads at most two bodies, the first front cover and the first
/// picture of any type, each within the artwork bound.
enum FlacProbe {
    static func probe(fileAt url: URL) -> Result<ProbedTrack, FlacRejection> {
        let metadata: FlacMetadata
        do throws(FlacRejection) {
            metadata = try FlacMetadataReader.read(fileAt: url, includePictures: false)
        } catch {
            return .failure(error)
        }
        guard let contentID = ContentIdentity.compute(fileAt: url) else { return .failure(.unreadable) }
        let compilation = metadata.tags["COMPILATION"]?.first.map { $0.trimmingCharacters(in: .whitespaces) == "1" }
        return .success(
            ProbedTrack(
                contentID: contentID, title: TagText.clean(metadata.title),
                artist: TagText.clean(metadata.artist) ?? "", albumArtist: TagText.clean(metadata.albumArtist) ?? "",
                album: TagText.clean(metadata.album) ?? "", compilation: compilation ?? false,
                discNumber: metadata.discNumber.flatMap(plausible),
                trackNumber: metadata.trackNumber.flatMap(plausible),
                year: metadata.year.flatMap(plausibleYear), format: metadata.streamInfo.format,
                totalFrames: metadata.streamInfo.totalFrames,
                cover: cover(fileAt: url), trackGainDb: metadata.trackGainDb, trackPeak: metadata.trackPeak,
                albumGainDb: metadata.albumGainDb, albumPeak: metadata.albumPeak))
    }

    /// A DATE of "0000" or "9999" is a placeholder, not a year.
    private static func plausibleYear(_ year: Int) -> Int? { (1000...2100).contains(year) ? year : nil }

    /// Disc and track numbers from tags are free text; anything outside 0…9999 is noise, not an order.
    private static func plausible(_ n: Int) -> Int? { (0...9999).contains(n) ? n : nil }

    /// The front cover's image data, or the first picture's when there is no front cover.
    static func cover(fileAt url: URL) -> Data? {
        var bytesRead = 0
        return cover(fileAt: url, bytesRead: &bytesRead)
    }

    /// As `cover(fileAt:)`, counting the bytes read, for the bound test. Each PICTURE block's 4-byte type is read
    /// first; its body is read only for the first front cover, or as the fallback while there is none yet. Every
    /// other picture is skipped by seeking, so a file with a thousand 16 MiB back covers costs at most two bodies.
    static func cover(fileAt url: URL, bytesRead: inout Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var count = 0
        defer { bytesRead = count }
        func read(_ n: Int) -> [UInt8]? {
            guard let data = try? handle.read(upToCount: n), data.count == n else { return nil }
            count += n
            return [UInt8](data)
        }
        func skip(_ n: Int) -> Bool {
            guard let offset = try? handle.offset() else { return false }
            return (try? handle.seek(toOffset: offset + UInt64(n))) != nil
        }
        guard var magic = read(4) else { return nil }
        if magic[0] == 0x49, magic[1] == 0x44, magic[2] == 0x33 {
            guard let rest = read(6) else { return nil }
            var size = 0
            for byte in rest[2...5] { size = size << 7 | Int(byte & 0x7F) }
            if rest[1] & 0x10 != 0 { size += 10 }
            guard skip(size), let next = read(4) else { return nil }
            magic = next
        }
        guard magic == [0x66, 0x4C, 0x61, 0x43] else { return nil }
        var fallback: Data?
        for _ in 0..<FlacValidator.maxBlocks {
            guard let header = read(4) else { break }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let isLast = header[0] & 0x80 != 0
            if header[0] & 0x7F == 6, length >= 4, length <= ArtworkStore.maxSourceBytes + 1024,
                let typeBytes = read(4)
            {
                let type =
                    Int(typeBytes[0]) << 24 | Int(typeBytes[1]) << 16 | Int(typeBytes[2]) << 8 | Int(typeBytes[3])
                if type == 3 || fallback == nil {
                    guard let rest = read(length - 4) else { break }
                    if let picture = parsePicture(typeBytes + rest) {
                        if picture.type == 3 { return picture.data }
                        fallback = picture.data
                    }
                } else if !skip(length - 4) {
                    break
                }
            } else if !skip(length) {
                break
            }
            if isLast { break }
        }
        return fallback
    }

    /// A PICTURE block body (big-endian lengths, spec'd by the FLAC format). Nil when any length overruns the body.
    static func parsePicture(_ b: [UInt8]) -> (type: Int, data: Data)? {
        var pos = 0
        func u32() -> Int? {
            guard pos + 4 <= b.count else { return nil }
            defer { pos += 4 }
            return Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
        }
        func skipBytes(_ n: Int) -> Bool {
            guard n >= 0, n <= b.count - pos else { return false }
            pos += n
            return true
        }
        guard let type = u32(), let mimeLength = u32(), skipBytes(mimeLength), let descriptionLength = u32(),
            skipBytes(descriptionLength), skipBytes(16), let dataLength = u32(), dataLength > 0,
            dataLength <= b.count - pos
        else { return nil }
        return (type, Data(b[pos..<pos + dataLength]))
    }
}
