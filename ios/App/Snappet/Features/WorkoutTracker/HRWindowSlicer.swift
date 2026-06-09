import Foundation

/// **Pure** slicer that maps a session's HR series onto a single clip's capture window — the one
/// place that decides which heart-rate samples a tagged video shows. Foundation only (no AVFoundation
/// / SwiftData / Photos), so it runs in `SnappetTests` with no simulator.
///
/// Both the single-clip editor (`ClipEditorView`) and the multi-clip Studio (`StudioHRPlacement`)
/// route through this, so a video can never silently lose its HR overlay. The previous inline slice
/// (a strict `t >= start && t <= start+span` filter) returned **empty** whenever the window fell
/// between two sparse band samples, before the first sample (band connected late), or after the last
/// (a victory clip shot once HR stopped) — and an empty series makes the chart (needs ≥2 points) and
/// every overlay badge silently disappear, which read to users as "my video is missing HR" even
/// though the band was recording (the deep review's whole "element-vanishes" family).
///
/// Guarantees:
/// 1. **In-coverage** (the window overlaps `[firstSample.t, lastSample.t]`): returns the interior
///    samples plus **interpolated endpoints** at the window edges — so a window that lands in a gap
///    between sparse samples still yields a drawable, correctly-interpolated line.
/// 2. **Just outside coverage** (entirely before the first / after the last sample) but within
///    `clampTolerance` seconds of the nearest edge: returns a **flat last-known line** (the edge
///    sample held across the clip), so legitimate edge clips — captured inside the ±90 s media
///    discovery pad — still show HR instead of going blank.
/// 3. **Far outside coverage** (gap > `clampTolerance`), or an **empty** series: returns `[]`, the
///    honest "no heart-rate data" state (we don't fabricate a reading minutes away from any data).
///
/// When the result is non-empty it always has **≥ 2 points**, so the chart's `count >= 2` gate and the
/// overlay aggregates always have something to draw. Output `t` is rebased to `[0, span]` (clip-local).
enum HRWindowSlicer {

    /// Default clamp tolerance: the same ±90 s pad `SessionMediaService` uses to decide a video was
    /// "shot during this workout". A clip discovered inside that pad is, by definition, at most 90 s
    /// from the session edge — so clamping to the edge HR within this tolerance keeps edge clips
    /// non-blank, while anything further out (a cool-down clip filmed minutes later, a cross-day
    /// manual pick) stays honestly empty.
    static let defaultClampTolerance: Double = 90

    /// Slice `series` (session-relative `t`) to the clip window `[start, start + span]`, rebased to
    /// `[0, span]`. See the type doc for the in-coverage / edge-clamp / out-of-coverage contract.
    static func slice(_ series: [HRPoint], start: Double, span: Double,
                      clampTolerance: Double = defaultClampTolerance) -> [HRPoint] {
        let span = max(0.001, span)               // guard div-by-zero downstream (photos pass a default)
        let start = max(0, start)
        let end = start + span
        let sorted = series.sorted { $0.t < $1.t }
        guard let first = sorted.first, let last = sorted.last else { return [] }

        // Rebase an absolute-time point into the clip-local `[0, span]` frame.
        func rebased(_ p: HRPoint) -> HRPoint {
            HRPoint(t: min(span, max(0, p.t - start)), bpm: p.bpm, rrIntervalsMs: p.rrIntervalsMs)
        }
        // Two identical points spanning the clip — a flat "last known" line (edge clamp / single sample).
        func flat(_ p: HRPoint) -> [HRPoint] {
            [HRPoint(t: 0, bpm: p.bpm, rrIntervalsMs: p.rrIntervalsMs),
             HRPoint(t: span, bpm: p.bpm, rrIntervalsMs: p.rrIntervalsMs)]
        }

        // ── Out of coverage: clamp to the nearest edge only within tolerance, else honest-empty. ──
        if end < first.t {                                   // whole window before the first sample
            return (first.t - end) <= clampTolerance ? flat(first) : []
        }
        if start > last.t {                                  // whole window after the last sample
            return (start - last.t) <= clampTolerance ? flat(last) : []
        }

        // ── In coverage: interpolate the window endpoints + keep the interior samples. ──
        // Linear interpolation / endpoint-hold at an absolute time (same rule as `HRChartGeometry`).
        func value(at t: Double) -> HRPoint {
            if t <= first.t { return first }
            if t >= last.t { return last }
            for i in 0 ..< (sorted.count - 1) {
                let a = sorted[i], b = sorted[i + 1]
                if t >= a.t, t <= b.t {
                    let s = b.t - a.t
                    let f = s > 0 ? (t - a.t) / s : 0
                    return HRPoint(t: t, bpm: a.bpm + (b.bpm - a.bpm) * f, rrIntervalsMs: a.rrIntervalsMs)
                }
            }
            return last
        }

        var pts: [HRPoint] = [rebased(value(at: start))]
        for s in sorted where s.t > start && s.t < end { pts.append(rebased(s)) }
        pts.append(rebased(value(at: end)))

        // Collapse to a flat line if the window only ever touched a single distinct sample value
        // (e.g. a one-sample session, or both endpoints clamped to the same edge), so the chart's
        // ≥2-point gate still passes with a sensible reading.
        let distinctT = Set(pts.map { ($0.t * 1000).rounded() })
        if distinctT.count < 2 { return flat(pts[0]) }
        return pts
    }
}
