# Prompt: Studio — extended HR window per clip (lead-in / tail / metrics scope)

**File**: pdd/prompts/features/115-studio-extended-hr-window.md
**Created**: 2026-07-09
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone (user feature request, out of the clips/export WYSIWYG family: prompts 82 · 89 · 101).
**Source**: user report — a Clips-feed screenshot vs a Studio-export screenshot of the same clip showed
two different HR charts (the export had burned the WHOLE session's HR + session totals, e.g. 584 kcal
on a ~30 s clip), which surfaced both a bug and a feature wish.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes**: `docs/ux-research/studio-hr-window/wireframes.html` (approved: Variant A styling,
defaults lead 0:05 / tail 0:30, Full-window metrics scope default)

## Goal

A hard move's heart-rate story doesn't end when the camera stops — HR typically peaks 10–30 s *after*
a max effort. Give each Studio clip a configurable **extended HR window**: the tile's chart draws
`[clip_start − lead, clip_end + tail]` while the live playhead dot + BPM still track the video exactly
across the footage span. The off-camera regions get honest "Variant A" styling (faint zone-tinted
washes + ember boundary ticks; the curve stays solid — the data is real, only camera coverage
differs). A per-clip **metrics scope** picks whether AVG/PEAK/KCAL/HRV cover the footage only or the
full window (default: full window — the feature exists to surface the off-camera peak).

Also fix the bug the user actually hit: a `TimelineClip` whose `sessionMediaID` link is lost fell
through to the **session-wide** HR burn (whole-session chart + totals). Recover the capture offset via
the denormalized PHAsset `localIdentifier` so per-clip slicing (and lead/tail) keep working.

## Context the implementer needs

- The per-clip export path: `StudioEditorViewModel.clipHRContent()` → `StudioHRPlacement.sample`
  (footage capture window, `HRWindowSlicer`) → `HROverlayValues.resolveTile` → `StudioClipHRContent`
  → `StudioComposer` → `StudioOverlays.hrTileLayer`/`tileChartLayer`. The preview twin:
  `previewHR`/`previewOverlayValues`/`previewElementFraction` → `HRTileView`/`PremiumHRCurve`.
- The chart's x-axis denominator is the last sliced sample's window-local `t` (`maxT`), NOT the
  nominal span — `HRWindowSlicer` endpoint-holds at the data edge, so a tail past coverage shows up
  as `maxT < span`. Every new fraction must divide by `maxT` or the dot/panes/curve drift.
- Every fraction domain (chart x, `bpm(atFraction:)`, animated segments) is window-local; the video
  occupies the `[lead, lead + footage]` sub-range once the window extends. Segments' `start`/`end`
  must STAY in video-fraction domain (the export gates them onto the clip's output slot).
- The Clips feed (`ClipHROverlay`) and the Recap/reel exporter build `HROverlayValues` without a
  window — they must render byte-identically to before (window `nil` = identity everywhere).

## Approach

One pure concept threaded through both renderers:

- `HRClipWindow` (new, pure): lead/footage/tail seconds + `footageStartFraction(maxT:)` /
  `footageEndFraction(maxT:)` / `chartFraction(videoFraction:maxT:)`; `HRWindowRegionStyle` = the
  shared Variant-A colors; `HRMetricsScope` (`clip` / `window`).
- `TimelineClip`: optional `hrLeadSec` / `hrTailSec` / `hrMetricsScopeRaw` (migration-safe additive
  Codable, like `adjust`/`volume`); effective accessors defaulting to 5 s / 30 s / `.window`.
  `StudioProjectEditor.setClipHRWindow` mutates; `nil` clears back to "track the default".
- `StudioHRPlacement.extendedWindow` (lead clamped at session t=0) + `sampleExtended` (returns
  samples + window per clip); legacy `sample` unchanged in behaviour. `resolveOffsets` = the pure
  mediaID→localIdentifier fallback rule.
- `HROverlayValues`: optional `window` + `statsSamples`/`statsDurationSec` (footage-only aggregates
  under `.clip` scope); `chartFraction(forVideoFraction:)`; animated segments resolve readings at
  mapped fractions; `resolveTile` carries the window into `ResolvedHRTile.window`.
- `HRChartGeometry.playheadKeyframes`: dot enters at the lead boundary (keyTime 0), sweeps the
  footage, **parks** at the tail boundary (keyTime 1); boundary y/bpm interpolated; identity without
  a window.
- Renderers: region panes + boundary ticks in `PremiumHRCurve` (preview) and
  `StudioOverlays.tileChartLayer` (export), both from `HRWindowRegionStyle` + the same fractions.
- VM/UI: `scopedOverlayValues` (ONE builder for preview badges + export burn), window-aware
  `previewHR`/`previewElementFraction`, `HRWindowControls` section in the Studio HR tool (mini-map,
  Lead-in/Tail sliders, honest clamp hint, Metrics-over picker, Reset) targeting the clip under the
  playhead; `captureOffset` falls back to the `localIdentifier` map.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/HRClipWindow.swift` (new)
- Edits: `StudioProject.swift`, `StudioProjectEditor.swift`, `StudioHRPlacement.swift`,
  `HROverlayValues.swift`, `HRChartGeometry.swift`, `HRTileView.swift`, `StudioOverlays.swift`,
  `StudioEditorViewModel.swift`, `StudioEditorView.swift`
- `ios/App/SnappetTests/HRClipWindowTests.swift` (new)
- Docs: knowledge-graph node/edge, `decisions.md` entry, this prompt.

## Acceptance criteria

- [ ] A clip with defaults exports a chart spanning `[start−5 s, end+30 s]`; the burned dot enters at
      the lead boundary, sweeps only the footage, and parks at the footage/tail boundary.
- [ ] Preview == export: same panes, same boundary fractions, same dot behaviour, same aggregates.
- [ ] `.clip` scope restores footage-only AVG/PEAK/KCAL/HRV; `.window` includes the tail peak.
- [ ] Lead/tail = 0/0 renders byte-identically to pre-115 (no panes, keyTime = x).
- [ ] The Clips feed and Recap/reel exports are untouched (window `nil` end to end).
- [ ] An unlinked clip (lost `sessionMediaID`) still gets per-clip HR via `localIdentifier`.
- [ ] Old persisted projects decode (new fields `nil` → defaults).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated (tail sign, Variant A, defaults-apply-to-existing-projects, maxT rule).

## Constraints

- On-device only; no backend. `HighlightEngine` untouched.
- Pure logic (window math, keyframes, scope, offset recovery) unit-tests without a device; the
  Core-Animation burn is device-only as ever.
- Dashing stays reserved for sparse/interpolated data — off-camera ≠ estimated (Variant A rationale).

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — new `HRClipWindowTests` + the existing suites
   (placement/tile/values regressions must stay green).
2. `make ios-sim SIMULATOR='iPhone 17 Pro'` — full app type-check/build.
3. Device leg (MrRobot, deferred): export a real session clip with a hard-move HR spike; verify the
   burned tail shows the off-camera peak, the dot parks at the boundary, and the tile's PEAK matches
   the scope setting. Re-check the user's original broken project exports per-clip HR (offset
   recovery) instead of the whole-session chart.
