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

## Review sweep (user: "review the other slides too to make sure we have not missed anything")

The user caught an unlabelled recent-grades chip on device. That prompted a pass over every view restyled in prompts
220–227: each view's conditional UI was listed from the code, and the states the seed never showed were screenshot
via the existing UI tests. Fixes:
- **Add a climb:** the recent-grades row gets a "Recent" label. As bare outline chips it read as a stray duplicate.
- **Interval runner:** a one-hand protocol's four adjust chips truncated to "+10…" / "Res…". This was there before
  the restyle. They now use `ViewThatFits`: one centred row, or two.
- **Activity dashboard:** a one-point chart said "One session so far" beside a "3 sessions" KPI. It now says
  "Only 1 of 3 sessions has a hardest send — …".
- **Contrast:** `.borderedProminent` tinted with the accent put **white text on periwinkle (~2:1)**. That affected
  Log set, Finish workout, Add set, Log leg, plan Next / Set plan, the racket CTAs, Progress reel and Compare. All
  13 now use `SnappetWidePrimaryStyle` (`onBrand` ink), which also dims when disabled. Kilter / Clips / Wardrobe
  still have the same pattern and get it in their own passes.

Checked and fine:
- the self-paced Done
- the one-hand indicator ("LEFT" stays caps: a glance-from-the-wall cue the test reads)
- the climbing overview, the board climb page and Open on the board
- the previous-climb list
- the racket match / decided / recap
- the Health-import note (from code)

## Acceptance

- [x] Dark screenshots match the mockup (add a climb, plan, picker, timed sheet).
- [x] Full UI suite on the final code: only the known `525 kg` test failed. Unit suite alone: 2653 green.
- [x] Device: user on MrRobot 2026-11-03/04. The user caught the recent-grades chip and approved the sweep fixes
  ("okay looks good").
