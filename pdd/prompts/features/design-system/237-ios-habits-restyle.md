# Prompt: Design-system reset — Habits (prompt 237)

**File**: pdd/prompts/features/design-system/237-ios-habits-restyle.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "merge 429 and implement the small apps")**: `docs/ux-research/design-system/small-apps.html`
(Habits section; before: `small-before-habit-*.png`)

## Goal

Restyle Habits, the first of the six small apps (prompts 237–242, one PR each, stacked). It is visual only: ids and
flows are unchanged.

## Approach

- **Colour:** Habit green becomes the user's accent; Habits joins `AppLibraryView.suiteAccentModules`.
- **Rows:**
  - One card per habit (a Section each).
  - The icon sits on a neutral tile. The name is medium weight.
  - The streak line is grey with an accent flame (was an orange headline).
  - The pencil is grey.
- **Done:** today's tick and the week strip's done days are an accent fill with an ink tick / number. Due days are grey
  dots. Rest / skipped days stay dashed.
- **Linked strip:** grey background; Start is a small ink-on-accent pill (was orange with white text).
- **Editor:**
  - The selected symbol has an accent outline and wash (was green).
  - The skip-policy value is grey.
  - The weekday picker follows the tint, so it is accent.
- **Empty state:** "Add habit" is ink-on-accent at a fixed width. `ContentUnavailableView` actions get no width of
  their own.
- The list's `onDelete` is gone: each card is its own section, and the row's swipe / context Delete (with the
  confirmation) already covers it.

## Acceptance

- [x] Affected suites: `HabitUITests` 1/1, `RoutineScheduleUITests` 4/4 (linked habits). As built matches the mockup.
- [ ] Unit suite alone (run once for the stack).
- [ ] Device: user on MrRobot (batch with the other small apps).
