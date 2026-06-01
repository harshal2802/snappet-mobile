import Foundation
import AVFoundation
import Photos
import CoreGraphics
import QuartzCore
import UIKit

/// Turns a non-destructive `ClipEdit` (+ its source `PHAsset`) into a playable/exportable
/// AVFoundation composition (B3) — the CapCut-style on-device clip editor's render engine.
///
/// Built entirely with AVFoundation, on-device (no backend, RESEARCH §3.5):
/// - **trim** → a source `CMTimeRange` (`ClipEditGeometry.trimWindow`);
/// - **speed** → `scaleTimeRange` on the inserted range (`ClipEditGeometry.scaledDuration`);
/// - **crop / aspect / orientation** → `renderSize` on the `AVMutableVideoComposition` +
///   per-clip `AVMutableVideoCompositionLayerInstruction.setTransform`
///   (`ClipEditGeometry.renderSize` / `.cropTransform`) — this is the **mixed-orientation
///   normalization** that closes the deferred gap (decisions.md 2026-05-31);
/// - **text overlays** → a `CALayer` tree composited via `AVVideoCompositionCoreAnimationTool`.
///
/// The single `makeComposition(for:)` builds the `(AVMutableComposition, AVVideoComposition?)`
/// reused for **both** preview (wrap in an `AVPlayer`) and export — mirroring how `ReelExporter`
/// shares one composition (decisions.md 2026-05-31, P3). The pure geometry/timing math lives in
/// `ClipEditGeometry` (unit-tested with no AVFoundation). Reuses `ReelExporter`'s PHAsset→AVAsset
/// resolve + `Box`/`sending` Swift-6 patterns. Stateless → `Sendable`.
final class VideoStudio: Sendable {

    /// Wraps a non-Sendable value across a single continuation resume (produced/consumed once) —
    /// same pattern as `ReelExporter`/`PhotoClipRenderer`.
    private struct Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    enum StudioError: LocalizedError {
        case sourceUnavailable, noVideoTrack, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .sourceUnavailable: return "This clip's source video couldn't be loaded."
            case .noVideoTrack: return "The source has no video track to edit."
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    private let timescale: CMTimeScale = 600

    // MARK: - Build the composition (shared by preview + export)

    /// Build the playable composition + its video composition for an edit **snapshot**. An
    /// `AVMutableComposition` is an `AVAsset`, so this is reused for BOTH in-app preview
    /// (wrap in an `AVPlayer`) and export. `sending` lets the freshly-built, otherwise-
    /// unreferenced values cross to the `@MainActor` view model under Swift 6 isolation.
    ///
    /// Takes an `EditPlan` (a `Sendable` value snapshot of a `ClipEdit`, taken on the
    /// `@MainActor` caller via `EditPlan(edit)`) so the non-Sendable SwiftData `@Model` never
    /// crosses the actor boundary into this nonisolated build path.
    func makeComposition(for plan: EditPlan) async throws
        -> sending (AVMutableComposition, AVVideoComposition?) {
        try await build(plan: plan)
    }

    private func build(plan: EditPlan) async throws
        -> (AVMutableComposition, AVVideoComposition?) {
        guard let source = await avAsset(forLocalIdentifier: plan.localIdentifier) else {
            throw StudioError.sourceUnavailable
        }
        guard let srcVideo = try? await source.loadTracks(withMediaType: .video).first else {
            throw StudioError.noVideoTrack
        }

        let assetDuration = (try? await source.load(.duration).seconds) ?? 0
        guard let window = ClipEditGeometry.trimWindow(
            start: plan.trimStart, end: plan.trimEnd ?? assetDuration,
            assetDuration: assetDuration) else {
            throw StudioError.noVideoTrack
        }

        // Orientation-applied natural size (CapCut-style: respect the recorded rotation).
        let naturalSize = (try? await srcVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let preferred = (try? await srcVideo.load(.preferredTransform)) ?? .identity
        let orientedSize = orientedSize(naturalSize, transform: preferred)

        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.noVideoTrack
        }

        let sourceRange = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: timescale),
            duration: CMTime(seconds: window.duration, preferredTimescale: timescale))
        try vTrack.insertTimeRange(sourceRange, of: srcVideo, at: .zero)

        // Speed: scale the inserted range to the speed-adjusted output duration.
        let outDuration = ClipEditGeometry.scaledDuration(
            sourceDuration: window.duration, speed: plan.speed)
        if abs(plan.speed - 1.0) > 0.001 {
            let scaledTo = CMTime(seconds: outDuration, preferredTimescale: timescale)
            vTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: vTrack.timeRange.duration),
                                  toDuration: scaledTo)
        }

        // Audio: keep the original (also speed-scaled) unless muted.
        if !plan.mutedOriginalAudio,
           let srcAudio = try? await source.loadTracks(withMediaType: .audio).first,
           let aTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? aTrack.insertTimeRange(sourceRange, of: srcAudio, at: .zero)
            if abs(plan.speed - 1.0) > 0.001 {
                let scaledTo = CMTime(seconds: outDuration, preferredTimescale: timescale)
                aTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: aTrack.timeRange.duration),
                                      toDuration: scaledTo)
            }
        }

        // Render size = the chosen output aspect (mixed-orientation normalization).
        let renderSize = ClipEditGeometry.renderSize(for: plan.aspect, sourceSize: orientedSize)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        // One layer instruction: preferredTransform (orientation) THEN the crop/scale transform.
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        let crop = ClipEditGeometry.cropTransform(
            cropRect: plan.cropRect, sourceSize: orientedSize, renderSize: renderSize)
        layerInstruction.setTransform(preferred.concatenating(crop), at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Text overlays via a CALayer tree (AVVideoCompositionCoreAnimationTool).
        if !plan.textOverlays.isEmpty {
            attachOverlays(plan.textOverlays, to: videoComposition,
                           renderSize: renderSize, totalDuration: composition.duration.seconds)
        }

        return (composition, videoComposition)
    }

    // MARK: - Export

    /// Export the edited clip to a temp `.mp4`. Uses the modern async export API (no
    /// continuation/data-race under Swift 6), mirroring `ReelExporter.export`. Takes an
    /// `EditPlan` snapshot (the non-Sendable `@Model` stays on the `@MainActor` caller).
    func export(_ plan: EditPlan) async throws -> URL {
        let (composition, videoComposition) = try await makeComposition(for: plan)
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StudioError.exportFailed("could not create export session")
        }
        session.videoComposition = videoComposition
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappet-clip-\(UUID().uuidString).mp4")
        try await session.export(to: out, as: .mp4)
        return out
    }

    // MARK: - Overlay compositing (Core Animation tool)

    private func attachOverlays(_ overlays: [TextOverlay],
                                to videoComposition: AVMutableVideoComposition,
                                renderSize: CGSize, totalDuration: Double) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: renderSize)

        for overlay in overlays where !overlay.string.isEmpty {
            let text = CATextLayer()
            text.string = overlay.string
            text.fontSize = CGFloat(overlay.fontSize)
            text.foregroundColor = UIColor(hex: overlay.colorHex).cgColor
            text.alignmentMode = .center
            text.isWrapped = true
            text.contentsScale = 2
            text.shadowColor = UIColor.black.cgColor
            text.shadowOpacity = 0.6
            text.shadowRadius = 3
            text.shadowOffset = .zero

            let boxW = renderSize.width * 0.9
            let boxH = max(CGFloat(overlay.fontSize) * 1.6, 40)
            let center = ClipEditGeometry.layerPoint(
                normalized: overlay.normalizedPosition, in: renderSize)
            text.frame = CGRect(x: center.x - boxW / 2, y: center.y - boxH / 2,
                                width: boxW, height: boxH)

            // Time-gate the overlay's visibility (output/edited seconds). Visible ONLY within
            // [start, end] — a keyframe over the whole clip so the overlay also DISAPPEARS after
            // `end` (a `fillMode:.forwards` basic animation would wrongly hold it visible).
            let total = max(0.01, totalDuration.isFinite ? totalDuration : overlay.endSec)
            let start = max(0, min(overlay.startSec, total))
            let end = max(start, min(overlay.endSec, total))
            if start > 0 || end < total {
                text.opacity = 0
                let s = start / total
                let e = end / total
                let anim = CAKeyframeAnimation(keyPath: "opacity")
                anim.values   = [0, 0, 1, 1, 0, 0]
                anim.keyTimes = [0, NSNumber(value: s), NSNumber(value: s),
                                 NSNumber(value: e), NSNumber(value: e), 1]
                anim.beginTime = AVCoreAnimationBeginTimeAtZero
                anim.duration = total
                anim.isRemovedOnCompletion = false
                anim.fillMode = .both
                text.add(anim, forKey: "visibility")
            }
            overlayLayer.addSublayer(text)
        }

        parent.addSublayer(videoLayer)
        parent.addSublayer(overlayLayer)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    // MARK: - Orientation helper

    /// Apply a track's `preferredTransform` to its natural size to get the displayed size
    /// (swaps width/height for 90°/270° rotations).
    private func orientedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// The source clip's full duration in seconds (for the editor's trim handles), or `nil`
    /// if the asset can't be resolved (e.g. on the simulator with no Photos).
    func sourceDuration(localIdentifier id: String) async -> Double? {
        guard let asset = await avAsset(forLocalIdentifier: id),
              let d = try? await asset.load(.duration).seconds, d > 0 else { return nil }
        return d
    }

    // MARK: - PHAsset → AVAsset (reused from ReelExporter)

    private func avAsset(forLocalIdentifier id: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        let boxed: Box<AVAsset?> = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = false   // on-device only
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: Box(avAsset))
            }
        }
        return boxed.value
    }

}

/// A `Sendable` value snapshot of a `ClipEdit`'s fields, taken on the `@MainActor` caller so the
/// non-Sendable SwiftData `@Model` never crosses into `VideoStudio`'s nonisolated build path
/// (the same discipline as `ReelExporter` taking a plain `ReelPlan`). Resolution-independent —
/// the geometry/timing become `CMTime`s/transforms inside `VideoStudio`.
struct EditPlan: Sendable {
    let localIdentifier: String
    let trimStart: Double
    let trimEnd: Double?
    let cropRect: CGRect
    let aspect: ClipEditGeometry.OutputAspect
    let speed: Double
    let textOverlays: [TextOverlay]
    let mutedOriginalAudio: Bool

    @MainActor init(_ e: ClipEdit) {
        localIdentifier = e.localIdentifier
        trimStart = e.trimStart
        trimEnd = e.trimEnd
        cropRect = e.cropRect
        aspect = e.aspect
        speed = e.speed
        textOverlays = e.textOverlays
        mutedOriginalAudio = e.mutedOriginalAudio
    }
}

// MARK: - Color hex helper

private extension UIColor {
    /// Parse a `#RRGGBB` (or `RRGGBB`) hex string; falls back to white on a bad string.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self.init(white: 1, alpha: 1); return
        }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
