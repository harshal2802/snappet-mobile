import UIKit

// The pixel edge for closet photos (wardrobe prompt 03). Sizing DECISIONS live in the pure
// `WardrobeImagePolicy`; this file only does the resizing, encoding, and off-main decoding, and
// owns the one bounded cache the tiles read through.
//
// Mirrors `Features/Feed/AssetPosterLoader.swift` (clips-feed perf, prompt 106) on purpose: same
// `NSCache` + `totalCostLimit` + decoded-bitmap cost shape, same `nonisolated` decode helpers.
// Two caches for the same job would drift.

/// Resize/encode/decode for garment photos, plus the shared decoded-image cache.
enum WardrobeImageStore {

    /// The two blobs a capture (or a migration pass) produces for one garment.
    struct Prepared {
        /// The display master — what the 240pt detail hero renders. `imageData` on the model.
        var display: Data
        /// The grid thumbnail — what all nine tile sites render. `thumbnailData` on the model.
        var thumbnail: Data
    }

    // MARK: - Producing

    /// Downscale `image` to the policy caps and encode both slots.
    ///
    /// `isCutout` decides the encoding, and it matters: a background-removed cut-out carries alpha,
    /// so it must stay PNG (JPEG would fill the transparent surround with black). A plain original
    /// has no alpha to lose and goes to JPEG, which is far smaller for photographic content.
    ///
    /// `nonisolated` and safe to call from a detached task — `UIGraphicsImageRenderer` and the
    /// encoders are not MainActor-bound, and this runs against 10 MB masters during migration.
    static func prepare(image: UIImage, isCutout: Bool) -> Prepared? {
        let display = resized(image, maxEdge: WardrobeImagePolicy.displayMaxEdge)
        let thumb = resized(image, maxEdge: WardrobeImagePolicy.thumbnailMaxEdge)
        guard let displayData = encode(display, isCutout: isCutout),
              let thumbData = encode(thumb, isCutout: isCutout) else { return nil }
        return Prepared(display: displayData, thumbnail: thumbData)
    }

    /// Aspect-preserving resize that **keeps alpha**. `format.opaque = false` is load-bearing:
    /// the default renderer format is opaque on some devices, which would flatten a cut-out's
    /// transparent surround to black.
    static func resized(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let target = WardrobeImagePolicy.fittedSize(for: image.size, maxEdge: maxEdge)
        guard target != image.size, target.width > 0, target.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1                    // target is already in pixels; no Retina multiplier
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func encode(_ image: UIImage, isCutout: Bool) -> Data? {
        isCutout ? image.pngData()
                 : image.jpegData(compressionQuality: WardrobeImagePolicy.jpegQuality)
    }

    /// Whether a stored blob is already within a cap — read via ImageIO so the migration can
    /// check 100 photos without decoding a single one of them into memory.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: w, height: h)
    }

    /// True when `data` decodes to something with an alpha channel — i.e. it is a cut-out and
    /// must be re-encoded as PNG. Cheap: reads ImageIO metadata, never decodes pixels.
    static func hasAlpha(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        return (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    // MARK: - Consuming

    /// Decode `data` at a size suitable for `pointHeight`, force-baked off the caller's thread.
    ///
    /// Uses ImageIO's thumbnail path rather than `UIImage(data:)` so the full-size bitmap is never
    /// materialized — the old code's actual failure mode. The result is a baked bitmap, so the
    /// scroll frame that draws it pays zero decode cost.
    static func decode(_ data: Data, pointHeight: CGFloat, scale: CGFloat = 3) -> UIImage? {
        let maxPixel = max(1, Int((pointHeight * scale).rounded()))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,      // decode here, not on the draw
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The one decoded-image cache for the closet. `@MainActor`-isolated so it is concurrency-safe
/// from the many `View`s that read it; the decode itself happens off-main and only the cache
/// touch comes back here.
@MainActor
enum WardrobeImageCache {
    /// Which stored blob a cached entry came from — the same item has a thumbnail AND a hero.
    enum Slot: String { case thumbnail, hero }

    /// Byte-cost bounded, so a big closet cannot pin memory: `NSCache` evicts under pressure and
    /// a re-request just re-decodes (the cold path). 60 MB holds a full grid of 320px thumbnails
    /// (~0.4 MB each) with room for a handful of heroes.
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 60 * 1024 * 1024
        return c
    }()

    private static func key(_ itemID: UUID, _ slot: Slot, _ generation: Int) -> NSString {
        "\(itemID.uuidString)#\(slot.rawValue)#\(generation)" as NSString
    }

    /// Fetch-or-decode. `generation` busts the entry when the underlying bytes change (an edit,
    /// or the migration rewriting the photo) without needing an explicit invalidation call —
    /// callers pass the blob's byte count, which changes whenever the image does.
    static func image(itemID: UUID, slot: Slot, data: Data,
                      pointHeight: CGFloat) async -> UIImage? {
        let k = key(itemID, slot, data.count)
        if let hit = cache.object(forKey: k) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) {
            WardrobeImageStore.decode(data, pointHeight: pointHeight)
        }.value
        guard let decoded else { return nil }
        cache.setObject(decoded, forKey: k,
                        cost: WardrobeImagePolicy.bitmapBytes(for: decoded.size,
                                                              scale: decoded.scale))
        return decoded
    }

    /// Drop everything — used after the migration rewrites the closet in bulk.
    static func removeAll() { cache.removeAllObjects() }
}
