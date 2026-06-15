import Foundation
import AVFoundation
import Vision
import CoreImage
import Photos
import OSLog
import HighlightEngine

/// Wraps a non-Sendable value so it can cross an async continuation boundary (produced/consumed once).
private struct AssetBox: @unchecked Sendable { let value: AVAsset?; init(_ v: AVAsset?) { value = v } }

private let sceneLog = Logger(subsystem: "com.snappet.app", category: "SceneScorer")

/// Raw per-frame visual signals, each normalized to 0…1. PURE value type — testable without Vision.
struct SceneFrameSignals: Equatable, Sendable {
    var sharpness: Double   // focus energy (variance-of-Laplacian), relative within a clip
    var saliency: Double    // mean attention-based saliency (Vision)
    var presence: Double    // face/body coverage fraction (Vision)
}

/// PURE combination of the per-frame signals into one 0…1 scene score. No Vision/AVFoundation here, so
/// the scoring *decision* is unit-tested off-device (the fixture proof).
///
/// Sharpness is a **multiplicative gate**: a blurry frame can't be a highlight however salient — it kills
/// the score directly. Content (saliency + subject presence) is a `[0.5, 1.0]` multiplier, so an empty
/// frame is penalized (down to half) but a sharp, subjectless-but-fine frame isn't zeroed. Net: BOTH
/// blurry and empty frames are penalized; only sharp-AND-has-something scores high.
///
/// These are the scorer's INTERNAL weights — NOT the HR-vs-scene fusion weights, which come only from
/// replayed feedback (`FeedbackReplay.tunedWeighting`).
enum SceneScoring {
    static func score(_ s: SceneFrameSignals) -> Double {
        let content = 0.5 + 0.3 * s.saliency + 0.2 * s.presence   // [0.5, 1.0]
        return min(1, max(0, s.sharpness * content))
    }
}

/// The thin PLATFORM EDGE for #83 Step 1: samples frames across a workout's video media and scores each
/// with Apple's Vision + Core Image (saliency, sharpness, face/body presence). Only the resulting scalar
/// scores cross into `HighlightEngine` (via `SceneHighlightSelector.visualScore`) — the engine stays
/// platform-free. Real-footage selection quality is device-verified; the off-device proof is the
/// synthesized blurry-vs-sharp fixture test (`SceneScorerTests`).
final class SceneScorer: Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Score a workout's video media → `visualScore` map keyed by **workout-offset seconds** (the engine
    /// timeline): for media at `startOffset S`, a frame sampled at media-time `t` maps to `S + t`.
    /// Signals are normalized relative to the brightest/sharpest sampled frame, so the score ranks
    /// moments WITHIN the session (which is all the selector needs). Returns an empty map on any failure
    /// — the caller then falls back to a 0 scene contribution (HR-only), never a crash.
    func sceneScores(for media: [MediaItem], sampleEverySec: Double = 1.0) async -> [(offset: Double, score: Double)] {
        var rawByOffset: [(offset: Double, signals: SceneFrameSignals)] = []
        for item in media where item.kind == .video && item.duration > 0.1 {
            guard let asset = await avAsset(forLocalIdentifier: item.id) else { continue }
            let times = stride(from: 0.0, through: item.duration, by: sampleEverySec).map { $0 }
            for t in times {
                guard let signals = await self.signals(asset: asset, atSeconds: t) else { continue }
                rawByOffset.append((offset: item.startOffset + t, signals: signals))
            }
        }
        guard !rawByOffset.isEmpty else { return [] }

        // Relative-normalize sharpness + saliency across the sampled frames (presence is already a 0…1
        // coverage fraction). Divide-by-max keeps it scale-free — no magic absolute thresholds.
        let maxSharp = max(rawByOffset.map { $0.signals.sharpness }.max() ?? 0, 1e-9)
        let maxSal = max(rawByOffset.map { $0.signals.saliency }.max() ?? 0, 1e-9)
        return rawByOffset.map { entry in
            let n = SceneFrameSignals(sharpness: entry.signals.sharpness / maxSharp,
                                      saliency: entry.signals.saliency / maxSal,
                                      presence: entry.signals.presence)
            return (offset: entry.offset, score: SceneScoring.score(n))
        }
    }

    /// A `visualScore` closure for `SceneHighlightSelector`: nearest sampled score to the queried offset
    /// (the engine samples on a 1 s grid too, so nearest is exact in practice). 0 when no scores exist.
    static func visualScore(from scores: [(offset: Double, score: Double)]) -> @Sendable (Double) -> Double {
        let sorted = scores.sorted { $0.offset < $1.offset }
        return { offset in
            guard let nearest = sorted.min(by: { abs($0.offset - offset) < abs($1.offset - offset) }) else { return 0 }
            return nearest.score
        }
    }

    // MARK: - Vision / Core Image per-frame signals (the platform edge)

    /// Decode one frame and compute its raw signals. `nil` if the frame can't be produced.
    private func signals(asset: AVAsset, atSeconds t: Double) async -> SceneFrameSignals? {
        guard let cg = await cgImage(asset: asset, atSeconds: t) else { return nil }
        return frameSignals(cg)
    }

    /// Raw Vision + Core Image signals for one decoded frame. Internal so the fixture test can drive it
    /// with synthesized sharp-vs-blurry images (the off-device proof that the scorer penalizes blur/empty).
    func frameSignals(_ cg: CGImage) -> SceneFrameSignals {
        SceneFrameSignals(
            sharpness: sharpnessEnergy(CIImage(cgImage: cg)),
            saliency: meanSaliency(cg),
            presence: subjectCoverage(cg)
        )
    }

    private func cgImage(asset: AVAsset, atSeconds t: Double) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .init(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = .init(seconds: 0.5, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 480, height: 480)   // downscale: Vision/CI cost + plenty for scoring
        let time = CMTime(seconds: t, preferredTimescale: 600)
        return try? await withCheckedThrowingContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, error in
                if let image { cont.resume(returning: image) }
                else { cont.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
    }

    /// Focus measure = mean squared Laplacian response on the luma. Blurry frame → near 0; sharp → high.
    private func sharpnessEnergy(_ image: CIImage) -> Double {
        let mono = image.applyingFilter("CIPhotoEffectMono")
        let laplacian = mono.applyingFilter("CIConvolution3X3", parameters: [
            "inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9),
            "inputBias": 0
        ])
        // Square the response (energy), then average over the frame.
        let squared = laplacian.applyingFilter("CIMultiplyCompositing",
                                               parameters: [kCIInputBackgroundImageKey: laplacian])
        let avg = squared.applyingFilter("CIAreaAverage",
                                         parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double((px[0] + px[1] + px[2]) / 3)
    }

    /// Mean attention-based saliency (0…1). Flat/empty frame → low; a clear subject → high.
    private func meanSaliency(_ cg: CGImage) -> Double {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNSaliencyImageObservation else { return 0 }
        let buffer = obs.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        let ptr = base.assumingMemoryBound(to: Float.self)
        var sum: Double = 0
        for y in 0..<h { for x in 0..<w { sum += Double(ptr[y * stride + x]) } }
        let n = Double(w * h)
        return n > 0 ? min(1, max(0, sum / n)) : 0
    }

    /// Fraction of the frame covered by detected faces or human bodies (0…1). No subject → 0.
    private func subjectCoverage(_ cg: CGImage) -> Double {
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        _ = try? handler.perform([faces, humans])
        let boxes = ((faces.results as? [VNDetectedObjectObservation]) ?? [])
            + ((humans.results as? [VNDetectedObjectObservation]) ?? [])
        guard !boxes.isEmpty else { return 0 }
        // Union is overkill; the largest box is a good, cheap subject-prominence proxy (boundingBox is
        // already normalized 0…1, so area is a coverage fraction).
        let largest = boxes.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0
        return min(1, max(0, largest))
    }

    private func avAsset(forLocalIdentifier id: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        let boxed: AssetBox = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: AssetBox(avAsset))
            }
        }
        return boxed.value
    }
}
