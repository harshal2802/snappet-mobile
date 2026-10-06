import Foundation
import Photos
import AVFoundation

// MARK: - Clips feed — share a single clip's video (prompt 87)
//
// Exports one Clips-feed clip to a temp file for the system share sheet (`ShareSheet`). Two lanes:
// - `exportForSharing` — the RAW clip (passthrough, no re-encode): "Share original clip".
// - `exportWithHeartRate` (prompt 160) — the clip's kept range re-encoded with the feed's HR tile and
//   name lower-third burned in, via the Studio's own Core-Animation overlay tool: "Share with heart rate".
// Device-only: needs the real `PHAsset`, so both return nil on the simulator / for a missing or non-video
// asset (the caller shows the "couldn't prepare" alert).

enum ClipShareService {

    /// Export the clip's video by Photos `localIdentifier` to a temp `.mov` for sharing, or nil on failure.
    static func exportForSharing(localIdentifier: String) async -> URL? {
        guard let avAsset = await videoAsset(localIdentifier: localIdentifier) else { return nil }

        // Try passthrough (no re-encode → fast, original quality) into a .mov first. Passthrough can
        // CONSTRUCT fine yet FAIL at export when the source codec/track layout can't remux into a QuickTime
        // container (e.g. some HEVC/HDR / multi-track captures) — so on failure, re-encode to a .mp4 (a
        // HighestQuality re-encode produces a compatible file), instead of silently giving up.
        if let url = await export(avAsset, preset: AVAssetExportPresetPassthrough, fileType: .mov) { return url }
        return await export(avAsset, preset: AVAssetExportPresetHighestQuality, fileType: .mp4)
    }

    /// Render the clip's kept range with its HR tile + caption burned in (prompt 160) to a temp `.mp4`,
    /// or nil on failure. One clip, native orientation + resolution — the share looks like the poster.
    static func exportWithHeartRate(_ plan: ClipSharePlan.Plan) async -> URL? {
        guard let avAsset = await videoAsset(localIdentifier: plan.localIdentifier),
              let srcVideo = try? await avAsset.loadTracks(withMediaType: .video).first,
              let assetDuration = try? await avAsset.load(.duration).seconds,
              let plan = ClipSharePlan.clamped(plan, assetDuration: assetDuration) else { return nil }

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: plan.start, preferredTimescale: 600),
                                duration: CMTime(seconds: plan.duration, preferredTimescale: 600))
        guard let vTrack = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? vTrack.insertTimeRange(range, of: srcVideo, at: .zero)) != nil else { return nil }
        // Audio only when the source has some — an EMPTY audio track fails the re-encode on device
        // (-11838 / -16976; the ReelExporter + StudioComposer lesson).
        if let srcAudio = try? await avAsset.loadTracks(withMediaType: .audio).first {
            let aTrack = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
            try? aTrack?.insertTimeRange(range, of: srcAudio, at: .zero)
        }

        #if targetEnvironment(simulator)
        // The simulator has no H.264 encoder (see ReelExporter.export) — passthrough, no overlay.
        return await export(composition, preset: AVAssetExportPresetPassthrough, fileType: .mp4)
        #else
        let natural = (try? await srcVideo.load(.naturalSize)) ?? CGSize(width: 1080, height: 1920)
        let transform = (try? await srcVideo.load(.preferredTransform)) ?? .identity
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let canvas = CGSize(width: (abs(oriented.width) / 2).rounded() * 2,
                            height: (abs(oriented.height) / 2).rounded() * 2)
        guard canvas.width >= 2, canvas.height >= 2,
              // From the composition's properties, NOT a bare init — a bare AVMutableVideoComposition
              // fails the device re-encode (-11838 / -16976; ReelExporter.makeVideoComposition).
              let vc = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        else { return nil }
        vc.renderSize = canvas
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        vc.instructions = [instruction]

        // The caption rides the Studio's climb-name lower-third, TOP of frame: the feed scorebug sits
        // at the bottom (HRTile default centerY 0.80), so the two never overlap.
        let overlays = plan.caption.map {
            [OverlayItem(kind: .climbName, content: $0, startSec: 0, endSec: plan.duration,
                         position: CGPoint(x: 0.5, y: 0.1), highlightHex: "#000000")]
        } ?? []
        // The tile in the poster's band shape + inset, not its stored geometry (see `posterBand`).
        var hr = plan.hr
        hr.tile = hr.tile.map { ClipSharePlan.posterBand($0, canvas: canvas) }
        vc.animationTool = StudioOverlays.makeAnimationTool(
            overlays: overlays, canvas: canvas, totalDuration: composition.duration.seconds,
            clipHR: [hr])
        return await export(composition, preset: AVAssetExportPresetHighestQuality, fileType: .mp4,
                            videoComposition: vc)
        #endif
    }

    /// Resolve a Photos video by `localIdentifier` (iCloud download allowed), or nil.
    private static func videoAsset(localIdentifier: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let phAsset = assets.firstObject, phAsset.mediaType == .video else { return nil }

        // AVAsset isn't Sendable → box it across the continuation (mirrors StudioComposer.avAsset).
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true            // allow an iCloud-stored clip to download
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        return boxed.value
    }

    /// Run one export attempt to a fresh temp file; nil if the session can't be made or the export throws.
    private static func export(_ asset: AVAsset, preset: String, fileType: AVFileType,
                               videoComposition: AVVideoComposition? = nil) async -> URL? {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        session.videoComposition = videoComposition
        let ext = fileType == .mp4 ? "mp4" : "mov"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-clip-\(UUID().uuidString).\(ext)")
        do { try await session.export(to: out, as: fileType) } catch { return nil }
        return out
    }

    /// Wraps a non-Sendable value so it can cross an async continuation boundary (produced + consumed once).
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
