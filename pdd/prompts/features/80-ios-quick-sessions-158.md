# Prompt: Quick Sessions UX — rework the freeform/quick-session flow

**File**: pdd/prompts/features/80-ios-quick-sessions-158.md
**Created**: 2026-06-17
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone UX rework (post-v0.1), driven by a senior-iOS-UX review of the Quick Start flow.
**Source**: GitHub issue [#158](https://github.com/harshal2802/Snappet/issues/158) §A–§G
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Rework the routineless **`FreeformPlayerView`** (Quick Start) from a `List` with a hidden add-menu into a
discoverable canvas with faster entry, frictionless climb naming, a real completion moment, live
HR/metrics/recovery, and live clips that open the built-in Studio. The guided `WorkoutPlayerView` is the
device-verified path and is **reused read-only, never modified**. One combined PR, committed per
workstream. Zero SwiftData model change throughout — every figure is derived, and the new surfaces reuse
shipped infra (`SetMeasure`, `WorkoutMath`, `RecoveryReadiness`, `WorkoutHRStats`, `HeartRateZone`,
`LastSetLookup`, `SessionMedia`/`SessionMediaAssignment`, `StudioEditorView`).

## Context the implementer needs

`FreeformPlayerView` (`ios/App/Snappet/Features/WorkoutTracker/`) hosts routineless sessions inside the
module's `fullScreenCover(item: $playing)`. The one set-commit funnel is `appendLog`. The freeform
XCUITests (NamedClimb / FreeformFlow / RepeatSet / TimedSet / TrackingType / ClimbAttempt) drive add via
`freeform.addExercise` → an option labelled "Lifting exercise"/"Climbing"/"Timed exercise", and finish
via `freeform.finish`. The live HR, Photos, and Studio paths are **device-only** (no HR source / Photos
library on the simulator) — their pure logic must be unit-tested and the platform I/O kept behind a thin
edge in `Services/`.

## Approach

- **Pure helpers first** (ship no-callers, the `StopwatchTiming` precedent): `FreeformSummary`
  (repeat-label / completion stats / dominant-kind / milestone) and `LiveMetricsSummary` (live
  bpm/zone/avg/max/redline/recovery), composing the existing pure helpers; unit-tested.
- **§A** discoverable empty-state cards + inline title + a persistent bottom command bar
  (`safeAreaInset(.bottom)`), retiring the toolbar "End".
- **§B** cached `LastSetLookup` prefill; keyboard-free inline `[−] value [+]` quick-add via `appendLog`;
  value-labelled Repeat via `FreeformSummary`.
- **§C** kill the blocking "Name this climb" alert — add immediately, rename inline via
  `SetMeasure.climbName` (reuses `displayName`).
- **§D** an in-cover `.done` summary (reuse the guided done-screen layout) with a milestone
  `.celebrates(on:)` burst; Done / View detail (`SessionRoute`) / Keep going / Discard.
- **§E** a command-bar HR chip → `LiveMetricsPanel` sheet (HR chart, zone bar, recovery ring, rest
  timer), throttled.
- **§F** wire `SetMediaStrip` per exercise + a discovery cadence applying `SessionMediaAssignment`.
- **§G** a freeform video clip → the shared `StudioEditorView` (`StudioEntry.resolveProject`).

## Output

- New: `FreeformSummary.swift`, `LiveMetricsSummary.swift`, `LiveMetricsPanel.swift`,
  `FreeformSummaryTests.swift`, `LiveMetricsSummaryTests.swift`, `QuickAddSetTests.swift`,
  `CompletionMomentTests.swift`.
- Changed: `FreeformPlayerView.swift` (the rework), `WorkoutTrackerModule.swift` (thread `history` +
  `onViewDetail`), `SetMediaStrip.swift` (optional `onEdit`), the 3 climb UITests (migrated off the
  alert), `TrackingTypeFilterTests`/`FreeformFlowWalkthroughTests` (Finish → summary → Done),
  `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`.

## Acceptance criteria

- [x] Empty state shows discoverable type cards; add-exercise reachable as the logbook grows.
- [x] Quick-add logs reps×weight keyboard-free; Repeat is value-labelled; the sheet prefills the last set.
- [x] Tapping Climbing adds immediately (no alert) and renames inline; the 3 alert tests are migrated.
- [x] Finish opens a completion summary with stats + a milestone celebration; Done/View detail/Keep going.
- [x] Live HR chip + panel (chart/zone/recovery/rest) render; pure HR math unit-tested.
- [x] Clips auto-tag during the session and a video clip opens the scoped Studio.
- [x] App changes type-check (Swift 6, 0 warnings); no platform imports added to `HighlightEngine`.
- [x] Zero SwiftData model change; the one `appendLog` save path + one `SetMeasure` funnel preserved.
- [x] `decisions.md` records the §C reversal + the §F supersede + the build choices.

## Constraints

- On-device only; no backend. The guided `WorkoutPlayerView` and the watch/widget targets are untouched.
- State verification honestly: live HR (§E), Photos discovery/PHPicker (§F), Studio preview/export (§G)
  are **device-verified, not CI** — keep the pure logic unit-tested and the I/O behind `Services/`.
- Leaf-only a11y ids; wall-clock timers; Live-Activity sync intact; Reduce-Motion via `.snappetAnimation`.

## Test plan

1. `cd ios/App && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
   — unit suites + the 8 freeform XCUITest classes green (erase the sim if a long walkthrough wedges).
2. On a real device (HR source + Photos): live HR chip/panel + recovery, live clip auto-tag, tap a clip →
   Studio with its HR overlay.
