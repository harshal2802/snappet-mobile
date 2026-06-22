import Photos
import UIKit

// MARK: - Clips feed — oriented clip aspect resolver (device I/O, prompt 92)
//
// Resolves a clip's **oriented** display aspect ratio (width / height) so the Clips feed can size each
// post's tile to its media (no letterbox/pillarbox bars). Device I/O (Photos), kept OUT of the pure
// `ClipFeedComposer`. Results cache in memory by `localIdentifier`; the feed writes the resolved value back
// onto `SessionMedia.aspectRatio` (a one-shot lazy backfill) so it persists.
//
// We read the asset's **oriented poster-frame size** via `PHImageManager.requestImage(.aspectFit)`, which
// is reliable for BOTH photo and video — the rendered poster frame is always display-oriented. (The earlier
// `requestAVAsset` + `loadTracks` path returned a track-less asset on-device → a nil aspect → the feed fell
// back to the default and still pillarboxed; and a video track's raw `naturalSize` / `PHAsset.pixelWidth`
// are pre-rotation, so they'd give an inverted aspect.) `nil` when the asset can't be read (simulator /
// denied / iCloud-only offline) → the caller keeps `ClipFeedComposer.defaultAspect`.
actor ClipAspectResolver {
    static let shared = ClipAspectResolver()

    private var cache: [String: Double] = [:]

    /// Oriented aspect (w/h) for a PHAsset `localIdentifier`, cached on success. `nil` if unresolved.
    /// `isVideo` is unused (the poster-frame size is correct for both kinds) — kept for call-site clarity.
    func aspect(localIdentifier: String, isVideo: Bool) async -> Double? {
        if let cached = cache[localIdentifier] { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }
        guard let value = await posterAspect(asset), value.isFinite, value > 0 else { return nil }
        cache[localIdentifier] = value
        return value
    }

    /// The oriented display aspect from the asset's poster frame (correct for video AND photo).
    private func posterAspect(_ asset: PHAsset) async -> Double? {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat     // a single callback (no degraded pass) → safe continuation
        opts.isNetworkAccessAllowed = true         // resolve iCloud-only clips too (local is instant)
        opts.resizeMode = .fast
        // aspectFit (NOT aspectFill) so the returned image preserves the asset's true aspect (no crop).
        let size: CGSize? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 800, height: 800),
                contentMode: .aspectFit, options: opts) { image, _ in
                cont.resume(returning: image?.size)   // CGSize is Sendable; the UIImage never escapes
            }
        }
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return Double(size.width / size.height)
    }
}
