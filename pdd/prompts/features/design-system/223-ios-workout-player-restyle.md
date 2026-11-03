# Prompt: Design-system reset, step 3e — the workout player (prompt 223)

**File**: pdd/prompts/features/design-system/223-ios-workout-player-restyle.md
**Created**: 2026-11-02
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement. make sure we are not breaking any existing functionality")**:
`docs/ux-research/design-system/workout-player.html` (before: `player-before-*.png`, after: `player-after-*.png`)

## Goal

Restyle the Quick Session pager (`FreeformPlayerView` pager + `QuickSessionPagerViews`). It is visual only:
- no accessibility id changes
- no element-type changes (the grade pill stays a `Text`, the status badge stays an `HStack`)
- no action or state changes

The finish screen is its own step.

## Approach

- **One accent:**
  - The per-discipline ambient glow is gone; the background is plain paper.
  - The rail's current chip is accent outline + text (was the discipline colour). Other chips are hairline outlines;
    done chips stay green.
  - `PlanSegmentsView` defaults to the accent (the host no longer passes `discipline.accent`).
- **Panels:**
  - `pagerGlass` becomes the card surface + hairline (was `.ultraThinMaterial`). It's used by the nav, dock, steppers,
    panels and racket heroes.
  - New `pagerOutline()` is a hairline capsule for secondary actions: Time this set, Log different, Repeat, Timed
    attempt, Skip / ±30s, +1 extra set, Finish.
- **Type:**
  - Labels are sentence case: kickers, "Set 2 of 4", "Attempt #2", "Elapsed", "Previous sets", "Rest · of 1:30",
    "Go".
  - Big numbers are light: steppers, elapsed, rest, run stats, plan editor, grade.
  - Names are 22 semibold.
- **Climbing:**
  - The grade is a light number on a neutral tile (was a Kilter-amber / blue fill).
  - The status badge uses `KilterAscentStyle.color`: flash blue-green, sent green, project amber.
  - The mini pyramid and milestone trophy use the accent.
- **Overview + add page:** neutral glyph tiles and medium names (the add page was a rainbow of discipline colours).
- **Dock:**
  - Auto-rest "on" and the rest countdown use the accent.
  - The recovery dot is perfFresh / perfModerate; the paused glyph is amber.
  - HR zone colours stay.
- **Shared components that change with it:**
  - `RecordClipButton`: outline capsule; notices use meaning tokens. It's also used by the timed covers and the
    festival live sheet, which are dark.
  - Racket match / drill heroes (`RacketViews`): accent, sentence labels, light numbers. `RacketRecapCards` is not
    touched (finish / detail).
  - Plan editor chip and guide step numbers use the accent.

## Acceptance

- [x] Dark screenshots match the mockup (strength, climb with a send, overview, add).
- [ ] Full UI suite (every player test), then the unit suite separately.
- [ ] Device: user on MrRobot.
