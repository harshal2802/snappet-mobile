# Prompt: Hang load (added / pulley) + one-hand protocols

**File**: pdd/prompts/features/142-ios-hang-load-hands.md
**Created**: 2026-09-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: hangboard-protocols — 139 → 140 → 141 → **142 load + hands** → 143 mid-run adjust → 144 any-frequency → 145 force sensor
**Design**: `docs/ux-research/hangboard-protocols/wireframes.html` frames 2 (load L1), 2C, 5B (approved)

## Goal

Load is real weight: added on top of bodyweight, or taken off with a pulley — "modular, without breaking
anything else". Hangs can be one-handed (alternate / left first / left only / right only).

## Approach

- `Shared/HangLoad.swift`: `HangLoad` (added / assisted, amount as typed + unit, `signedKg`,
  `totalKg(bodyweightKg:)`), `HandMode` (per-hand `sequence`, `repMultiplier`), `Hand`.
- `TimedExerciseSpec.load` / `.handMode` (Optional → no bytes change); `totalSeconds` uses per-hand reps.
- `IntervalSchedule` expands one-hand sets per hand (`Phase.hand`), `nextWorkHand(after:)`.
- `SetLog.loadKg` (signed vs bodyweight) + `.handModeRaw`, written by the runner; set rows read
  "1:03 · +10 kg · one hand, each side".
- Editor: Load (Bodyweight / + Added / − Pulley, typeable amount with the Weight ± step, total on your
  fingers from the profile bodyweight) + Hands; only for protocols the runner logs (repeaters/tabata) — a
  single hold's stopwatch doesn't carry load, so offering it there would silently drop it.
- Runner: LEFT/RIGHT badge on every hang, "Left 2 of 3", "Next: RIGHT hand", load bar with total.

## Acceptance criteria

- [x] Added / pulley load and one-hand modes author, run, show and log; summary reads them back.
- [x] One-hand timeline = per-hand reps in the chosen order; totals match.
- [x] Existing protocols / set logs keep identical bytes.
- [x] `HangLoadHandsTests` (12) + `StructuredIntervalRunnerTests.testOneHandWithAddedLoadShowsHandAndLoad`.
