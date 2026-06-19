# Prompt: Workout-Type Parity — timing as an orthogonal axis (Phase 3)

**File**: pdd/prompts/features/workout-type-parity/03-timed-orthogonal.md
**Created**: 2026-06-19 · **Chain**: `workout-type-parity/PLAN.md` → Phase 3
**Context**: `pdd/context/*`; design README §4 (Timed orthogonal), wireframe steps 5–6

## Goal
Let any strength set be reps × weight AND timed → the combined "8 × 60 kg · 0:42" row.

## Approach
- New `TimedSetCover.swift`: a dark-glass count-up FOCUS cover (the strength analogue of the climb
  `TimedAttemptCover`) — exercise card + editable reps/weight steppers, wall-clock hero timer
  (`StopwatchViewModel(.countUp)` driven directly), live-HR chip, single STOP & LOG. No outcome grid.
- "Time this set" footer action on the strength card (`freeform.timeThisSet`) → `timingSetFor`
  fullScreenCover, seeded from `quickAddSeed` → commits `SetLog(reps,weight,durationSec)` via `appendLog`.
- STOP commits once + dismisses (no double-log); dismiss-before-stop / empty effort logs nothing.

## Output
`TimedSetCover.swift` + `TimedStrengthSetTests.swift` (new) · `FreeformPlayerView.swift`.

## Acceptance
- [ ] Build clean; TimedStrengthSetTests (Time this set → STOP → combined "× kg · M:SS" row) + QuickAddSetTests green.
- [ ] a11y ids `timedSet.*` distinct from the climb cover's `timedAttempt.*`.

*Deferred: consolidating the two climb-timing entry points; a count-down target hold; Time-this-set on run/dance/other.*
