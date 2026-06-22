import Photos
import AVFoundation
import CoreGraphics

// MARK: - Clips feed — oriented clip aspect resolver (device I/O, prompt 92)
//
// Resolves a clip's **oriented** display aspect ratio (width / height) so the Clips feed can size each
// post's tile to its media (no letterbox/pillarbox bars). Device I/O (Photos / AVFoundation), kept OUT of
// the pure `ClipFeedComposer` per the layering rule. Results are cached in memory by `localIdentifier`, so
// a re-appearing post never re-reads the asset; the feed writes the resolved value back onto
// `SessionMedia.aspectRatio` (a one-shot lazy backfill) so it persists.
//
//   - A **photo**'s `PHAsset.pixelWidth/pixelHeight` already bake in orientation → the ratio is correct.
//   - A **video**'s raw track `naturalSize` is pre-rotation, so we apply the track `preferredTransform`
//     (the same `orientedSize` math `StudioComposer.sourceAspect` uses) before taking w/h; falls back to
//     the pixel dims if the track can't be read.
//   - Returns `nil` when the asset can't be read (the simulator has no library, iCloud-only with no
//     network, or `.limited`/denied access) — the caller keeps `ClipFeedComposer.defaultAspect`.
actor ClipAspectResolver {
    static let shared = ClipAspectResolver()

    private var cache: [String: Double] = [:]

    /// Oriented aspect (w/h) for a PHAsset `localIdentifier`, cached. `nil` if unresolved.
    func aspect(localIdentifier: String, isVideo: Bool) async -> Double? {
        if let cached = cache[localIdentifier] { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }
        let resolved = isVideo ? await videoAspect(asset) : pixelAspect(asset)
        if let resolved { cache[localIdentifier] = resolved }
        return resolved
    }

    /// Photo (and video fallback): the asset's pixel dimensions already account for orientation.
    private func pixelAspect(_ asset: PHAsset) -> Double? {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return nil }
        return Double(asset.pixelWidth) / Double(asset.pixelHeight)
    }

    /// Video: `naturalSize × preferredTransform` (orientation-correct), falling back to the pixel dims.
    private func videoAspect(_ asset: PHAsset) async -> Double? {
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .fastFormat            // dimensions only — don't pull the full iCloud video
        // AVAsset isn't Sendable → box it to cross the continuation boundary (mirrors ClipMediaSurface).
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        guard let avAsset = boxed.value,
              let track = try? await avAsset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return pixelAspect(asset) }
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let w = abs(oriented.width), h = abs(oriented.height)
        guard w > 0, h > 0 else { return pixelAspect(asset) }
        return Double(w / h)
    }

    /// Wraps a non-Sendable value so it can cross an async continuation boundary (produced + consumed once).
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
