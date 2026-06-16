# Prompt: Timed sets — live-time a duration hold with the shared stopwatch

**File**: pdd/prompts/features/68-ios-timed-set-timer.md
**Created**: 2026-06-16
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Workout-with-timer initiative — **PR 2 of 6** (the first real consumer of the `StopwatchView` primitive built in PR 1). Ideated + architected 2026-06-15 on this branch.
**Source**: In-repo ideation + architecture plan — Gym Tracker "Workout with timer" (timed sets · repeat-set loop · free-flow climb sessions · tracking-type search), 2026-06-15.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Let a `.duration` set be **timed live** instead of only typed. In the freeform set-logging sheet
(`LogSetSheet`), a timed set today offers two text fields ("Min" / "Sec"); this PR adds a **Timer**
mode (the default) that embeds PR 1's `StopwatchView` — press Start, do the hold, press Stop and the
captured elapsed seconds fill the Min/Sec the save path reads (there's no separate `durationSec` state)
— with **Manual** mode keeping the typed fields as an override. This is the first real caller of the stopwatch primitive (PR 1 shipped it tested, with "no
callers yet"); it proves the primitive in a shipping flow and is the small, low-risk consumer to wire
first before the per-climb-attempt timer (PR 5).

## Context the implementer needs

- **One sheet, one case changes.** `FreeformPlayerView.swift`'s private `LogSetSheet` adapts its `Form`
  to the exercise's `SetKind`. Only the `.duration` case changes; `.repsWeight` and `.climbAttempt` are
  untouched. The sheet keeps `.presentationDetents([.medium])` and the existing
  `keypadDoneToolbar` / Cancel+Add toolbar.
- **The save path must not change.** `build()`'s `.duration` arm is
  `let total = (Double(minutes) ?? 0)*60 + (Double(seconds) ?? 0); return SetLog(durationSec: total > 0 ? total : nil)`,
  and the "Add" button is gated by `SetMeasure.hasInput(build(), kind:)`. The cleanest wiring is to have
  the stopwatch's `onStop` write the captured seconds back into the **same** `minutes`/`seconds` state
  the Manual fields use, so `build()` and the enablement gate stay exactly as they are — the timer is
  just another way to fill those two fields.
- **The primitive is ready.** `StopwatchView(mode: .countUp) { elapsed in … }` (PR 1) calls `onStop`
  with the captured `TimeInterval` when the user taps Stop; it exposes `accessibilityIdentifier`s
  `stopwatch.toggle` (the Start/Stop button) and `stopwatch.elapsed` (the digits). Durations already
  render through `SetMeasure.formatDuration`.
- **Reuse the one duration formatter / put the new mapping in `SetMeasure`.** Capturing seconds → the
  two Min/Sec fields is the inverse of `min*60 + sec`; it belongs next to `formatDuration` /
  `parseReps` / `parseWeight` in the pure `SetMeasure` (the codebase funnels duration logic through one
  tested place), not inlined in the view.
- **An existing UI test types into Min/Sec.** `FreeformFlowWalkthroughTests` logs a timed set by typing
  into the `Min`/`Sec` fields; once Timer becomes the default those fields are hidden, so that test must
  first switch to **Manual** mode (the live-timer path gets its own test).

## Approach

1. **Pure mapping — `SetMeasure.swift`**: add `splitDuration(_ seconds: Double) -> (minutes: String,
   seconds: String)`, the inverse of the build path (`Int(rounded)/60`, `%60` as total minutes — no
   hour wrap, matching the two fields; clamp non-finite/negative to `"0"`/`"0"`). Pure, `SetMeasure`-style,
   unit-tested.
2. **`LogSetSheet`'s `.duration` case — `FreeformPlayerView.swift`**:
   - A small private `enum DurationInputMode { case timer, manual }` (`CaseIterable`, `Identifiable`,
     a `label`) + `@State private var durationMode: DurationInputMode = .timer`.
   - A `.segmented` `Picker` "Timer | Manual" at the top of the case (`labelsHidden`,
     `accessibilityIdentifier("logset.durationMode")`).
   - **Timer**: embed `StopwatchView(mode: .countUp)` whose `onStop` sets `minutes`/`seconds` from
     `SetMeasure.splitDuration(elapsed)` — filling the same state `build()` reads and the gate checks.
   - **Manual**: the existing Min/Sec `HStack` unchanged (still `accessibilityIdentifier("logset.duration")`).
   - `build()` and the Add gate are **unchanged**; detents/toolbar/style preserved.
3. **Knowledge graph**: add the now-real caller edge `wt-freeform-player → wt-stopwatch` (`uses`, label
   "time a duration set"). PR 1 added the `wt-stopwatch` / `wt-stopwatch-timing` nodes with "no callers
   yet"; this is the first.

## Output

- Changed: `ios/App/Snappet/Features/WorkoutTracker/SetMeasure.swift` (add `splitDuration`),
  `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift` (Timer/Manual `.duration` case +
  `DurationInputMode`).
- Tests: extend `ios/App/SnappetTests/SetMeasureTests.swift` (round-trip + clamp for `splitDuration`);
  new `ios/App/SnappetUITests/TimedSetTimerTests.swift` (Quick Start → Timed exercise → Timer mode →
  `stopwatch.toggle` start/stop → Add → assert the row shows a duration); update the timed step in
  `ios/App/SnappetUITests/FreeformFlowWalkthroughTests.swift` to switch to Manual first.
- `docs/knowledge-graph/data.js`: a `links` edge `wt-freeform-player → wt-stopwatch` (`uses`).
- `pdd/context/decisions.md`: a 2026-06-16 entry — live timer as the first stopwatch consumer; the
  Timer/Manual toggle (Timer default) writing the same Min/Sec state so the save path is unchanged;
  `splitDuration` as the pure inverse of `min*60+sec` reusing the one duration funnel.

## Acceptance criteria

- [ ] In a freeform `.duration` log sheet, **Timer** mode shows the stopwatch; Start → Stop captures the
      elapsed seconds and the logged set's `durationSec` equals that capture (rendered "M:SS").
- [ ] **Manual** mode still types Min/Sec; both modes persist `durationSec` via the unchanged `build()`,
      and the Add button is still gated by `SetMeasure.hasInput`.
- [ ] `.repsWeight` and `.climbAttempt` are unchanged; the sheet keeps `.presentationDetents([.medium])`.
- [ ] `splitDuration` round-trips through the save path (`(Double(min) ?? 0)*60 + (Double(sec) ?? 0)`
      equals the captured rounded seconds) and clamps bad input — covered in `SetMeasureTests` without a
      simulator.
- [ ] A UI test exercises the live-timer path via `stopwatch.toggle`; the existing freeform walkthrough
      still logs a timed set (via Manual).
- [ ] No second duration formatter added; the app type-checks against the iOS 18 SDK (Swift 6, 0
      warnings); `HighlightEngine`, the watch and the widget are untouched.
- [ ] `docs/knowledge-graph/data.js` and `pdd/context/decisions.md` updated in this change.

## Constraints

- On-device only; no backend / network / accounts.
- **Reuse, don't re-implement.** Consume `StopwatchView` as-is (PR 1); do not duplicate its timing or
  add a second formatter. The save path (`build()` / `durationSec`) and `SetLog` are unchanged.
- Do not touch the device-verified guided `WorkoutPlayerView`, the watch/widget targets, `HighlightEngine`,
  or release workflows.
- Honest verification: a clean type-check ≠ a device run. The orchestrator runs the simulator suite; this
  change ships `xcodegen generate`-verified plus the pure `SetMeasureTests`.

## Test plan

1. `cd ios/App && xcodegen generate`, then
   `xcodebuild test -scheme Snappet -only-testing:SnappetTests/SetMeasureTests
   -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (orchestrator); plus
   `-only-testing:SnappetUITests/TimedSetTimerTests` for the live-timer path.
2. By eye on the sim: Quick Start → add a Timed exercise → Add set (Timer mode default) → Start, hold a
   few seconds, Stop → Add → the set row reads the captured "M:SS"; switch to Manual and confirm typing
   Min/Sec still works.
