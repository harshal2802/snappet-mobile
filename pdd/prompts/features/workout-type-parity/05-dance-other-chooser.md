# Prompt: Workout-Type Parity — Dance/Other + six-type chooser (Phase 5)

**File**: pdd/prompts/features/workout-type-parity/05-dance-other-chooser.md
**Created**: 2026-06-19 · **Chain**: `workout-type-parity/PLAN.md` → Phase 5
**Context**: `pdd/context/*`; design README §4 (Dance/Other), wireframe steps 1 + 8

## Goal
Make all six disciplines reachable and give Dance/Other their own (lightweight) identity.

## Approach
- `addOpenEffort(discipline)` creates a `.duration` entity tagged `.dance`/`.other`, auto-expanded.
- Make the timed card **discipline-aware**: `timedHeader` uses `ex.discipline.symbol`/`.accent` so the one
  card serves timed/dance/other (timer/tomato, figure.dance/violet, figure.mixed.cardio/teal).
- Empty state → a 2-column grid of all six type cards (preserve `freeform.cardLifting/cardClimbing/
  cardTimed`; add `cardRunning/cardDance/cardOther`); add-menu gains Dance + Other.

## Output
`FreeformPlayerView.swift` · `DanceOtherTests.swift` (new).

## Acceptance
- [ ] Build clean; DanceOtherTests (chooser → Dance card) + FreeformFlowWalkthroughTests green.
- [ ] Existing empty-state card ids preserved; new accLabels distinct from add-menu item labels.

*Deferred: a richer dance "Duration hero" card + "Name a routine" / offer-hierarchy-on-2nd-thing; expand-gate for the timed/dance/other card.*
