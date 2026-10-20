import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Album art, extracted once and kept on disk at the size the UI uses (spec §5.4).
///
/// Each distinct embedded cover is stored once, under the SHA-256 of its bytes, so the twelve tracks of an album that
/// all embed the same JPEG cost one file. The stored image is downsampled with ImageIO to `sleevePixels` on its long
/// side and re-encoded as JPEG: the UI never decodes a 4000 px scan to draw a 300 pt sleeve, and the decoded-image
/// cost stays predictable.
///
/// Images are untrusted input (spec §5.8): anything over `maxSourceBytes`, or that claims more than `maxSourcePixels`,
/// is refused before ImageIO decodes it, and so is anything ImageIO cannot read. A refused cover just means the album
/// shows no art.
///
/// Not thread-safe: the library calls it only from its own serial queue. Reads for the UI go through `data(for:)`,
/// which only reads a finished file, and is safe from any thread.
final class ArtworkStore: @unchecked Sendable {
    static let sleevePixels = 600
    static let maxSourceBytes = 16 * 1024 * 1024
    static let maxSourcePixels = 64_000_000

    let folder: URL
    /// Decoded-file bytes for the UI, bounded by bytes, not count (spec §5.4: Runout's out-of-memory risk).
    private let cache = NSCache<NSString, NSData>()

    init(folder: URL, cacheBytes: Int = 32 * 1024 * 1024) {
        self.folder = folder
        cache.totalCostLimit = cacheBytes
    }

    /// Stores `image` (JPEG, PNG or anything ImageIO reads) and returns its ID; nil when it is refused.
    func store(_ image: Data) -> String? {
        guard !image.isEmpty, image.count <= Self.maxSourceBytes else { return nil }
        let id = SHA256.hash(data: image).prefix(16).map { String(format: "%02x", $0) }.joined()
        let destination = url(for: id)
        if FileManager.default.fileExists(atPath: destination.path) { return id }
        guard let sleeve = Self.downsample(image) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try sleeve.write(to: destination, options: .atomic)
        } catch {
            return nil
        }
        return id
    }

    /// The stored sleeve image (JPEG), or nil when there is none. Cached in memory up to the byte limit.
    func data(for id: String) -> Data? {
        guard Self.isValidID(id) else { return nil }
        if let cached = cache.object(forKey: id as NSString) { return cached as Data }
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        cache.setObject(data as NSData, forKey: id as NSString, cost: data.count)
        return data
    }

    func url(for id: String) -> URL {
        folder.appending(path: "\(id).jpg")
    }

    /// Deletes every stored image whose ID is not in `keep`: covers of tracks that left the library.
    func removeAll(except keep: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".jpg") {
            let id = String(name.dropLast(4))
            if !keep.contains(id) {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
                cache.removeObject(forKey: id as NSString)
            }
        }
    }

    /// An ID is 32 lowercase hex digits; anything else never reaches the file system.
    private static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func downsample(_ image: Data) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(image as CFData, sourceOptions),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width.multipliedReportingOverflow(by: height).partialValue <= maxSourcePixels,
            !width.multipliedReportingOverflow(by: height).overflow
        else { return nil }
        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: sleevePixels,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
