# Prompt: Design-system reset, step 3f — Gym sheets & pickers (prompt 227)

**File**: pdd/prompts/features/design-system/227-ios-gym-sheets-restyle.md
**Created**: 2026-11-03
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "OK")**: `docs/ux-research/design-system/gym-sheets.html`
(before: `sheets-before-*.png`, after: `sheets-after-*.png`)

## Goal

The second Gym leftovers group. Restyle:
- `AddClimbSheet`
- `WorkoutPlanView`
- `LibraryPickerView` / `LibraryPickYours`
- `PickTimedExerciseSheet` + its create form
- `RoutineImportSheet`

It is visual only: ids and actions are unchanged.

## Approach

- **Workout orange → the user's accent** everywhere in these sheets: tints, toggles, selected chips, grade value,
  colour ring, Edit / Swap, wand, checkmarks.
- **Primary actions:** `SnappetWidePrimaryStyle` for Add & log first attempt / Save / Add to my routines / the
  timed create CTA, on paper (were orange `.borderedProminent` on `.bar`). Add climb is an accent outline.
- **Chips:** `snappetPill` (were white-on-orange bold fills) in the add-climb grade picker and the plan's
  strategy / constraints.
- **Neutral tiles:**
  - previous-climb grades (were amber boulder / azure route)
  - picker grade tiles + glyphs (were Kilter amber / the discipline colour)
  - timed-category glyphs (were orange)
- **Plan hero:** a light sentence-case "Easy" / "Rest" with a "Today" label, inline. The shared `DisciplineHero`
  (heavy caps + halo) stays for the Clips cards and share images.
- **Timed rows:** explicit ink titles. `.primary` inside a List Button resolves to the tint and read as link-blue.
- **Climb hold colours** are the climbs' real colours and stay.

## Acceptance

- [x] Dark screenshots match the mockup (add a climb, plan, picker, timed sheet).
- [ ] Full UI suite, then the unit suite separately.
- [ ] Device: user on MrRobot.
