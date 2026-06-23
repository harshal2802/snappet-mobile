import Foundation
import CoreGraphics
import HighlightEngine

/// **Pure** geometry for the heart-rate chart overlay — Foundation/CoreGraphics only (no AVFoundation
/// / SwiftUI), so the line-mapping + the time→bpm sampling are unit-tested without a device. Both the
/// SwiftUI preview chart and the Core Animation export chart consume these normalized points, so they
/// draw the same line. The whole session's HR maps across the whole video, and the playhead dot tracks
/// the video's 0…1 progress (the "moving-playhead line").
enum HRChartGeometry {

    /// Padded bpm range for the y-axis (min…max with ~10% headroom). Falls back to a sane band for
    /// flat/empty data so the chart never divides by zero.
    static func bpmRange(_ samples: [HRPoint]) -> (min: Double, max: Double) {
        let bpms = samples.map(\.bpm).filter { $0 > 0 }
        guard let lo = bpms.min(), let hi = bpms.max(), hi > lo else {
            let c = bpms.first ?? 120
            return (Swift.max(40, c - 20), c + 20)
        }
        let pad = (hi - lo) * 0.1
        return (lo - pad, hi + pad)
    }

    /// Chart points normalized to the unit square: `x = t / maxT` (0…1), `y = (bpm − lo)/(hi − lo)`
    /// where **y = 1 is the highest bpm**. Empty for fewer than 2 samples.
    static func normalizedPoints(_ samples: [HRPoint]) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        let sorted = samples.sorted { $0.t < $1.t }
        guard let maxT = sorted.last?.t, maxT > 0 else { return [] }
        let (lo, hi) = bpmRange(sorted)
        let span = Swift.max(1, hi - lo)
        return sorted.map { CGPoint(x: $0.t / maxT, y: ($0.bpm - lo) / span) }
    }

    /// Interpolated bpm at a 0…1 fraction of the session timeline, or `nil` with no data.
    static func sampleBPM(_ samples: [HRPoint], atFraction f: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted { $0.t < $1.t }
        guard let maxT = sorted.last?.t, maxT > 0 else { return sorted.first?.bpm }
        let t = min(max(f, 0), 1) * maxT
        if t <= sorted.first!.t { return sorted.first!.bpm }
        if t >= sorted.last!.t { return sorted.last!.bpm }
        for i in 0 ..< (sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if t >= a.t, t <= b.t {
                let span = b.t - a.t
                let p = span > 0 ? (t - a.t) / span : 0
                return a.bpm + (b.bpm - a.bpm) * p
            }
        }
        return sorted.last!.bpm
    }

    /// A **dense, uniform-grid** version of a sliced clip window for *display* — so the curve renders
    /// smoothly and the playhead dot **glides** instead of snapping between a handful of raw points
    /// (HR-granularity epic / prompt 101). Reuses the engine's `HeartRateSeries` resampler+smoother
    /// (one resampler, not a second), then samples it back onto an `[HRPoint]` grid spanning `[0, maxT]`.
    ///
    /// Honesty: this adds **no** data. A 2-point (interpolation-only) window resamples to *collinear*
    /// points — still a straight line — so a sparse window can't masquerade as a measured curve (the
    /// overlay dashes it via `HRCadence.isSparse`). The win for sparse data is purely a smoothly-moving
    /// dot; for moderately/densely sampled windows it also smooths the curve and the zone-gradient stops.
    ///
    /// **Endpoints are preserved** (`t == 0` and `t == maxT`) so the chart still spans the full width and
    /// the playhead `fraction` (which divides by the window's `maxT`) stays aligned. Bounded to ~`maxPoints`
    /// (raising `dt` for long editor/session windows) so a full-session chart can't balloon the path.
    /// `< 2` samples or `maxT == 0` → the input is returned unchanged. Pure → unit-tested.
    static func displaySeries(_ samples: [HRPoint], maxPoints: Int = 240, minDt: Double = 0.5,
                              smoothingWindowSec: Double = 2) -> [HRPoint] {
        guard samples.count >= 2 else { return samples }
        let sorted = samples.sorted { $0.t < $1.t }
        guard let maxT = sorted.last?.t, maxT > 0 else { return samples }
        let dt = Swift.max(minDt, maxT / Double(Swift.max(2, maxPoints)))
        let hs = sorted.map { HRSample(t: $0.t, bpm: $0.bpm) }
        let series = HeartRateSeries.make(from: hs, duration: maxT, dt: dt,
                                          smoothingWindowSec: smoothingWindowSec,
                                          restBpm: nil, maxBpm: nil)
        let n = Swift.max(2, Int((maxT / dt).rounded()) + 1)
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1) * maxT
            return HRPoint(t: t, bpm: series.bpm(at: t))
        }
    }

    /// Normalized y (0…1, 1 = top) for a bpm value, using the chart's padded range.
    static func normalizedY(forBPM bpm: Double, in samples: [HRPoint]) -> Double {
        let (lo, hi) = bpmRange(samples)
        return min(1, max(0, (bpm - lo) / Swift.max(1, hi - lo)))
    }

    // MARK: - Premium HR-curve recipe (the redesign — preview == export)

    /// A **smooth** curve through already-mapped points, as a `CGPath` — Catmull-Rom converted to
    /// cubic béziers: `c1 = p1 + (p2−p0)/6`, `c2 = p2 − (p3−p1)/6`. Coordinate-space agnostic (both the
    /// SwiftUI preview and the Core-Animation export map their normalized points into their OWN space
    /// first, then call this), so the curve is identical on both sides — WYSIWYG. A `CGPath` because
    /// SwiftUI's `Path(cgPath)` and Core Animation's `CAShapeLayer.path` both consume it directly.
    /// Fewer than 2 points → an empty path; exactly 2 → a straight segment.
    static func smoothedPath(through pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count >= 3 else {
            if pts.count == 2 { path.addLine(to: pts[1]) }
            return path
        }
        for i in 0 ..< (pts.count - 1) {
            let p0 = pts[Swift.max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[Swift.min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// The index of the curve's **peak** (highest-bpm normalized point — `y` is largest, since `y = 1`
    /// is the top). Drives the single baked "peak" label above the hump. `nil` for an empty input.
    static func peakIndex(_ pts: [CGPoint]) -> Int? {
        guard !pts.isEmpty else { return nil }
        return pts.indices.max(by: { pts[$0].y < pts[$1].y })
    }

    /// The peak (max) bpm over the samples, for the baked peak label. `nil` with no positive samples.
    static func peakBPM(_ samples: [HRPoint]) -> Double? {
        samples.map(\.bpm).filter { $0 > 0 }.max()
    }

    /// One stop of the **zone-banded stroke gradient** (the curve greens through the aerobic plateau
    /// and reddens into the peak): a normalized x (0…1) along the curve and the repo zone colour at the
    /// bpm there. Pure — no SwiftUI; the renderers turn the hex into their platform colour.
    struct ZoneStop: Equatable, Sendable { var location: Double; var hex: String }

    /// The zone-banded stroke gradient stops along x — each sample coloured by ITS bpm's zone, using the
    /// repo `HeartRateZone` ramp (one source of truth with every pill). `x = t / maxT`. Fewer than 2
    /// positive samples → empty (a flat-colour fallback is the renderer's job). Locations are clamped to
    /// [0,1] and non-decreasing (the renderer can feed them straight to a gradient layer).
    static func zoneStops(_ samples: [HRPoint], maxHR: Double) -> [ZoneStop] {
        let sorted = samples.sorted { $0.t < $1.t }
        guard let maxT = sorted.last?.t, maxT > 0, sorted.count >= 2 else { return [] }
        var last = 0.0
        return sorted.map { p in
            let loc = Swift.min(1, Swift.max(last, p.t / maxT)); last = loc
            return ZoneStop(location: loc, hex: HeartRateZone.forBpm(p.bpm, maxHR: maxHR).colorHex)
        }
    }
}
