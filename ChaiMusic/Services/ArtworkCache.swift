import Foundation
import UIKit
import ImageIO

struct ArtworkThumbnail: @unchecked Sendable {
    let image: UIImage
    let tint: UIColor
}

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, CachedArtwork>()
    private final class CachedArtwork: NSObject {
        let value: ArtworkThumbnail
        init(_ value: ArtworkThumbnail) { self.value = value }
    }
    init() { cache.totalCostLimit = 40 * 1024 * 1024; cache.countLimit = 250 }

    func thumbnail(url: URL, pixels: Int) -> ArtworkThumbnail? {
        let bounded = min(1200, max(80, pixels))
        let key = "\(url.path)|\(bounded)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: bounded,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let tint: UIColor = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return UIColor(red: 0.24, green: 0.42, blue: 0.31, alpha: 1)
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return UIColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
                           blue: CGFloat(bytes[2]) / 255, alpha: 1)
        }
        let result = ArtworkThumbnail(image: UIImage(cgImage: image), tint: tint)
        cache.setObject(CachedArtwork(result), forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
}
