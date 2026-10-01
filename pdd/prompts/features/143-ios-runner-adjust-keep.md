# Prompt: Adjust a protocol mid-run + keep-or-once

**File**: pdd/prompts/features/143-ios-runner-adjust-keep.md
**Created**: 2026-09-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: hangboard-protocols — 139 → 140 → 141 → 142 → **143 mid-run adjust** → 144 any-frequency → 145 force sensor
**Design**: `docs/ux-research/hangboard-protocols/wireframes.html` frames 3, 4 (option R1), 6 (approved)

## Goal

"Give user option to … edit that during run time … make sure these features do not confuse people."

## Approach

- Runner chips (load · rest · reps · hands, each with ✎) open an **Adjust** sheet (the editor in
  `adjustOnly` mode); the clock keeps running. Done → `RunnerViewModel.adjust(to:)`.
- Pure `IntervalSchedule.remap(current:to:)`: the edit applies from the next phase; the phase in progress
  keeps its remaining time (capped at its new length); a rep that no longer exists continues at the
  set's end; open-rep count carries over.
- `RunnerViewModel`: rebuildable schedule, banks only **fully** completed work at each adjust (banking the
  in-progress hang's partial double-counted it — caught on the UI-test screenshot), `countFrom`,
  injectable clock (time accounting unit-tested without sleeping).
- End card when something changed: "YOU CHANGED" lines (`ProtocolChanges`) + **Keep for next time** /
  **Just this once**, with a note naming where Keep saves (`ProtocolKeepTarget`: this routine's block ›
  the saved preset › the rest of this workout).
- Also fixes a 141 edge: Skip on the last rest no longer finishes a self-paced run before its final rep.

## Acceptance criteria

- [x] Adjust load / rest / reps / hands mid-run; the clock keeps going; changes apply from the next phase.
- [x] TUT counts every hang exactly once across adjustments; the log records the final load.
- [x] Keep updates the routine block (or preset / session); Just this once only logs.
- [x] `RunnerAdjustTests` (8), `RunnerViewModelTests` (6), `StructuredIntervalRunnerTests.testAdjustLoadMidRunThenChooseJustThisOnce`.
