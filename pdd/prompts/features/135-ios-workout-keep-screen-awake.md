# Prompt: Keep the screen on during a workout

**File**: pdd/prompts/features/135-ios-workout-keep-screen-awake.md
**Created**: 2026-09-29
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone fix (user report, 2026-09-29)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

"When I use a timed set or play a workout routine my screen keeps getting locked." Keep the phone
awake while the user is working out, without leaving it permanently awake, and let them choose how
aggressive that is.

## Context the implementer needs

- `FreeformPlayerView` is the single player for every session (routine-in-pager convergence, 119).
  It never touched `UIApplication.isIdleTimerDisabled`, so rest count-downs, the Log-set stopwatch
  (`StopwatchView` inside `LogSetSheet`) and the gaps between sets all auto-locked.
- `TimedSetCover`, `TimedAttemptCover` and `StructuredTimedRunner` each wrote `true` on appear and
  `false` on disappear — unconditionally, so any future player-level hold would be clobbered the
  moment a cover closed.
- A fullScreenCover fires its presenter's `onDisappear`, so the player's own appear/disappear is the
  wrong signal for "the workout is open".

## Approach

- Pure `ScreenAwakePolicy` + `KeepScreenAwakeMode` (Whole workout · Only timers · Off; default Whole
  workout; `@AppStorage("workout.keepScreenAwake")`).
- `Services/ScreenAwakeController` (on `AppModel`, injected as optional `\.screenAwake` env) —
  named, idempotent holds; the flag is derived from the live holds + mode. The only writer of the flag.
- Holders: `WorkoutTrackerModule` keyed on `playing` (minimize releases), the player's rest
  count-down until zero, the three covers, `StopwatchView` while running. Re-asserted on foreground.
- Workout Settings → "During a workout · Keep screen on" picker with a per-mode footer.

## Acceptance criteria

- [x] Screen stays on through a whole routine (rest, between sets, timed covers) in the default mode.
- [x] Closing a timed cover no longer turns auto-lock back on under the open player.
- [x] Minimizing the workout lets the phone lock again.
- [x] Only-timers and Off modes behave as labelled; changing mode applies immediately.
- [x] `ScreenAwakeTests` (policy table + hold bookkeeping incl. the reported cover-close bug); full unit suite green.
- [x] Knowledge graph + decisions updated.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`.
2. Device (owed): start a routine, set Auto-Lock to 30 s, sit through a 2:00 rest and a timed set →
   screen stays on; minimize → locks after 30 s; Settings → Off → locks mid-rest.
