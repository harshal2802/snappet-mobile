import Foundation
import AVFoundation
import Photos
import CoreGraphics
import CoreImage
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
        // Resolve each clip's PHAsset → AVAsset (the device-only / Photos-bound step), then assemble.
        var resolved: [(clip: TimelineClip, asset: AVAsset)] = []
        for clip in videoClips {
            if let asset = await avAsset(forLocalIdentifier: clip.localIdentifier) {
                resolved.append((clip, asset))
            }
        }
        return try await assemble(resolved: resolved, aspect: snapshot.aspect, sourceDurations: sourceDurations)
    }

    /// Build the multi-clip composition from **already-resolved** `(clip, AVAsset)` pairs — the
    /// testable seam, decoupled from Photos. The S0 profiling spike drives this directly with a
    /// synthetic on-device video (no PHAsset needed), so on-device export cost can be measured.
    func assemble(resolved: sending [(clip: TimelineClip, asset: AVAsset)],
                  aspect: ClipEditGeometry.OutputAspect,
                  sourceDurations: [UUID: Double] = [:]) async throws
        -> sending (AVMutableComposition, AVVideoComposition?) {
        guard !resolved.isEmpty else { throw ComposerError.noRenderableClips }

        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposerError.noRenderableClips
        }
        // Audio track is created LAZILY (only when a clip actually has audio) — an empty audio track
        // left in the composition makes the videoComposition export fail -11838 on-device, and real
        // clips can legitimately have no audio (S0 spike).
        var aTrack: AVMutableCompositionTrack?

        var cursor = CMTime.zero
        // ONE layer instruction for the single video track; each clip sets its transform at its own
        // start time (a piecewise-constant transform across the sequential cuts). Multiple layer
        // instructions for the same track in one instruction is malformed and fails export.
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        var renderSize: CGSize?
        // Per-clip colour filter, by output time range (drives the CIFilter compositor path below).
        var filterRanges: [(range: CMTimeRange, filter: StudioFilter, intensity: Double)] = []

        for (clip, source) in resolved {
            guard let srcVideo = try? await source.loadTracks(withMediaType: .video).first else {
                continue   // no video track → skip this clip, keep the rest
            }
            var assetDuration = sourceDurations[clip.id] ?? 0
            if assetDuration <= 0 { assetDuration = (try? await source.load(.duration).seconds) ?? 0 }
            guard let window = ClipEditGeometry.trimWindow(
                start: clip.trimStart, end: clip.trimEnd ?? assetDuration,
                assetDuration: assetDuration) else { continue }

            let naturalSize = (try? await srcVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let preferred = (try? await srcVideo.load(.preferredTransform)) ?? .identity
            let orientedSize = orientedSize(naturalSize, transform: preferred)
            let canvas = renderSize ?? ClipEditGeometry.renderSize(for: aspect, sourceSize: orientedSize)
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

            // Original audio (also speed-scaled), if present — create the audio track on first use.
            if let srcAudio = try? await source.loadTracks(withMediaType: .audio).first {
                let track = aTrack ?? composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                aTrack = track
                if let track {
                    try? track.insertTimeRange(sourceRange, of: srcAudio, at: insertAt)
                    if abs(clip.speed - 1.0) > 0.001 {
                        let seg = CMTimeRange(start: insertAt,
                                              duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
                        track.scaleTimeRange(seg, toDuration: CMTime(seconds: outDuration, preferredTimescale: timescale))
                    }
                }
            }

            // Per-clip transform (orientation THEN crop→canvas), set at this clip's start time on
            // the shared layer instruction — it holds until the next clip's transform.
            let crop = ClipEditGeometry.cropTransform(
                cropRect: clip.cropRect, sourceSize: orientedSize, renderSize: canvas)
            layerInstruction.setTransform(preferred.concatenating(crop), at: insertAt)

            let outRange = CMTimeRange(start: insertAt,
                                       duration: CMTime(seconds: outDuration, preferredTimescale: timescale))
            filterRanges.append((outRange, clip.filter, clip.filterIntensity))
            cursor = outRange.end
        }

        guard cursor > .zero, let canvas = renderSize else { throw ComposerError.noRenderableClips }

        let videoComposition: AVMutableVideoComposition
        if filterRanges.contains(where: { $0.filter != .none }) {
            // S2 — at least one clip has a colour filter: composite through Core Image. AVFoundation
            // hands each frame to the handler as a CIImage; we aspect-fill it to the canvas and apply
            // the active clip's filter. (This path supersedes the per-clip transform/crop instruction;
            // combining precise crop WITH a filter is a follow-up — the layout here is aspect-fill.)
            let ranges = filterRanges
            videoComposition = AVMutableVideoComposition(asset: composition) { request in
                let t = request.compositionTime
                var image = StudioFilters.aspectFill(request.sourceImage, to: canvas)
                if let active = ranges.first(where: { $0.range.containsTime(t) }), active.filter != .none {
                    image = StudioFilters.apply(active.filter, intensity: active.intensity, to: image)
                }
                request.finish(with: image, context: nil)
            }
            videoComposition.renderSize = canvas
        } else {
            // No filters: the transform/crop path. Build from the composition's own properties (so
            // color/format tags + a valid source-track mapping are present) rather than a bare
            // `AVMutableVideoComposition()`, which the on-device encoder rejects with -11838 (S0).
            videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
            videoComposition.renderSize = canvas
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]
        }

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
