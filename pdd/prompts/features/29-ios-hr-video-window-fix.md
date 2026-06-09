# Prompt: HR-on-video — never-missing, per-clip heart-rate windows

**File**: pdd/prompts/features/29-ios-hr-video-window-fix.md
**Created**: 2026-06-09
**Project type**: Native iOS bugfix/hardening (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-up hardening to PR #60/#61 (configurable HR/fitness overlay + multi-clip Studio).
**Source**: user bug report — "wrist band was connected and working but a tagged video is missing HR
and wristband-related data", plus a deep multi-agent review (47 failure modes traced → 32 confirmed).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Guarantee that **every video tagged to a session that recorded any HR shows that video's heart rate**,
correctly aligned to the moment it was filmed — in BOTH the single-clip editor and the multi-clip
Studio. The band was recording; the overlay went missing or wrong because of how a clip is matched to
the session's HR series. Fix the matching, not the capture.

## Context the implementer needs

Two distinct defects, both confirmed against the code:

1. **Multi-clip Studio drew the WHOLE session, not each clip's moment** (the headline bug, shipped with
   PR #61). `StudioEditorViewModel` loaded the whole-session `hrSeries` and handed it un-sliced to
   `StudioComposer`, which mapped it across the *concatenated composition* timeline
   (`HRChartGeometry.normalizedPoints` uses `x = t/sessionMaxT`; the playhead sweeps `totalDuration`).
   So a clip filmed at minute 25 of a 30-min session showed the session-wide chart crammed to a chart
   edge, and every badge (avg/max/zone/calories) was a session aggregate. The single-clip editor
   already slices per clip; the Studio never replicated it — even though `TimelineClip.sessionMediaID`
   can resolve each clip's `SessionMedia.offsetSec`.

2. **The strict window filter dropped HR for edge/sparse/short clips.** `ClipEditorView`'s slice used a
   hard `t >= start && t <= start+span` with no bracketing → a clip before the band connected, a
   victory clip in the trailing ±90 s pad after HR stopped, or a short clip between sparse band samples
   yielded **0 samples** → the chart (needs ≥2) and every badge silently vanished. ~12 confirmed
   findings reduce to this one missing bracket/clamp.

Also: non-Kilter workout sessions only persist `hrSeries` at *finish*, so a clip opened mid-session had
an empty series (Kilter has `syncLiveHR`; the workout path doesn't).

## Approach

- **`HRWindowSlicer`** (new, pure, `Features/WorkoutTracker`): the one slicer both editors use. Brackets
  the window with interpolated endpoints (in-coverage), clamps to last-known HR within a 90 s tolerance
  (edge clips), and returns `[]` only when truly out of coverage or empty — always ≥2 points otherwise.
- **`StudioHRPlacement`** (new, pure): per-clip capture windows → per-clip sliced/rebased samples for
  the placed video clips, keyed on `SessionMedia.offsetSec`.
- **`StudioComposer` / `StudioOverlays`**: thread `clipHRByID` (per-clip content) through
  `makeComposition`/`assemble`/both assembly paths/`export`; render one HR chart + element set **per
  clip**, opacity-gated/animated to each clip's output slot. The single-clip `VideoStudio` path stays
  byte-for-byte (slot params default to the whole timeline).
- **`SessionHRSeries` + `LiveHRMerge`** (new, pure): for a still-live session with an empty persisted
  series, fall back to the live coordinator buffer (both transports merged so a mid-session source
  switch doesn't drop samples). Read-only; no persistence change.
- Single-clip editor + Studio preview both route through the slicer/placement so preview == export.

## Output

- `Features/WorkoutTracker/HRWindowSlicer.swift`, `StudioHRPlacement.swift`, `LiveHRMerge.swift` (pure).
- Edits: `SessionHRSeries.swift`, `ClipEditorView.swift`, `StudioEditorViewModel.swift`,
  `StudioEditorView.swift`, `Services/StudioComposer.swift`, `Services/StudioOverlays.swift`.
- Tests: `HRWindowSlicerTests`, `LiveHRMergeTests`, `StudioHRPlacementTests`.

## Acceptance criteria

- [x] A clip whose window has no in-range samples but is within 90 s of HR data shows last-known HR.
- [x] A clip far outside coverage (cross-day manual pick, cool-down minutes later) shows honest empty.
- [x] Each clip in a multi-clip Studio project shows its OWN capture-window HR (chart + badges), gated
      to its slot — verified by a pure placement test (two clips at different session times diverge).
- [x] App changes type-check (Swift 6) and the existing HR/Studio suites stay green.
- [x] No platform imports added to `HighlightEngine` (all new logic is app-side, pure).
- [x] `decisions.md` updated.

## Constraints

- On-device only; the slicer/placement are pure and simulator-testable, but the **Studio export
  burn-in** (Core Animation per-clip layers) cannot be rendered on the simulator — verify on hardware.
- Clamp semantics are a product call: clamp within the ±90 s media pad, else honest-empty (chosen).

## Test plan

1. `xcodebuild test` (sim) — new pure suites + existing HR/Studio suites green.
2. **Device-pending** (real iPhone + band): record a session, film clips early/late/at-the-end, then
   confirm each clip's overlay (single-clip editor AND multi-clip Studio export) shows that clip's HR.
