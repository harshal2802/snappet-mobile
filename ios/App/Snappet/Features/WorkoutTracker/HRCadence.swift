import Foundation

/// **Pure** cadence diagnostic for a heart-rate series — how *dense* the captured samples actually are
/// over a window. Foundation only (no AVFoundation / SwiftData), so it unit-tests in `SnappetTests`.
///
/// The whole "30s clip shows a flat 2-point line" symptom is a capture-cadence problem: the persisted
/// `hrSeries` is faithful (1:1, no downsampling) but the live source delivered few samples (an Apple
/// Watch surfaces HR only ~every 5–15 s vs a BLE strap's ~1 Hz). This type lets the app *measure* that:
/// Phase B's overlay reads `isSparse(windowSec:)` to style an interpolation-dominated window honestly
/// (instead of dressing two interpolated endpoints up as a measured curve), and a debug surface can show
/// the raw cadence numbers to confirm on device.
struct HRCadence: Equatable, Sendable {
    /// Number of samples in the series.
    let count: Int
    /// Seconds from the first to the last sample (0 for empty / single-sample series).
    let spanSec: Double
    /// Effective samples per second over the span (`(count - 1) / spanSec`); 0 when there's no span.
    /// Uses intervals, not points, so a 31-sample / 30 s window reads as ~1.0 Hz, not 1.03.
    let perSecond: Double
    /// Median gap (seconds) between consecutive samples; 0 with fewer than 2 samples.
    let medianGapSec: Double
    /// Largest gap (seconds) between consecutive samples — the worst "hole" in coverage; 0 with < 2.
    let maxGapSec: Double

    static let empty = HRCadence(count: 0, spanSec: 0, perSecond: 0, medianGapSec: 0, maxGapSec: 0)

    /// Summarize a series' cadence. Order-independent (sorts by `t`). Non-positive gaps (duplicate
    /// timestamps) are kept as 0 so they can't inflate the rate.
    static func summarize(_ series: [HRPoint]) -> HRCadence {
        guard series.count >= 2 else {
            return HRCadence(count: series.count, spanSec: 0, perSecond: 0, medianGapSec: 0, maxGapSec: 0)
        }
        let ts = series.map(\.t).sorted()
        let span = max(0, ts.last! - ts.first!)
        var gaps: [Double] = []
        gaps.reserveCapacity(ts.count - 1)
        for i in 1..<ts.count { gaps.append(max(0, ts[i] - ts[i - 1])) }
        let perSecond = span > 0 ? Double(ts.count - 1) / span : 0
        return HRCadence(count: series.count, spanSec: span, perSecond: perSecond,
                         medianGapSec: HRCadence.median(gaps), maxGapSec: gaps.max() ?? 0)
    }

    /// Whether a clip window of `windowSec` is too sparsely sampled to render as a *measured* curve —
    /// i.e. the line would be mostly interpolation. True when the effective rate is below
    /// `minPerSecond` (default 0.2 Hz ≈ one sample / 5 s, the Apple-Watch live ceiling), OR the worst
    /// gap covers more than `maxGapFraction` of the window (a single hole swallowing most of the clip),
    /// OR there are fewer than 2 samples. A ~1 Hz strap window is never sparse; a 2-points-in-30s window
    /// always is. Thresholds are deliberately conservative so the honest-styling only fires when the
    /// curve genuinely lacks interior detail.
    func isSparse(windowSec: Double, minPerSecond: Double = 0.2, maxGapFraction: Double = 0.6) -> Bool {
        guard count >= 2 else { return true }
        if perSecond < minPerSecond { return true }
        if windowSec > 0, maxGapSec > windowSec * maxGapFraction { return true }
        return false
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}
