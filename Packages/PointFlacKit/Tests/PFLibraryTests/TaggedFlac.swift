import CoreGraphics
import Foundation
import ImageIO
import PFTestSupport
import UniformTypeIdentifiers

/// Real FLAC files with made-up tags: a fixture's STREAMINFO and audio frames, with its metadata blocks replaced by a
/// VORBIS_COMMENT (and optionally a PICTURE) built here. The audio is untouched, so the file still passes the admission
/// rule and decodes, and two files made from one fixture share a content identity.
enum TaggedFlac {
    static func make(
        from fixture: String, tags: [(String, String)] = [], vendor: String = "pointFlac tests",
        rawComment: [UInt8]? = nil, picture: Data? = nil, pictureType: Int = 3, extraPictures: Int = 0
    ) throws -> Data {
        let bytes = [UInt8](try Data(contentsOf: Fixtures.url(Fixtures.named(fixture))))
        precondition(bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]), "fixture must start with fLaC")
        var position = 4
        var streamInfo: [UInt8] = []
        while true {
            let header = Array(bytes[position..<position + 4])
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if header[0] & 0x7F == 0 { streamInfo = Array(bytes[position + 4..<position + 4 + length]) }
            position += 4 + length
            if header[0] & 0x80 != 0 { break }
        }
        let audio = bytes[position...]

        var blocks: [(type: UInt8, body: [UInt8])] = [(0, streamInfo)]
        blocks.append((4, rawComment ?? comment(vendor: vendor, tags: tags)))
        if let picture {
            for index in 0...extraPictures {
                blocks.append((6, pictureBlock(type: index == 0 ? pictureType : 0, data: picture)))
            }
        }
        var out: [UInt8] = [0x66, 0x4C, 0x61, 0x43]
        for (index, block) in blocks.enumerated() {
            let last: UInt8 = index == blocks.count - 1 ? 0x80 : 0
            let n = block.body.count
            out += [last | block.type, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            out += block.body
        }
        out += audio
        return Data(out)
    }

    static func write(
        _ fixture: String, to url: URL, tags: [(String, String)] = [], picture: Data? = nil,
        rawComment: [UInt8]? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try make(from: fixture, tags: tags, rawComment: rawComment, picture: picture).write(to: url)
    }

    static func comment(vendor: String, tags: [(String, String)]) -> [UInt8] {
        var body = le32(vendor.utf8.count) + Array(vendor.utf8) + le32(tags.count)
        for (key, value) in tags {
            let entry = Array("\(key)=\(value)".utf8)
            body += le32(entry.count) + entry
        }
        return body
    }

    static func pictureBlock(type: Int, data: Data) -> [UInt8] {
        let mime = Array("image/png".utf8)
        return be32(type) + be32(mime.count) + mime + be32(0) + be32(8) + be32(8) + be32(24) + be32(0)
            + be32(data.count) + [UInt8](data)
    }

    static func le32(_ n: Int) -> [UInt8] {
        [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]
    }

    static func be32(_ n: Int) -> [UInt8] {
        [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    }

    /// A solid-colour PNG, `size` pixels square.
    static func png(size: Int = 64, red: CGFloat = 0.8) -> Data {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
