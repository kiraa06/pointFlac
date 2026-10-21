import ImageIO
import SwiftUI
import UIKit

/// An album's sleeve: its cover art when it has any, else a generated sleeve in the album's palette (the mockups'
/// sun-and-sea motif). Square; the caller sizes and clips it.
///
/// Why the art arrives asynchronously: decoding a cover in `body` stalls the main thread for milliseconds per sleeve,
/// which a crate flick at 120 Hz cannot afford. The generated sleeve shows until `ArtworkLoader` has a thumbnail at
/// about twice the display size; a cache hit shows at once, with no flash.
struct ArtworkView: View {
    let albumID: String
    let artwork: Data?
    /// The longest side to decode, in pixels: ≈300 for sleeves and rows, more for the Cover and the platter.
    var pixels: Int = 300
    @State private var image: UIImage?

    init(albumID: String, artwork: Data?, pixels: Int = 300) {
        self.albumID = albumID
        self.artwork = artwork
        self.pixels = pixels
        _image = State(initialValue: ArtworkLoader.shared.cached(albumID, pixels: pixels))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().interpolation(.medium).scaledToFill()
            } else {
                GeneratedSleeve(palette: ArtPalette(seed: albumID))
            }
        }
        .task(id: "\(albumID)|\(pixels)") {
            guard let artwork else {
                image = nil
                return
            }
            image = await ArtworkLoader.shared.image(albumID, data: artwork, pixels: pixels)
        }
    }
}

/// The mockups' generated art: a diagonal gradient with a sun and a sea disc. Pure shapes, so it costs nothing to
/// cache and draws crisply at any size.
struct GeneratedSleeve: View {
    let palette: ArtPalette

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: palette.base, location: 0), .init(color: palette.deep, location: 0.55),
                        .init(color: palette.night, location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(palette.sun).frame(width: s * 0.28, height: s * 0.28)
                    .position(x: s * 0.3, y: s * 0.3)
                Circle().fill(palette.sea).frame(width: s * 0.44, height: s * 0.44)
                    .position(x: s * 0.7, y: s * 0.65)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Decodes cover art off the main thread with ImageIO, straight to a thumbnail of the size asked for, and keeps the
/// results in a bounded cache (spec §8: ≤ 150 MB of decoded images), byte-costed. Art that will not decode is
/// remembered too, so a broken cover is tried once, not on every appearance.
final class ArtworkLoader: @unchecked Sendable {
    static let shared = ArtworkLoader()

    /// `NSCache` is thread-safe; that is why the class can be shared across tasks.
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()
    private let failures = NSCache<NSString, NSNull>()

    private static func key(_ id: String, _ pixels: Int) -> NSString { "\(id)|\(pixels)" as NSString }

    /// A decoded thumbnail, if one is cached. Cheap enough for a view's init.
    func cached(_ id: String, pixels: Int) -> UIImage? {
        images.object(forKey: Self.key(id, pixels))
    }

    /// The thumbnail for `id`, decoding it off the main thread on a miss. Nil when the data is not an image.
    func image(_ id: String, data: Data, pixels: Int) async -> UIImage? {
        let key = Self.key(id, pixels)
        if let hit = images.object(forKey: key) { return hit }
        if failures.object(forKey: key) != nil { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(data, pixels: pixels) }.value
        guard let decoded else {
            failures.setObject(NSNull(), forKey: key)
            return nil
        }
        let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
        images.setObject(decoded, forKey: key, cost: cost)
        return decoded
    }

    /// Warms the cache ahead of need: the crate's front record, so the hand-off's disc and the platter have their art
    /// before the tap (spec §4.5: textures are ready before the tap).
    func prefetch(_ id: String, data: Data?, pixels: [Int]) {
        guard let data else { return }
        for size in pixels where cached(id, pixels: size) == nil {
            Task.detached(priority: .utility) { _ = await self.image(id, data: data, pixels: size) }
        }
    }

    private static func decode(_ data: Data, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}
