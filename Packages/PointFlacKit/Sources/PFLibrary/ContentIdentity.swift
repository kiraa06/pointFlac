import CryptoKit
import Foundation

/// A FLAC file's identity, independent of where it is and of its tags (spec §5.4).
///
/// SHA-256 over the 34-byte STREAMINFO body and the first 64 KiB of audio frames, truncated to 128 bits (hex). The
/// audio is what makes the file; the metadata blocks before it change whenever a tag is edited, and the path changes
/// on every rename or move. Hashing only the start keeps a 10k-file scan cheap (one 64 KiB read per new file), and
/// STREAMINFO carries the total frame count and, from most encoders, the MD5 of the whole decoded stream, so two
/// different recordings sharing their first 64 KiB of frames still differ.
///
/// Two bit-identical files (the same rip in an album and a compilation) share an identity. The library keeps both,
/// giving the second a path-derived ID (`LibraryScanner`).
enum ContentIdentity {
    static let audioPrefixBytes = 64 * 1024

    /// Nil when the file cannot be read as FLAC up to its first frame. Callers validate first, so nil means the file
    /// changed under them.
    static func compute(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func read(_ count: Int) -> [UInt8]? {
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
        func skip(_ count: Int) -> Bool {
            guard let offset = try? handle.offset() else { return false }
            return (try? handle.seek(toOffset: offset + UInt64(count))) != nil
        }

        guard var magic = read(4) else { return nil }
        if magic[0] == 0x49, magic[1] == 0x44, magic[2] == 0x33 {  // "ID3", as FlacValidator allows
            guard let rest = read(6) else { return nil }
            var size = 0
            for byte in rest[2...5] { size = size << 7 | Int(byte & 0x7F) }
            if rest[1] & 0x10 != 0 { size += 10 }
            guard skip(size), let next = read(4) else { return nil }
            magic = next
        }
        guard magic == [0x66, 0x4C, 0x61, 0x43] else { return nil }

        var streamInfo: [UInt8]?
        // The validator allows 1,024 blocks; the bound keeps a file that changed since from looping here.
        for _ in 0..<1024 {
            guard let header = read(4) else { return nil }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if streamInfo == nil {
                guard header[0] & 0x7F == 0, length == 34, let body = read(34) else { return nil }
                streamInfo = body
            } else if !skip(length) {
                return nil
            }
            if header[0] & 0x80 != 0 { break }
        }
        guard let streamInfo, let audio = try? handle.read(upToCount: audioPrefixBytes), !audio.isEmpty else {
            return nil
        }
        var hasher = SHA256()
        hasher.update(data: streamInfo)
        hasher.update(data: audio)
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
