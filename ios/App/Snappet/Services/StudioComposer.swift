import Foundation
import AVFoundation
import Photos
import CoreGraphics
import UIKit

/// Turns a `StudioProjectSnapshot` (multi-clip timeline) into a playable/exportable AVFoundation
/// composition — the full studio's render engine (S1), generalizing `VideoStudio` from one clip to
/// many. Like `VideoStudio`, the single `makeComposition(for:sourceDurations:)` builds the
/// `(AVMutableComposition, AVVideoComposition?)` reused for **both** preview (`AVPlayer`) and export,
/// reusing the same `Box`/`avAsset` PHAsset-resolution and `ClipEditGeometry` transform math.
///
/// **S1 scope (this file):** ordered **video** clips inserted sequentially (trim + speed) with a
/// shared output canvas (`renderSize`) and per-clip orientation+crop transforms — the mixed-
/// orientation normalization, now across many clips. **Device-only** (PHAsset → AVAsset needs a real
/// Photos library; nothing renders on the simulator), so it is exercised by build + the pure
/// `StudioGeometry`/`StudioProjectEditor` tests, not a simulator run.
///
/// **Deferred to S2+ (extension points, intentionally not yet rendered):** Core-Image filters/LUTs
/// (`TimelineClip.filter`) via a custom `AVVideoCompositing`; transitions (`StudioTransition`) as
/// opacity/transform ramps; overlays (`OverlayItem`) via `AVVideoCompositionCoreAnimationTool`;
/// Ken-Burns photos via `PhotoClipRenderer`; the audio mix (`AudioTrack`). The model already carries
/// all of these — only the compositor pass is pending (gated by the S0 device-profiling spike).
final class StudioComposer: Sendable {

    private struct Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    enum ComposerError: LocalizedError {
        case noRenderableClips, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noRenderableClips: return "This project has no video clips to render yet."
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    private let timescale: CMTimeScale = 600

    /// Build the multi-clip composition. `sourceDurations` (clip id → seconds) lets the caller pass
    /// already-resolved durations; any missing one is loaded from the asset here.
    func makeComposition(for snapshot: StudioProjectSnapshot,
                         sourceDurations: [UUID: Double] = [:]) async throws
        -> sending (AVMutableComposition, AVVideoComposition?) {

        // S1 renders video clips; photos are a Ken-Burns step in S2+.
        let videoClips = StudioGeometry.ordered(snapshot.clips).filter { !$0.isPhoto }
        guard !videoClips.isEmpty else { throw ComposerError.noRenderableClips }

        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposerError.noRenderableClips
        }
        let aTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        var renderSize: CGSize?

        for clip in videoClips {
            guard let source = await avAsset(forLocalIdentifier: clip.localIdentifier),
                  let srcVideo = try? await source.loadTracks(withMediaType: .video).first else {
                continue   // unresolved (e.g. on the simulator) → skip this clip, keep the rest
            }
            var assetDuration = sourceDurations[clip.id] ?? 0
            if assetDuration <= 0 { assetDuration = (try? await source.load(.duration).seconds) ?? 0 }
            guard let window = ClipEditGeometry.trimWindow(
                start: clip.trimStart, end: clip.trimEnd ?? assetDuration,
                assetDuration: assetDuration) else { continue }

            let naturalSize = (try? await srcVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let preferred = (try? await srcVideo.load(.preferredTransform)) ?? .identity
            let orientedSize = orientedSize(naturalSize, transform: preferred)
            let canvas = renderSize ?? ClipEditGeometry.renderSize(for: snapshot.aspect, sourceSize: orientedSize)
            renderSize = canvas

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: window.start, preferredTimescale: timescale),
                duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
            let insertAt = cursor
            do { try vTrack.insertTimeRange(sourceRange, of: srcVideo, at: insertAt) }
            catch { continue }

            // Speed-scale the just-inserted segment in place.
            let outDuration = ClipEditGeometry.scaledDuration(sourceDuration: window.duration, speed: clip.speed)
            if abs(clip.speed - 1.0) > 0.001 {
                let segment = CMTimeRange(start: insertAt,
                                          duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
                vTrack.scaleTimeRange(segment, toDuration: CMTime(seconds: outDuration, preferredTimescale: timescale))
            }

            // Original audio (also speed-scaled), if present.
            if let aTrack, let srcAudio = try? await source.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(sourceRange, of: srcAudio, at: insertAt)
                if abs(clip.speed - 1.0) > 0.001 {
                    let seg = CMTimeRange(start: insertAt,
                                          duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
                    aTrack.scaleTimeRange(seg, toDuration: CMTime(seconds: outDuration, preferredTimescale: timescale))
                }
            }

            // Per-clip transform: orientation THEN crop→canvas, applied for this clip's output range.
            let crop = ClipEditGeometry.cropTransform(
                cropRect: clip.cropRect, sourceSize: orientedSize, renderSize: canvas)
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
            li.setTransform(preferred.concatenating(crop), at: insertAt)
            // Hide this clip's layer outside its own segment so layers don't bleed across cuts.
            let outEnd = CMTimeAdd(insertAt, CMTime(seconds: outDuration, preferredTimescale: timescale))
            li.setOpacity(0, at: outEnd)
            layerInstructions.append(li)

            cursor = outEnd
        }

        guard cursor > .zero, let canvas = renderSize else { throw ComposerError.noRenderableClips }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = layerInstructions
        videoComposition.instructions = [instruction]

        return (composition, videoComposition)
    }

    /// Export the composed timeline to a temp `.mp4` (same async export path as `VideoStudio`).
    func export(_ snapshot: StudioProjectSnapshot, sourceDurations: [UUID: Double] = [:]) async throws -> URL {
        let (composition, videoComposition) = try await makeComposition(
            for: snapshot, sourceDurations: sourceDurations)
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ComposerError.exportFailed("could not create export session")
        }
        session.videoComposition = videoComposition
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-studio-\(UUID().uuidString).mp4")
        try await session.export(to: out, as: .mp4)
        return out
    }

    /// The source clip's full duration (for trim handles), or `nil` if unresolved (e.g. simulator).
    func sourceDuration(localIdentifier id: String) async -> Double? {
        guard let asset = await avAsset(forLocalIdentifier: id),
              let d = try? await asset.load(.duration).seconds, d > 0 else { return nil }
        return d
    }

    private func orientedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func avAsset(forLocalIdentifier id: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = false
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        return boxed.value
    }
}
