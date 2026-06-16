# Prompt: Climb attempts — optionally time an attempt with the shared stopwatch

**File**: pdd/prompts/features/70-ios-climb-attempt-timer.md
**Created**: 2026-06-16
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Workout-with-timer initiative — **PR 4 of 6** (the climb-side analogue of the timed-set timer, PR 2 — the second real consumer of the `StopwatchView` primitive built in PR 1). Ideated + architected 2026-06-15 on this branch.
**Source**: In-repo ideation + architecture plan — Gym Tracker "Workout with timer" (timed sets · repeat-set loop · free-flow climb sessions · tracking-type search), 2026-06-15.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Let a free-flow **climb attempt** be **optionally timed** — how long the boulder/route took — without
disturbing the fast log-and-go path. In the freeform set-logging sheet (`LogSetSheet`), the
`.climbAttempt` case today is grade + outcome + attempts; this PR adds an **opt-in** "Time the attempt"
toggle (default **off**) that, when on, embeds PR 1's `StopwatchView(mode: .countUp)` — press Start, do
the climb, press Stop and the captured elapsed seconds are stored in the **existing**
`SetLog.durationSec` (unused for `.climbAttempt` until now — so **no model change**) and appended to the
climb set's summary row ("V4 · Sent · 3 tries · 0:42"). This is the climb-side analogue of the timed-set
timer (PR 2), and the second real caller of the stopwatch primitive (PR 1 shipped it tested with "no
callers yet"; PR 2 wired the timed set, this wires the climb attempt).

## Context the implementer needs

- **One sheet, one case changes.** `FreeformPlayerView.swift`'s private `LogSetSheet` adapts its `Form`
  to the exercise's `SetKind`. Only the `.climbAttempt` case changes; `.repsWeight` and `.duration` are
  untouched. The sheet keeps `.presentationDetents([.medium])` and the existing
  `keypadDoneToolbar` / Cancel+Add toolbar.
- **Reuse `durationSec` — no model change.** `SetLog.durationSec: Double?` already persists captured
  durations (it's how a `.duration` set stores its seconds); it is simply unused for `.climbAttempt`.
  Storing the per-attempt time there means **no** `WorkoutModels` / `SetLog` change and the value rides
  every existing path (persist, duplicate/Repeat, backup) for free. `build()`'s `.climbAttempt` arm is
  `SetLog(climbGradeLabel:…, climbStatusRaw:…, climbAttempts:…)`; it gains `durationSec:` (nil unless the
  timer was used and captured a non-zero hold). The "Add" gate (`SetMeasure.hasInput`) is **unchanged** —
  grade/outcome still decide loggability; the timer is purely additive.
- **The primitive is ready and proven by PR 2.** `StopwatchView(mode: .countUp) { elapsed in … }` (PR 1)
  calls `onStop` with the captured `TimeInterval` and exposes a `onRunningChange` callback (PR 2 used it
  to lock a control while running). It exposes `accessibilityIdentifier`s `stopwatch.toggle` (Start/Stop)
  and `stopwatch.elapsed` (digits). Durations already render through `SetMeasure.formatDuration`.
- **Summary funnels through `SetMeasure`.** `SetMeasure.summary(_:kind:unit:)`'s `.climbAttempt` arm
  builds `["V4", "Sent", "3 tries"]` joined by " · "; append `formatDuration(durationSec)` when a
  duration is present (matching the `.duration` "> 0" rule), reusing the one duration funnel — no second
  formatter.
- **UI-test lessons (PR 2/3).** Do **not** put `.accessibilityIdentifier` on a composite/custom view —
  on iOS 26 it collapses the a11y subtree and hides children (so the `StopwatchView` stays un-identified
  and the test queries its leaf `stopwatch.toggle` / `stopwatch.elapsed` directly). The new toggle is a
  **leaf** `Toggle` with `accessibilityIdentifier("logset.climbTimerToggle")`. Query rows
  type-agnostically (`app.descendants(matching: .any).matching(identifier: "freeform.setRow")`, NOT
  `app.cells`) and assert on **distinctive values** (the grade + the captured M:SS).

## Approach

1. **`LogSetSheet`'s `.climbAttempt` case — `FreeformPlayerView.swift`**:
   - Add `@State private var climbTimed = false`, `@State private var climbTimerRunning = false`,
     `@State private var climbDurationSec: Double?`.
   - After the existing grade/outcome/attempts controls, a leaf `Toggle("Time the attempt", isOn:
     $climbTimed)` (`accessibilityIdentifier("logset.climbTimerToggle")`), `.disabled(climbTimerRunning)`
     so it can't be collapsed mid-run (tearing down the timer without a Stop, dropping the capture — the
     timed-set lesson).
   - When `climbTimed`, embed `StopwatchView(mode: .countUp)` whose `onStop` sets
     `climbDurationSec = elapsed > 0 ? elapsed : nil` and whose `onRunningChange` drives
     `climbTimerRunning`. No identifier on the `StopwatchView` itself.
   - `build()`'s `.climbAttempt` arm gains `durationSec: climbTimed ? climbDurationSec : nil`; the Add
     gate and the other arms are **unchanged**; detents/toolbar/style preserved.
2. **Summary — `SetMeasure.swift`**: in the `.climbAttempt` arm, after the tries part, append
   `formatDuration(secs)` when `set.durationSec` is present and `> 0`. Pure, one-funnel, unit-tested.
3. **Knowledge graph**: the now-real caller edge `wt-freeform-player → wt-stopwatch` (`uses`) already
   exists from PR 2 ("time a duration set"); broaden its label to cover climb attempts and update the
   `wt-freeform-player` desc to mention the optional per-attempt timer.

## Output

- Changed: `ios/App/Snappet/Features/WorkoutTracker/SetMeasure.swift` (append duration to the
  `.climbAttempt` summary), `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift` (opt-in
  timer in the `.climbAttempt` case + `durationSec` in its `build()` arm).
- Tests: extend `ios/App/SnappetTests/SetMeasureTests.swift` (climb summary with/without a duration);
  new `ios/App/SnappetUITests/ClimbAttemptTimerTests.swift` (Quick Start → Climbing → Add attempt →
  enable the timer → `stopwatch.toggle` start/stop → grade V4 → Add → assert the row shows the grade and
  the captured M:SS).
- `docs/knowledge-graph/data.js`: broaden the `wt-freeform-player → wt-stopwatch` (`uses`) edge label +
  the `wt-freeform-player` desc to include the optional per-attempt climb timer.
- `pdd/context/decisions.md`: a 2026-06-16 entry — optional per-attempt climb timer reusing `durationSec`
  (no model change), off by default; the second stopwatch consumer; summary appends the time via the one
  duration funnel.

## Acceptance criteria

- [ ] In a freeform `.climbAttempt` log sheet, a "Time the attempt" toggle (off by default) reveals the
      count-up stopwatch; Start → Stop captures the elapsed and the logged attempt's `durationSec` equals
      that capture, appended to the row ("… · M:SS").
- [ ] With the timer never used, the climb attempt logs exactly as before (`durationSec` nil; summary
      unchanged); grade/outcome/attempts behavior is intact and the Add gate is still
      `SetMeasure.hasInput`.
- [ ] `.repsWeight` and `.duration` are unchanged; the sheet keeps `.presentationDetents([.medium])`; no
      `SetLog`/`WorkoutModels` change.
- [ ] The `.climbAttempt` summary appends `formatDuration(durationSec)` only when a non-zero duration is
      present — covered in `SetMeasureTests` without a simulator (with-duration, single-try-with-duration,
      and without-duration cases).
- [ ] A UI test exercises the live-timer path via `logset.climbTimerToggle` + `stopwatch.toggle` and
      asserts a `freeform.setRow` shows both the grade and the captured M:SS.
- [ ] No second duration formatter added; the app type-checks against the iOS SDK (Swift 6, 0 warnings);
      `HighlightEngine`, the watch and the widget are untouched.
- [ ] `docs/knowledge-graph/data.js` and `pdd/context/decisions.md` updated in this change.

## Constraints

- On-device only; no backend / network / accounts.
- **Reuse, don't re-implement.** Consume `StopwatchView` as-is (PR 1); do not duplicate its timing or
  add a second formatter. Reuse `SetLog.durationSec` — do **not** add a new field or change `SetLog` /
  `build()`'s save shape beyond passing `durationSec`.
- Do not touch the device-verified guided `WorkoutPlayerView`, the watch/widget targets,
  `HighlightEngine`, or release workflows.
- Honest verification: a clean type-check ≠ a device run. The orchestrator runs the simulator suite; this
  change ships `xcodegen generate`-verified plus the pure `SetMeasureTests`.

## Test plan

1. `cd ios/App && xcodegen generate`, then
   `xcodebuild test -scheme Snappet -only-testing:SnappetTests/SetMeasureTests
   -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (orchestrator); plus
   `-only-testing:SnappetUITests/ClimbAttemptTimerTests` for the live-timer path.
2. By eye on the sim: Quick Start → add a Climbing exercise → Add attempt → toggle "Time the attempt" on
   → Start, climb a few seconds, Stop → set grade V4 → Add → the set row reads "V4 · Sent · M:SS";
   confirm logging without enabling the timer is unchanged.
