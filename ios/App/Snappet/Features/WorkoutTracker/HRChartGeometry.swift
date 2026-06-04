import Foundation
import CoreGraphics

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

    /// Normalized y (0…1, 1 = top) for a bpm value, using the chart's padded range.
    static func normalizedY(forBPM bpm: Double, in samples: [HRPoint]) -> Double {
        let (lo, hi) = bpmRange(samples)
        return min(1, max(0, (bpm - lo) / Swift.max(1, hi - lo)))
    }
}
