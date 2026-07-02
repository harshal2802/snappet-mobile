import SwiftUI
import Photos
import UIKit
import AVFoundation

// MARK: - Shared PHAsset poster-frame loader (Reel edit list + Feed media tiles/carousel)
//
// The poster-frame load was copy-pasted in ReelView's `HighlightThumbnail` and the Feed's
// `ClipThumbnail` (same PHCachingImageManager, same continuation, same cache policy). It lives here
// once so the two callers can't drift on cache behavior; each view keeps its own distinct chrome
// (gradient + play affordance vs. neutral fill + zone badge) and only shares this loader.

/// Loads a PHAsset's poster frame through one shared `PHCachingImageManager` so scrolling a list/
/// carousel doesn't re-decode frames. On-device only (`isNetworkAccessAllowed = false`) and a single
/// high-quality callback (no degraded pass). Returns `nil` when the asset can't be read (limited
/// access, iCloud-only with network off, or the simulator) so the caller can fall back to its own
/// placeholder chrome.
///
/// `@MainActor`-isolated so the shared cache is concurrency-safe (each caller is a `View`).
@MainActor
enum AssetPosterLoader {
    private static let manager = PHCachingImageManager()

    /// - Parameter pointSize: the on-screen point size; the request targets 3× for Retina sharpness.
    static func poster(localIdentifier: String, pointSize: CGSize) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let target = CGSize(width: pointSize.width * 3, height: pointSize.height * 3)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat      // single callback (no degraded pass)
        options.isNetworkAccessAllowed = false         // posters stay local + fast
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFill, options: options) { img, _ in
                continuation.resume(returning: img)
            }
        }
    }

    /// Frame-0 posters are big — a full-tile 3× baked bitmap is ~10 MB — so an unbounded dictionary held
    /// ~500 MB for a 50-video session and never let go (memory-pressure / jetsam risk, prompt 106).
    /// `NSCache` is byte-cost-bounded and evicts automatically under system memory pressure; a re-request
    /// after eviction just re-decodes (the same path as a cold load).
    private static let frameZeroCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 150 * 1024 * 1024   // ~15 full-tile posters; smaller tiles keep many more
        return cache
    }()

    /// The cache cost of a baked poster: its decoded bitmap size in bytes.
    private static func bitmapCost(_ img: UIImage) -> Int {
        Int(img.size.width * img.scale) * Int(img.size.height * img.scale) * 4
    }

    /// The clip's EXACT first frame (t=0) as the poster — vs `poster(...)`, whose `PHImageManager` thumbnail is,
    /// for a VIDEO, an arbitrary Photos-chosen key frame. The Clips carousel uses this so the still each page
    /// holds is pixel-identical to the frame its `AVPlayerLayer` first displays: the `isReadyForDisplay`
    /// reveal/crossfade (ClipMediaSurface) becomes invisible, removing the takeover "flick" (the poster→video
    /// frame jump that frame analysis pinned as the root cause). Falls back to `poster(...)` whenever the AVAsset
    /// or frame can't be read (iCloud-only with network off, the simulator, an unreadable/edit-list clip), and
    /// memoizes by `localIdentifier` so swiping back never re-decodes. `appliesPreferredTrackTransform` + the
    /// 3× `maximumSize` match the player layer's orientation + the tile's Retina fill, so they register exactly.
    static func videoFrameZero(localIdentifier: String, pointSize: CGSize) async -> UIImage? {
        if let cached = frameZeroCache.object(forKey: localIdentifier as NSString) { return cached }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            return await poster(localIdentifier: localIdentifier, pointSize: pointSize)
        }
        // The PHImageManager + AVAssetImageGenerator callbacks are delivered on a BACKGROUND queue, so the
        // decode runs in a `nonisolated` helper. A closure inherited into this `@MainActor` type would carry
        // MainActor isolation and TRAP (`dispatch_assert_queue`) when the framework invokes it off-main — the
        // crash this fixes. Only the cache touch stays on the MainActor here; `extractFrameZero` returns a
        // Sendable `UIImage`, so nothing non-Sendable crosses the actor boundary.
        guard let img = await extractFrameZero(asset: asset, pointSize: pointSize) else {
            return await poster(localIdentifier: localIdentifier, pointSize: pointSize)
        }
        frameZeroCache.setObject(img, forKey: localIdentifier as NSString, cost: bitmapCost(img))
        return img
    }

    /// Decodes the asset's EXACT frame-0 off the main actor. `nonisolated` is load-bearing: it keeps the
    /// PHImageManager/AVAssetImageGenerator completion closures non-isolated so they run safely on the
    /// background queues the frameworks call them on. Local-only + fast (mirrors `poster()`): an iCloud-only
    /// clip yields nil → the caller falls back to the Photos thumbnail until it's local (documented edge).
    nonisolated private static func extractFrameZero(asset: PHAsset, pointSize: CGSize) async -> UIImage? {
        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = false
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                cont.resume(returning: AVAssetBox(avAsset))
            }
        }.value
        guard let avAsset else { return nil }
        let gen = AVAssetImageGenerator(asset: avAsset)
        gen.appliesPreferredTrackTransform = true     // bake orientation — matches the AVPlayerLayer
        gen.requestedTimeToleranceBefore = .zero       // EXACT frame-0, no key-frame tolerance
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: pointSize.width * 3, height: pointSize.height * 3)
        let cg: CGImage? = try? await withCheckedThrowingContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, error in
                if let image { cont.resume(returning: image) }
                else { cont.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        return cg.map { decoded($0) }   // bake the bitmap off-main so the snap-frame draw costs zero decode
    }

    /// Force-decodes a CGImage into a baked bitmap OFF the main thread. `UIImage(cgImage:)` is otherwise lazy —
    /// it decodes its pixels the first time it's DRAWN, which (for the carousel) is on the swipe-snap commit,
    /// adding decode + upload to the exact frame that's already stalling. Drawing it into a CGContext here (in
    /// the `nonisolated` helper — CGContext is not MainActor-bound) moves that cost off the snap. Falls back to
    /// the lazy image if the context can't be created.
    nonisolated private static func decoded(_ cg: CGImage) -> UIImage {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return UIImage(cgImage: cg) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let baked = ctx.makeImage() else { return UIImage(cgImage: cg) }
        return UIImage(cgImage: baked)
    }

    /// Boxes the non-Sendable `AVAsset` so it can cross the `requestAVAsset` continuation (mirrors SceneScorer).
    private struct AVAssetBox: @unchecked Sendable {
        let value: AVAsset?
        init(_ value: AVAsset?) { self.value = value }
    }
}
