# Prompt: Workout-Type Parity — strength as an expandable card (Phase 2)

**File**: pdd/prompts/features/workout-type-parity/02-strength-card.md
**Created**: 2026-06-19 · **Chain**: `workout-type-parity/PLAN.md` → Phase 2
**Context**: `pdd/context/*`; design README §4 (Strength), wireframe steps 3–4

## Goal
Give strength (`.repsWeight`) the same expandable entity card as climbing instead of a flat List section.

## Approach
- Replace `liftingOrTimedSection` with `strengthSection`/`strengthHeader`/`strengthRollup` in
  `FreeformPlayerView.swift`: rolled-up header (discipline icon · tap-to-expand name · chevron · ⋯) +
  rolled-up chips (top set · N sets · e1RM) → expanded set list + per-set `SetMediaStrip` (EVERY set) +
  the existing `QuickAddRow` + footer ("Log something different" / Repeat).
- `addLifting` AUTO-EXPANDS the new card (so quick-add is immediately reachable — preserves QuickAddSetTests).
- New pure `StrengthStats.swift` (top set by weighted load + Epley e1RM) + tests.
- Preserve `freeform.quickReps/quickWeight/quickLog/setRow/addSet/repeatSet`; new header ids
  `freeform.entityName/.expand/.entityMenu`.

## Output
`StrengthStats.swift` + `StrengthStatsTests.swift` (new) · `FreeformPlayerView.swift`.

## Acceptance
- [ ] Build clean; StrengthStats unit tests green; QuickAddSetTests + RepeatSetTests + FreeformFlowWalkthroughTests green.
- [ ] e1RM rounded for display; bodyweight → no e1RM chip.

*Deferred to a follow-up (task #10): the hybrid ⚙ default-prescription add sheet, inline edit-entity, recent-prescription chips, inline unit toggle.*
