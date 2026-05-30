import Foundation
import AVFoundation
import Photos
import HighlightEngine

/// Turns a platform-free `ReelPlan` into an actual video using AVFoundation
/// (#60 §5), entirely on-device. Resolves each segment's source `AVAsset` from its
/// PHAsset id, stitches the trimmed ranges into an `AVMutableComposition`, and
/// exports an .mp4 to a temp URL.
///
/// Photos (still segments) are skipped in v1's video stitch — a follow-up can render
/// a Ken-Burns still for `photoStill` seconds. Videos are the core of the reel.
final class ReelExporter {

    enum ExportError: LocalizedError {
        case noVideoSegments, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoSegments: return "This reel has no video clips to assemble yet."
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    func export(_ plan: ReelPlan) async throws -> URL {
        let videoSegments = plan.segments.filter { $0.kind == .video && $0.duration > 0.1 }
        guard !videoSegments.isEmpty else { throw ExportError.noVideoSegments }

        let composition = AVMutableComposition()
        let vTrack = composition.addMutableTrack(withMediaType: .video,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
        let aTrack = composition.addMutableTrack(withMediaType: .audio,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero

        for seg in videoSegments {
            guard let asset = try await avAsset(forLocalIdentifier: seg.mediaItemId) else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: seg.startWithinMedia, preferredTimescale: 600),
                duration: CMTime(seconds: seg.duration, preferredTimescale: 600)
            )
            if let src = try await asset.loadTracks(withMediaType: .video).first {
                try vTrack?.insertTimeRange(range, of: src, at: cursor)
            }
            if let srcA = try await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack?.insertTimeRange(range, of: srcA, at: cursor)
            }
            cursor = cursor + range.duration
        }

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportFailed("could not create export session")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-reel-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else {
            throw ExportError.exportFailed(export.error?.localizedDescription ?? "unknown")
        }
        return out
    }

    private func avAsset(forLocalIdentifier id: String) async throws -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        return await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: avAsset)
            }
        }
    }
}
