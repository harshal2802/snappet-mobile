# Prompt: Workout-Type Parity — running discipline (Phase 4)

**File**: pdd/prompts/features/workout-type-parity/04-running-discipline.md
**Created**: 2026-06-19 · **Chain**: `workout-type-parity/PLAN.md` → Phase 4
**Context**: `pdd/context/*`; design README §4 (Running), wireframe step 7; defer Watch/GPS → issue #177

## Goal
Add Running as a first-class discipline: manual distance + duration → derived pace, in its own card.

## Approach
- `exerciseSection` switches on `ex.discipline` (was if/else on kind) — cleaner + forward-compatible.
- `addRun()` creates a `.run`-discipline / `.duration`-kind entity (add-menu "Running"), auto-expanded;
  `distanceUnit` derives from the weight unit (lb→mi).
- `runSection`/`runHeader`/`runRollup` (total distance · avg pace · N legs via the pure `RunStats`); legs
  rendered by `SetMeasure.runSummary`; per-leg media; "Log a leg" (`freeform.logLeg`).
- `AddRunLegSheet`: manual distance + duration with a live derived-pace preview → `SetLog(distanceMeters,
  durationSec)`; pace derived, never stored.

## Output
`RunStats.swift` + `RunStatsTests.swift` · `AddRunLegSheet.swift` · `RunDisciplineTests.swift` (new) ·
`FreeformPlayerView.swift`.

## Acceptance
- [ ] Build clean; RunStats unit tests green; RunDisciplineTests (Running → Log a leg → "5 km · 25:00 · 5:00/km") + QuickAddSetTests green.

*Deferred (#177): live Apple-Watch/GPS distance, per-leg time-in-zone bar, entity photo, sticky km/mi toggle.*
