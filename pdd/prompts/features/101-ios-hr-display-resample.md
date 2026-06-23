# Prompt: HR overlay — smooth resampled curve + honest sparse styling (Phase B / M1)

**File**: pdd/prompts/features/101-ios-hr-display-resample.md
**Created**: 2026-06-23
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: HR-granularity epic (99) → Phase B. Follows Phase A (100, `HRCadence`).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the clip HR curve render smoothly and **honestly** regardless of how sparsely the source sampled
HR. Today a window with few interior samples draws as a flat 2-point line and the playhead dot **snaps**
between the two points as it crosses the midpoint. After this phase the dot glides, the curve is smooth
where there is interior detail, and a genuinely interpolation-dominated window is styled as
low-confidence (dashed) rather than passed off as a measured reading. This directly improves the
reported screenshot. It adds **no fabricated data** — a sparse window stays a straight (now dashed) line.

## Context the implementer needs

- The chart is drawn from the sliced clip window (`HROverlayValues.samples`, the `HRWindowSlicer` output,
  always ending at `t == durationSec`). Two consumers: the SwiftUI `PremiumHRCurve` (in `HRTileView`,
  the feed + editor preview) and the Core-Animation `StudioOverlays.tileChartLayer` (the export) — both
  via the shared pure `HRChartGeometry`. They must stay WYSIWYG-identical.
- `HRChartGeometry.smoothedPath` already Catmull-Rom-smooths ≥3 points; with exactly 2 it draws a line,
  and the dot (`pts.min{ |x−f| }`) snaps between the 2 points.
- The engine already owns a uniform-grid resampler+smoother: `HeartRateSeries.make(from:duration:dt:
  smoothingWindowSec:restBpm:maxBpm:)` (HighlightEngine). Reuse it — do not write a second resampler.
- **Invariant (from the epic):** the rendered line/dot come from the **resampled** grid; AVG/PEAK/zone
  dwell/kcal stay computed from the **raw** sliced samples (`WorkoutHRStats.make`). Smoothing must never
  shave the displayed peak.
- Perf: the feed is render-sensitive (the carousel perf saga). Resample **once** per payload in
  `HROverlayValues.init` (a value type built when the payload is made) — never inside `PremiumHRCurve.body`.

## Approach

- **Pure resampler.** Add `HRChartGeometry.displaySeries(_ samples:maxPoints:minDt:smoothingWindowSec:)`
  → a dense `[HRPoint]` over `[0, maxT]` via `HeartRateSeries.make`, bounded to ~`maxPoints` (raise `dt`
  for long editor windows so a full-session chart can't balloon). `< 2` samples / `maxT == 0` → returns
  the input unchanged. Add `import HighlightEngine` to HRChartGeometry.swift.
- **HROverlayValues.** Store `chartSamples = displaySeries(samples)`, `cadence = HRCadence.summarize(samples)`,
  `isSparseChart = cadence.isSparse(windowSec: durationSec)`, `rawPeakBpm = stats?.maxBpm`. Point
  `bpm(atFraction:)` at `chartSamples` so the live BPM number matches the gliding dot.
- **PremiumHRCurve.** Caller passes `values.chartSamples` (already dense). Add `rawPeakBpm:` (peak label
  shows the RAW peak) and `sparse:` (dashed stroke + dimmed area). Update the `HRTileView` call sites.
- **Export parity.** In `StudioOverlays.tileChartLayer`, resample `samples` via the SAME `displaySeries`
  before drawing, use the raw `peakBPM(samples)` for the label, and apply the dashed style when the window
  is sparse — so the burn-in matches the preview.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/HRChartGeometry.swift` — `displaySeries` + `import HighlightEngine`.
- `ios/App/Snappet/Features/WorkoutTracker/HROverlayValues.swift` — chartSamples / cadence / isSparseChart /
  rawPeakBpm; `bpm(atFraction:)` on chartSamples.
- `ios/App/Snappet/Features/WorkoutTracker/HRTileView.swift` — PremiumHRCurve reads chartSamples + new params.
- `ios/App/Snappet/Services/StudioOverlays.swift` — export resamples + raw peak + dashed-when-sparse.
- `ios/App/SnappetTests/HRChartGeometryTests.swift` (+ HROverlayValues tests) — displaySeries: endpoints
  preserved (t spans [0,maxT]), a 2-point window stays collinear (no fabricated wiggle), bounded count,
  dense window densifies; isSparseChart true for 2-in-30s, false for ~1 Hz; AVG/PEAK still from raw.
- `docs/knowledge-graph/data.js` + `pdd/context/decisions.md` — record the resample seam + the invariant.

## Acceptance criteria

- [ ] A sparse clip's dot **glides** (no midpoint snap); the line stays straight + **dashed** (honest),
      not a fabricated curve.
- [ ] A window with interior detail renders a smooth curve; a ~1 Hz window is solid (not dashed).
- [ ] Displayed AVG/PEAK are unchanged (still raw); the peak label equals the raw peak.
- [ ] Preview == export (both resample via `displaySeries`, same dashed styling).
- [ ] App type-checks (Swift 6, 0 warnings); `SnappetTests` green; no platform imports in `HighlightEngine`.

## Constraints

- Pure/Foundation compute; unit-tested. Resample once per payload (perf). Add no second resampler.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — green incl. new geometry/overlay tests.
2. Device/sim: a sparse clip shows a gliding dot on a dashed straight line; a dense clip shows a smooth
   solid curve; both match the exported reel.
