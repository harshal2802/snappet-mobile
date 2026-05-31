import Foundation
import AVFoundation
import Photos
import HighlightEngine

/// Wraps a non-Sendable value so it can cross an async continuation boundary.
/// Safe here because each boxed value is produced and consumed exactly once, serially.
private struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Turns a platform-free `ReelPlan` into an actual video using AVFoundation
/// (#60 §5), entirely on-device. Resolves each segment's source `AVAsset` from its
/// PHAsset id, stitches the trimmed ranges into an `AVMutableComposition`, and
/// exports an .mp4 to a temp URL.
///
/// Photos (still segments) are skipped in v1's video stitch — a follow-up can render
/// a Ken-Burns still for `photoStill` seconds. Videos are the core of the reel.
/// Stateless → `Sendable`.
final class ReelExporter: Sendable {

    enum ExportError: LocalizedError {
        case noVideoSegments, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoSegments: return "This reel has no video clips to assemble yet."
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    /// Build the playable composition for a plan. An `AVMutableComposition` is an
    /// `AVAsset`, so this is reused for BOTH in-app preview (wrap in an `AVPlayer`,
    /// no export) and export. `sending` lets the freshly-built, otherwise-unreferenced
    /// composition cross to the `@MainActor` view model under Swift 6 isolation.
    func makeComposition(for plan: ReelPlan) async throws -> sending AVMutableComposition {
        let renderable = plan.segments.filter {
            ($0.kind == .video && $0.duration > 0.1) || $0.kind == .photo
        }
        guard !renderable.isEmpty else { throw ExportError.noVideoSegments }

        let composition = AVMutableComposition()
        let vTrack = composition.addMutableTrack(withMediaType: .video,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
        let aTrack = composition.addMutableTrack(withMediaType: .audio,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
        let photoRenderer = PhotoClipRenderer()
        var cursor = CMTime.zero
        var inserted = 0

        // Iterate segments IN ORDER so photos interleave with videos correctly.
        for seg in renderable {
            if seg.kind == .photo {
                // Render the still to a Ken-Burns clip, then insert it like a video.
                guard let url = await photoRenderer.renderClip(assetId: seg.mediaItemId,
                                                               duration: plan.photoStill) else { continue }
                let asset = AVURLAsset(url: url)
                guard let src = try? await asset.loadTracks(withMediaType: .video).first else { continue }
                let dur = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: dur)
                do {
                    try vTrack?.insertTimeRange(range, of: src, at: cursor)
                    cursor = cursor + dur
                    inserted += 1
                } catch { continue }   // skip a bad photo clip, keep the reel
            } else {
                guard let asset = await avAsset(forLocalIdentifier: seg.mediaItemId) else { continue }
                let range = CMTimeRange(
                    start: CMTime(seconds: seg.startWithinMedia, preferredTimescale: 600),
                    duration: CMTime(seconds: seg.duration, preferredTimescale: 600)
                )
                guard let src = try? await asset.loadTracks(withMediaType: .video).first else { continue }
                do { try vTrack?.insertTimeRange(range, of: src, at: cursor) }
                catch { continue }
                if let srcA = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? aTrack?.insertTimeRange(range, of: srcA, at: cursor)
                }
                cursor = cursor + range.duration
                inserted += 1
            }
        }
        guard inserted > 0 else { throw ExportError.noVideoSegments }
        return composition
    }

    func export(_ plan: ReelPlan) async throws -> URL {
        let composition = try await makeComposition(for: plan)
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportFailed("could not create export session")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-reel-\(UUID().uuidString).mp4")
        // Modern async export (iOS 18+): throws on failure, no continuation/data-race.
        try await session.export(to: out, as: .mp4)
        return out
    }

    private func avAsset(forLocalIdentifier id: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        return boxed.value
    }
}
