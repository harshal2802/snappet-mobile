# Prompt: A protocol block runs once + exact weights

**File**: pdd/prompts/features/139-ios-protocol-runs-once-exact-weights.md
**Created**: 2026-09-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: hangboard-protocols — **139 fix + exact weights** → 140 protocol editor + presets → 141 tap-done reps → 142 load + hands → 143 mid-run adjust → 144 any-frequency schedules → 145 force sensor
**Design**: `docs/ux-research/hangboard-protocols/wireframes.html` (user approved all picks Q1–Q9, 2026-09-30); this prompt = frames 10, 15, 16
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Two small things every workout feels today:
1. A structured timed protocol (repeaters / tabata / EMOM) inside a routine was played once **per set**:
   the block copied `spec.sets` into its own `sets`, and the pager planned that many full runs — a
   3-set protocol asked for 9 sets, 7:3×6 for 36. The block's own rest also fired after each run on top
   of the protocol's rests.
2. Weights moved only in fixed ±2.5 steps with no way to type — 71.3 kg or a 1.25 kg microplate jump
   couldn't be logged.

## Approach

- `RoutineSessionBuilder.plannedRuns(for:)`: a structured block's `sets` counts **runs**; a legacy block
  whose `sets == spec.sets` (the copied value) reads as 1. New protocol blocks seed `sets: 1`;
  `SessionToRoutine` saves completed runs, not `spec.sets`.
- `QuickSessionPager.startsRestAfterLog(_:)`: no block rest after a protocol run.
- Pure `WeightEntry` (per-unit step choices, default 2.5 kg / 5 lb, nudge from any value without
  snapping, locale-tolerant parse, 0 = bodyweight) + a shared `TypeableWeightValue` (tap → decimal
  field with its own inline Done — the keyboard toolbar doesn't show inside the full-screen pager).
  Used by the pager's weight card and the timed-set screen. Workout Settings → **Weight ± step**.

## Acceptance criteria

- [x] A 3-set protocol in a routine plans 1 run; old routines read the same way; a deliberate 2-run block stays 2.
- [x] No extra block rest after a protocol run.
- [x] Typing 71.3 logs 71.3; ± moves from there by the chosen step; defaults unchanged.
- [x] `WeightEntryTests` (6), new `RoutineSessionBuilderTests` cases (4), updated `SessionToRoutineTests`,
      `QuickAddSetTests.testTypedExactWeightIsLoggedExactly`; existing quick-add / completion / timed-set UI tests green.
