# Prompt: Workout-Type Parity — shared entity-card foundation (Phase 1)

**File**: pdd/prompts/features/workout-type-parity/01-entity-card-foundation.md
**Created**: 2026-06-19 · **Chain**: `workout-type-parity/PLAN.md` → Phase 1
**Context**: `pdd/context/*`; design `docs/ux-research/workout-type-parity/README.md` §5

## Goal
Lay the reusable card primitives every discipline builds on, with ZERO behavior/a11y change to the
existing climb card (kept as the template).

## Approach
- Rename `expandedClimbs` → `expandedEntities` (one shared expand-state across disciplines) in
  `FreeformPlayerView.swift`.
- New `EntityCard.swift`: `WorkoutDiscipline.accent` (view-layer Color, kept OUT of the pure enum) +
  `EntityRollupChip` (tinted stat pill — the strength/run/timed analogue of the climb grade pill,
  matching the wireframe `.spill`) + the a11y-id convention doc (`freeform.entityName`/`.expand`/
  `.entityMenu`/`.logSet`/`.timeThisSet`/`.logLeg`).

## Output
`FreeformPlayerView.swift` (rename only) · `EntityCard.swift` (new).

## Acceptance
- [ ] No remaining `expandedClimbs` references; climb behavior + a11y unchanged.
- [ ] Build clean (0 warnings in changed files). New primitives used from Phase 2 on.
