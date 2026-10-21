import SwiftUI
import UIKit

/// An album's sleeve: its cover art when it has any, else a generated sleeve in the album's palette (the mockups'
/// sun-and-sea motif). Square; the caller sizes and clips it.
struct ArtworkView: View {
    let albumID: String
    let artwork: Data?

    var body: some View {
        if let image = ArtworkCache.shared.image(for: albumID, data: artwork) {
            Image(uiImage: image).resizable().interpolation(.medium).scaledToFill()
        } else {
            GeneratedSleeve(palette: ArtPalette(seed: albumID))
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

/// Decoded cover art, bounded (spec §8: a bounded image cache). Decoding happens once per album; `NSCache` evicts
/// under memory pressure.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    /// Reads an album's cover when its sleeve is first drawn and the card carries none (`RealLibrary`): covers are
    /// loaded lazily, never all at once.
    var loader: ((String) -> Data?)?

    func image(for id: String, data: Data?) -> UIImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        guard let data = data ?? loader?(id) else { return nil }
        guard let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 800, height: 800)) else {
            return nil
        }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: id as NSString, cost: cost)
        return image
    }
}
