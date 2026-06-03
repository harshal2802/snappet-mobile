# Prompt: Walkthrough — chronological screenshot capture of the Live Workout Studio initiative

**File**: pdd/prompts/features/live-workout-studio/WALKTHROUGH.md
**Created**: 2026-06-01
**Project type**: Native iOS UI test (Swift / XCUITest) + a test-only data seed — code lands in this repo.
**Chain**: `pdd/prompts/features/live-workout-studio/PLAN.md` → both tracks shipped (A1–A4 + B1–B5) →
**WALKTHROUGH** (a demo/QA asset, not a feature; depends on everything merged to `main`).
**Source**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15) (initiative umbrella).
**Context**: `pdd/context/conventions.md` (UI-testable Button/segmented-control navigation, the History-row
NavigationLink limitation), `pdd/context/decisions.md` (the 2026-06-01 A1–B5 entries — the features shown).

## Goal

Produce a **chronological, screenshot-capturing UI test** that walks the reachable surfaces of the Live
Workout Capture + Video Studio initiative in story order and captures one **zero-padded, ordered**
screenshot per step, so the frames can be stitched into a video walkthrough. The headline screen is the
**B2 enriched post-workout summary** (HR chart + avg/max/min + time-in-zone). Because the simulator has no
live HR source — it would otherwise persist an empty `hrSeries` and hide the whole HR section — a
**test-only demo seed** plants a completed session with a realistic synthetic HR curve so that screen
actually renders.

## What was built

1. **`StudioDemoSeed`** (`Features/WorkoutTracker/StudioDemoSeed.swift`) — a strictly test-arg-guarded seed
   that, under the launch arg **`-uiTestSeedStudioDemo`**, inserts on first launch ONE completed
   `WorkoutSession` (three logged exercises with completed sets) carrying a deterministic synthetic
   `hrSeries`: a warm-up ramp → five work/recovery oscillations → cool-down, ~120–175 bpm over ~30 min, one
   `HRPoint` every 3 s (no randomness → identical every run). Data only (no Photos needed). Idempotent
   (keyed on a fixed `routineID`). The arg is a **sibling of `-uiTestFreshStore`** and **implies a fresh
   in-memory store** for determinism — `SnappetApp.init()` builds the in-memory container for it and calls
   `StudioDemoSeed.seedIfRequested(into:)` before any UI appears. ZERO production impact: a normal launch
   has neither arg and never reaches the seed (the guard returns immediately).

2. **`LiveWorkoutStudioWalkthroughTests`** (`SnappetUITests/LiveWorkoutStudioWalkthroughTests.swift`) —
   launches with `["-uiTestSeedStudioDemo"]` and captures `snap("NN-name")` (`XCTAttachment`, `.keepAlways`)
   at each step, using `waitForExistence` for robust navigation and asserting where cheap (the A2
   `overallWorkoutTimer`, the A4 `liveMetricsOverlay`, the B2 `hrChart` / "Heart rate" section). The
   chronological arc:
   1. `01-suite-home` · 2. `02-app-library` · 3. `03-workout-dashboard` · 4. `04-routines` ·
   5. `05-routine-detail` (Start bar) · 6. `06-player` (A2 overall-timer header + A4 live-metrics overlay,
   no-source state) · 7. `07-rest-screen` (overall timer + overlay + rest countdown — captured only if the
   player surfaces a rest step) · 8. `08-after-finish` (dashboard) · 9. `09-history` · 10.
   `10-session-summary-hr` (the **headline** B2 chart + avg/max/min + time-in-zone bar — opens the *seeded*
   session specifically) · 11. `11-media-grouped-by-set` (the tagged-media gallery **grouped by set** + a
   **General** bucket, from 4 seeded synthetic clips; "Generate highlight" now enabled) · 11b.
   `11b-reassign-menu` (long-press a clip → the **Move to…** reassignment menu) · 12. `12-settings` · 13.
   `13-hr-source-picker` (the A3 Apple Watch + BLE-scan sheet). Thumbnails render placeholders on the sim
   (no Photos) — the grouping/reassignment UI is model-driven and renders in full.

## Constraints honored

- **Swift 6**; the seed is test-arg-guarded with ZERO production impact; **no platform import** added to
  `ios/HighlightEngine/**` (its source is untouched). The seed lives in the WorkoutTracker feature folder;
  the only app-target edit is the `-uiTestSeedStudioDemo` branch in `SnappetApp.init()`.
- Device-only surfaces (real live-HR overlay value, tagged-media thumbnails, the B3 clip editor, an actual
  generated reel) are NOT faked — the walkthrough snaps their real simulator state (no-source / empty /
  disabled). The seed only supplies HR **data** so the B2 summary renders; it adds no Photos/video.
- Navigation matches the suite's UI-testable conventions (segmented-control + Button rows). The History →
  session-detail row is the suite's one value-based `NavigationLink` (decisions.md 2026-05-31); the test
  opens the seeded session through it with identifier/label/first-row fallbacks, and falls back to a
  snapshot of the real History state if the push doesn't take.

## How to run + export the frames

```
cd ios/App && xcodegen generate
xcodebuild -project ios/App/Snappet.xcodeproj -scheme Snappet \
  -destination 'id=<booted-sim-udid>' \
  -only-testing:SnappetUITests/LiveWorkoutStudioWalkthroughTests \
  -resultBundlePath /tmp/studio-walkthrough.xcresult test CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool export attachments --path /tmp/studio-walkthrough.xcresult \
  --output-path /tmp/studio-attach
# manifest.json maps each `suggestedHumanReadableName` (NN-name) → exportedFileName; copy/rename
# into /tmp/studio-walkthrough-frames/frame-NNN.png in NN order. PNGs are uniform (same sim) so they
# stitch into a video. The PNGs are throwaway (in /tmp) and are NOT committed.
```
