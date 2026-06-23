# Prompt: New HR overlay metrics from the dense series (Phase E–G consolidated)

**File**: pdd/prompts/features/104-ios-hr-new-metrics.md
**Created**: 2026-06-23
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: HR-granularity epic (99) → Phases E/F/G, merged (they churn the same enum switches).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

With capture densified (A/C) and the curve resampled (B), surface the richer metrics dense HR unlocks as
configurable overlay tiles — all from engine types that already compute them, so this is wiring + honest
gating, not new physiology.

## Scope (and what's deferred)

- **M2 effort metrics** (from `ClimbEffort`): `timeToPeak`, `hrRise`, `hrRecovery` (drop after the peak).
- **M4 HRV metrics** (from the `HRVMetrics` the overlay already receives): `sdnn`, `pnn50`.
- **M3 zone tint already shipped in Phase B** — `HRChartGeometry.zoneStops` now reads the dense
  `chartSamples`, so the stroke greens-through-aerobic / reddens-into-peak smoothly. Nothing to add.
- **Deferred, documented:** the standalone normalized-`slope` ramp readout (cadence-fragile + hard to read
  as an absolute number; the zone-tinted curve already shows intensity dynamics), and the
  `RecoveryReadiness` RR-rebound (needs a session HRV baseline, not available at single-clip scope).
  Beat-to-beat watch RR via `HKHeartbeatSeriesQuery` stays a future follow-on (HRV is chest-strap-only now).

## Context the implementer needs

- `HROverlayMetric` (StudioProject.swift) is a `String` enum with **exhaustive** switches in
  `label`/`systemImage`/`explanation`/`supportsLive` (StudioProject) and `tilePriority`/`tileCaption`/
  `tileValueChars` (HRTileLayout), plus `HROverlayValues.staticValue`. New cases must extend all of them.
- `ClimbEffort.make(from:start:end:restBpm:maxBpm:)` returns `timeToPeak`/`hrRise`/`hrRecovery60`/`30`
  (each `Optional`, `nil` when unavailable — e.g. recovery needs the series to reach `peak+60/30s`, so a
  short clip honestly hides it). The effort metrics are only meaningful with interior detail → gate them
  on `!isSparseChart` (the Phase A/B sparse signal) so they don't appear on an interpolated 2-point window.
- `HRVMetrics` already carries `sdnn`/`pnn50` (pnn50 is a 0–1 fraction → show as %); the overlay receives
  `hrv`, and `.hrv` (rmssd) already renders — so sdnn/pnn50 piggyback (hidden wherever rmssd is, e.g. the
  feed where `hrv == .empty`).

## Approach

- Add 5 static `HROverlayMetric` cases (`timeToPeak`, `hrRise`, `hrRecovery`, `sdnn`, `pnn50`); extend the
  4 StudioProject switches + 3 HRTileLayout switches.
- `HROverlayValues`: compute a `ClimbEffort` once in `init` (raw `samples`, window `[0, durationSec]`);
  render the 3 effort metrics in `staticValue` (gated `!isSparseChart`, positive deltas) and sdnn/pnn50
  from `hrv`. All static (no live/animation).

## Output

- `ios/App/Snappet/Features/WorkoutTracker/StudioProject.swift` — 5 new cases + switch arms.
- `ios/App/Snappet/Features/WorkoutTracker/HRTileLayout.swift` — priority/caption/valueChars arms.
- `ios/App/Snappet/Features/WorkoutTracker/HROverlayValues.swift` — ClimbEffort + staticValue arms.
- `ios/App/SnappetTests/HROverlayValuesTests.swift` — effort metrics on a dense rising/falling clip;
  hidden on a sparse window; sdnn/pnn50 from a supplied `hrv`; hidden when `hrv == .empty`.
- `docs/knowledge-graph/data.js` + `pdd/context/decisions.md`.

## Acceptance criteria

- [ ] The 5 metrics are selectable in the Studio overlay builder and render real values on a dense clip.
- [ ] Effort metrics are hidden on a sparse/interpolated window; HRV metrics hidden without RR (feed).
- [ ] App type-checks (Swift 6, 0 warnings); `SnappetTests` green; no platform imports in `HighlightEngine`.

## Constraints

- Reuse the engine types (no new physiology). Honest gating over fabricated readings. On-device only.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — green incl. new overlay-metric tests.
2. Sim: enable the new tiles in the Studio editor on a session with HR; confirm they render/hide correctly.
