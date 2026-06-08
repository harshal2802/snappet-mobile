# Prompt: Configurable HR/fitness video-overlay builder

**File**: pdd/prompts/features/28-ios-hr-overlay-builder.md
**Created**: 2026-06-08
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Follow-on to the fitness-band richness roadmap (Phases 2–4, PRs #57–#59) — surfaces the
metrics those phases compute as **selectable video overlays**.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Today a clip's HR overlay is a single thing: a bpm line chart + a moving playhead dot (plus a
preview-only live-bpm number). All the richer metrics now exist (zones, %HRR, per-effort,
redline/strain, HRV, calories, recovery) but none can be put on the video. Give the user a **simple
overlay builder**: pick which numbers/charts to show, mark each **live** (tracks the playhead) or
**static** (one value for the clip), and toggle **animation** where it applies — then burn the
selection into the exported video. Works for both the single-clip editor and the multi-clip Studio
(and the Kilter clip studio, which reuses the Studio).

## Context the implementer needs

- **The export constraint is the design driver.** Overlays burn in via
  `AVVideoCompositionCoreAnimationTool` (Core Animation), which **cannot redraw text per frame** —
  that's why today's live bpm is preview-only. So:
  - **Static** elements (a single clip-window value: avg/max HR, redline %, strain/TRIMP, HRV RMSSD,
    calories, peak %HRR) → one fixed `CATextLayer`, trivially burned in.
  - **Live** elements (bpm / zone / %HRR / recovery that change over the clip) → in the **preview**
    they track the playhead (SwiftUI); in the **export**, *animated* live elements are rendered by the
    opacity-keyframe trick (one short-lived `CATextLayer` per distinct displayed value, its opacity
    keyed to its time window — the same pattern as `StudioOverlays.applyVisibility`). A live element
    with animation **off** burns in as a single static reading (the clip-start value).
  - The existing **chart**'s dot is already keyframe-animated; keep it.
- **All the data is already available at the overlay point**, computed from the clip's HR window
  (rebased to `[0, clipDuration]`, see `ClipEditorView.hrSamplesForClipWindow`): `WorkoutHRStats`
  (avg/max/min, `redlineFraction`, `edwardsTRIMP`), `ClimbEffort` (peak %HRR via `setEfforts`),
  `HRVMetrics` (RMSSD over the window), `UserHRProfile.estimatedKcal`, `RecoveryReadiness`,
  `HeartRateZone`, the session `maxHR`/`restHR`. `HRChartGeometry.sampleBPM(_:atFraction:)` already
  maps a playhead fraction to an interpolated bpm — reuse it for live values.
- **Back-compat:** `HROverlayConfig` is persisted on `ClipEdit` + `StudioProject`. Add an additive
  `elements: [HROverlayElement] = []`; old projects decode with `[]` (the chart keeps working via the
  existing fields). No SwiftData migration (Codable composite, the `textOverlays` precedent).

## Approach

- **Model (`StudioProject.swift`):** `HROverlayMetric` enum (`bpm, zone, hrr, avgHR, maxHR, redline,
  strain, hrv, calories, recovery`) each exposing `label`, `supportsLive`, `supportsAnimation`;
  `HROverlayElement` (id, metric, `live`, `animated`, normalized x/y, scale, colorHex). Add
  `HROverlayConfig.elements`.
- **Pure resolver (`HROverlayValues.swift`, app, testable):** from the clip's rebased samples + the
  computed stats/effort/HRV/kcal + bounds, produce per-element `staticText`, `liveText(atFraction:)`
  (value + zone color), and `segments(formatter:)` (the `[(text, startFrac, endFrac)]` for animated
  live text). Pure → unit-tested in `SnappetTests`; the device-only Core-Animation render consumes it.
- **Render — preview:** `HROverlayElementsView` lays the selected elements over the preview at their
  positions; live ones track `progress`. Reuse `StudioHRChartView` for the chart element.
- **Render — export (`StudioOverlays`):** for each element add a `CATextLayer` — static → fixed;
  live+animated → per-segment opacity-keyed layers; live+static → the start value. Driven off the
  resolver output passed through `EditPlan` / the composer (computed where the session lives).
- **UI:** a simple "Overlays" builder — a list of metrics to add/remove, each row with **Live** and
  **Animate** toggles (disabled + explained when the metric doesn't support them), a colour swatch,
  and "drag on the preview to place". Extends `StudioHRControls` (Studio) + the single-clip editor.

## Output

- New: `ios/App/Snappet/Features/WorkoutTracker/HROverlayValues.swift` (pure resolver + segments);
  `HROverlayElementsView.swift` (preview render); engine/app tests.
- Edits: `StudioProject.swift` (`HROverlayMetric` + `HROverlayElement` + `HROverlayConfig.elements`),
  `StudioOverlays.swift` (render elements, static + animated-live), `VideoStudio.swift` /
  `StudioComposer.swift` (`EditPlan`/snapshot carry the resolved overlay data), `ClipEditorView*.swift`
  + `StudioEditorView.swift` / `StudioHRControls` + the view models (the builder UI + plumbing).
- Tests: `HROverlayValuesTests` (static text per metric, live value at fraction, segment building +
  de-duping, the no-data/gated cases), `HROverlayModelTests` (capabilities: which metrics support
  live/animation), back-compat decode.

## Acceptance criteria

- [ ] The user can add/remove any of the metrics as overlay elements, set each **live** or **static**,
      and toggle **animate** only where applicable (disabled + labelled otherwise).
- [ ] Static elements burn into the exported video as fixed readings; animated-live elements change
      over the clip in the export (opacity-keyframed); the chart dot still animates.
- [ ] Every element renders identically (position/value) in the preview and the exported file, modulo
      the documented "live text only animates in export when animate is on".
- [ ] No-data / no-profile elements hide cleanly (e.g. calories with no profile, HRV with no RR) —
      the gating from Phases 2–4 is honored.
- [ ] Old projects (no `elements`) open unchanged; the existing chart overlay still works.
- [ ] Engine `swift test` passes (if touched); app type-checks (Swift 6, 0 warnings) and the XCTest
      suite passes on the simulator.
- [ ] `decisions.md` + the knowledge graph updated.

## Constraints

- On-device only. Keep the value/segment logic pure (no AVFoundation) so it's unit-tested; only the
  Core-Animation layer building is device-only.
- Don't regress the existing chart overlay or text overlays.

## Test plan

1. `cd ios/HighlightEngine && swift test` (only if the engine is touched).
2. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Device follow-up: add several overlays (a live zone pill, a static calories badge, the chart),
   export, and confirm the burned-in file matches the preview and the live elements animate.
