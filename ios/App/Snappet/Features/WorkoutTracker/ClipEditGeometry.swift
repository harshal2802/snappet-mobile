import Foundation
import CoreGraphics

/// Pure geometry + timing math for the non-destructive clip editor (B3).
///
/// **Isolated from AVFoundation on purpose** — every function here takes plain numbers /
/// `CGSize` / `CGRect` / `CGPoint` value types and returns the same, so the trim→range,
/// speed→duration, crop-rect→transform, normalized-position→point, and output-aspect→renderSize
/// math is unit-tested in `SnappetTests` with **no device, no AVFoundation, no SwiftUI** (the
/// same testability discipline that keeps `HighlightEngine` platform-free). `VideoStudio`
/// (`Services/`) consumes these to build the actual `AVMutableComposition` /
/// `AVMutableVideoComposition`; the seconds here become `CMTime`s there.
///
/// All values are in *seconds* (time) or *normalized 0…1* (crop rect / overlay position),
/// resolution-independent so the same edit applies at any render size.
enum ClipEditGeometry {

    // MARK: - Output aspect → render size

    /// The output canvas a clip is normalized into — the single place mixed-orientation
    /// reels are unified (a portrait + a landscape source both render into one `renderSize`,
    /// closing the deferred mixed-orientation gap, decisions.md 2026-05-31 / RESEARCH §3.5).
    enum OutputAspect: String, Codable, Sendable, CaseIterable, Identifiable {
        case portrait9x16   // 9:16 — the reel default
        case square1x1      // 1:1
        case landscape16x9  // 16:9
        case original       // keep the source's own size

        var id: String { rawValue }

        var label: String {
            switch self {
            case .portrait9x16: return "9:16"
            case .square1x1: return "1:1"
            case .landscape16x9: return "16:9"
            case .original: return "Original"
            }
        }

        /// The width:height ratio, or `nil` for `.original` (which uses the source size).
        var ratio: CGFloat? {
            switch self {
            case .portrait9x16: return 9.0 / 16.0
            case .square1x1: return 1.0
            case .landscape16x9: return 16.0 / 9.0
            case .original: return nil
            }
        }
    }

    /// The render size for an output aspect, given the natural (orientation-applied) source size.
    /// `.original` returns the source size unchanged; the fixed aspects scale to a canvas whose
    /// **longer side matches the source's longer side** (so we never upscale beyond the source),
    /// rounded to even integers (H.264 requires even dimensions). Always positive.
    static func renderSize(for aspect: OutputAspect, sourceSize: CGSize) -> CGSize {
        let srcW = max(2, abs(sourceSize.width))
        let srcH = max(2, abs(sourceSize.height))
        guard let ratio = aspect.ratio else {
            return CGSize(width: evenDimension(srcW), height: evenDimension(srcH))
        }
        // Base the canvas on the source's longer edge so quality is preserved.
        let longEdge = max(srcW, srcH)
        let w: CGFloat
        let h: CGFloat
        if ratio >= 1 {            // wide or square: long edge is the width
            w = longEdge
            h = longEdge / ratio
        } else {                   // tall: long edge is the height
            h = longEdge
            w = longEdge * ratio
        }
        return CGSize(width: evenDimension(w), height: evenDimension(h))
    }

    /// Round up to the nearest even integer ≥ 2 (H.264 needs even width/height).
    static func evenDimension(_ value: CGFloat) -> CGFloat {
        let v = max(2, value.rounded())
        return v.truncatingRemainder(dividingBy: 2) == 0 ? v : v + 1
    }

    // MARK: - Trim → time range (seconds)

    /// A validated, clamped trim window in seconds: `start < end`, both within
    /// `[0, assetDuration]`. Used to build the source `CMTimeRange` in `VideoStudio`.
    struct TimeWindow: Equatable, Sendable {
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }

    /// Clamp a requested `[start, end]` trim to a valid window inside `[0, assetDuration]`.
    ///
    /// - `start` is clamped to `[0, assetDuration]`; `end` to `[0, assetDuration]`.
    /// - If the resulting `end <= start` (degenerate / inverted), the window collapses to a
    ///   tiny `minDuration` slice anchored at `start` (clamped so it stays in bounds) so the
    ///   composition never gets a zero/negative range. Returns `nil` only if the asset itself
    ///   has no positive duration.
    static func trimWindow(start: Double, end: Double, assetDuration: Double,
                           minDuration: Double = 0.05) -> TimeWindow? {
        guard assetDuration > 0 else { return nil }
        let lo = min(max(0, start), assetDuration)
        let hi = min(max(0, end), assetDuration)
        if hi - lo >= minDuration {
            return TimeWindow(start: lo, end: hi)
        }
        // Degenerate: carve a minimal slice that stays inside the asset.
        let s = min(lo, max(0, assetDuration - minDuration))
        return TimeWindow(start: s, end: min(assetDuration, s + minDuration))
    }

    // MARK: - Split → two adjacent, non-overlapping trims

    /// Split a trim window at `at` seconds into two adjacent, non-overlapping windows
    /// `[start, at]` and `[at, end]`. `at` is clamped strictly inside `(start, end)` so
    /// **both** halves keep at least `minDuration`. Returns `nil` if the window is too short
    /// to split into two valid halves.
    static func split(_ window: TimeWindow, at: Double,
                      minDuration: Double = 0.05) -> (TimeWindow, TimeWindow)? {
        guard window.duration >= minDuration * 2 else { return nil }
        let lo = window.start + minDuration
        let hi = window.end - minDuration
        let cut = min(max(at, lo), hi)
        return (TimeWindow(start: window.start, end: cut),
                TimeWindow(start: cut, end: window.end))
    }

    // MARK: - Speed → scaled output duration

    /// Clamp a speed multiplier to the supported range (slow-mo 0.25× … fast 4×).
    static func clampSpeed(_ speed: Double, min lo: Double = 0.25, max hi: Double = 4.0) -> Double {
        Swift.min(Swift.max(speed, lo), hi)
    }

    /// The output duration after applying `speed` to a `sourceDuration` (seconds).
    /// `scaleTimeRange` in `VideoStudio` maps a source range of `sourceDuration` onto a target
    /// range of `sourceDuration / speed` — 2× halves the duration, 0.5× doubles it. Speed is
    /// clamped first, so the result is always positive for a positive source.
    static func scaledDuration(sourceDuration: Double, speed: Double) -> Double {
        let s = clampSpeed(speed)
        return sourceDuration / s
    }

    // MARK: - Crop rect / transform → layer-instruction transform

    /// Map a **normalized** crop rect (origin + size in 0…1 of the source) plus an
    /// orientation-applied `sourceSize` onto the affine transform that scales-and-translates
    /// the *cropped* region to fill `renderSize` (aspect-fill, centered). This is what
    /// `AVMutableVideoCompositionLayerInstruction.setTransform` receives.
    ///
    /// The crop rect is sanitized (clamped into the unit square, with a non-zero minimum size)
    /// so a degenerate rect can't produce an infinite/NaN scale. A full-frame crop
    /// (`0,0,1,1`) reduces to a plain aspect-fill of the whole source into `renderSize`.
    static func cropTransform(cropRect: CGRect, sourceSize: CGSize,
                              renderSize: CGSize) -> CGAffineTransform {
        let crop = sanitizedCropRect(cropRect)
        let srcW = max(1, abs(sourceSize.width))
        let srcH = max(1, abs(sourceSize.height))

        // The cropped region in source pixels.
        let cropW = max(1, crop.width * srcW)
        let cropH = max(1, crop.height * srcH)
        let cropOriginX = crop.minX * srcW
        let cropOriginY = crop.minY * srcH

        // Aspect-fill the cropped region into the render canvas.
        let scale = max(renderSize.width / cropW, renderSize.height / cropH)

        // After scaling the whole source by `scale`, translate so the crop's top-left lands
        // at the canvas origin, then center any overflow.
        let scaledCropW = cropW * scale
        let scaledCropH = cropH * scale
        let centerX = (renderSize.width - scaledCropW) / 2
        let centerY = (renderSize.height - scaledCropH) / 2
        let tx = centerX - cropOriginX * scale
        let ty = centerY - cropOriginY * scale

        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }

    /// Clamp a crop rect into the unit square with a minimum 5% side so it can't collapse.
    static func sanitizedCropRect(_ rect: CGRect) -> CGRect {
        let minSide: CGFloat = 0.05
        var w = min(max(rect.width, minSide), 1)
        var h = min(max(rect.height, minSide), 1)
        var x = min(max(rect.minX, 0), 1 - w)
        var y = min(max(rect.minY, 0), 1 - h)
        if !x.isFinite { x = 0 }
        if !y.isFinite { y = 0 }
        if !w.isFinite { w = 1 }
        if !h.isFinite { h = 1 }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Normalized overlay position → layer point

    /// Map a normalized overlay position (`x,y` in 0…1, **top-left origin** like SwiftUI) to a
    /// point in a `CALayer`'s coordinate space (**bottom-left origin, y flipped**) for the
    /// given canvas size. Used to place each `TextOverlay` in the Core Animation layer tree.
    static func layerPoint(normalized: CGPoint, in size: CGSize) -> CGPoint {
        let x = min(max(normalized.x, 0), 1) * size.width
        let yTopDown = min(max(normalized.y, 0), 1) * size.height
        return CGPoint(x: x, y: size.height - yTopDown)   // flip to CALayer's bottom-left origin
    }
}
