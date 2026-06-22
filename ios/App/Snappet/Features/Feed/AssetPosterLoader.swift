import SwiftUI
import Photos
import UIKit

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
}
