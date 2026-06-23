# Prompt: HR→video granularity — epic (maximize realtime HR detail + derive all metrics)

**File**: pdd/prompts/features/99-ios-hr-granularity-epic.md
**Created**: 2026-06-23
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips playback (82–98) → HR-granularity initiative (this epic) → phases 100–106.
**Source**: User-reported "30s video, only 2 HR datapoints" on the Clips overlay (Orange V5).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

A tagged ~30s climbing clip shows an HR overlay that is a near-straight 2-point line (AVG 135 /
PEAK 139) — far below the data the sensors can give. A deep review (workflow `wf_0d9641d0-75a` +
direct read) established the pipeline and root cause, and proposed a ranked plan. This epic delivers
the whole plan: maximize the granularity of realtime HR tied to video, render it honestly, and derive
the full metric set from the dense series.

## Root cause (verified)

Capture sparsity, **not** rendering or persistence. `WorkoutHRStats.points(from:)` is a strict 1:1
copy (no downsampling); the Clips feed reads each session's `hrSeries` after `end()` has flushed the
full buffer; `HRWindowSlicer.slice` is correct. The flat line is the slicer's two **interpolated
endpoints** when **zero raw samples land inside** the clip window — the Apple-Watch signature
(`HKLiveWorkoutBuilder.mostRecentQuantity()` surfaces HR only ~every 5–15s, duty-cycled). BLE chest
straps already deliver ~1 Hz + RR. One real bug compounds it: the watch-side
`WatchConnectivityLink.send` drops samples on a `sendMessage` failure (no `transferUserInfo` fallback).

## Phases (one prompt = one job = one PR)

- **100 — Phase A (M5) capture fixes.** Watch silent-drop fallback; pure `HRCadence` diagnostic
  (count / span / samples-per-sec / median+max gap) reused by Phase B; decisions note on the
  live-session-in-feed flush gap.
- **101 — Phase B (M1) display resample + honest styling.** Route the sliced clip window through the
  engine `HeartRateSeries` resampler so the chart + live dot are smooth (Catmull-Rom engages) on both
  the SwiftUI preview and the export. **AVG/PEAK stay computed from RAW samples.** Low-confidence
  styling when the window is interpolation-dominated (uses `HRCadence`). Directly fixes the screenshot.
- **102 — Phase C (Opt 1) watch HealthKit post-hoc densification.** At session end, re-read HK
  `heartRate` for `[startedAt,endedAt]` and merge the denser-of-two into `hrSeries` (pure merge fn +
  device-gated read; deferred re-densify on detail appear; graceful no-op for BLE-only).
- **103 — Phase D (Opt 4) steer to BLE strap.** Bias `LiveMetricsCoordinator.resolve` toward a
  connected band for clip-grade HR (honor explicit picks) + picker affordance.
- **104 — Phase E–G (consolidated) new HR metrics from dense data.** Add overlay metric cases from the
  existing engine types: **M2** time-to-peak / HR-rise / HR-recovery (from `ClimbEffort`, gated on a
  non-sparse window) and **M4** SDNN / pNN50 (from the `HRVMetrics` the overlay already receives, RR-gated).
  E/F/G were merged into one PR because they all churn the same `HROverlayMetric` exhaustive switches.
  **M3's per-second zone tint already shipped in Phase B** (the zone-gradient now reads the dense
  `chartSamples`). **Deferred (documented):** the standalone normalized-`slope` ramp readout (cadence-fragile,
  low interpretability — the zone-tinted curve already conveys intensity dynamics) and the
  `RecoveryReadiness` RR-rebound (needs a session HRV baseline not available at clip scope);
  `HKHeartbeatSeriesQuery` beat-to-beat RR for watch HRV remains a future follow-on.

## Invariant across the epic

Aggregates (AVG/PEAK/zone dwell/TRIMP/kcal) from **raw** sliced samples; the rendered line/dot from
the **resampled** grid. All compute stays in `HighlightEngine` or pure app helpers
(`HRWindowSlicer`, `HRChartGeometry`, `HROverlayValues`, `HRCadence`) — unit-tested with no simulator.
Only the Phase C HealthKit read and the watch relay fix are device-gated.

## Acceptance criteria

- [ ] Each phase ships its own prompt, code, tests, and `docs/knowledge-graph/data.js` + `decisions.md`
      updates.
- [ ] Engine changes pass `swift test`; app changes type-check (Swift 6, 0 warnings); `SnappetTests` green.
- [ ] No platform imports in `HighlightEngine`.
- [ ] Device-gated legs (watch relay, HK read, BLE cadence) flagged honestly as type-check ≠ device run.
