# Prompt: Design-system reset — Recap tab + Clips leftovers (prompt 231)

**File**: pdd/prompts/features/design-system/231-ios-recap-clips-restyle.md
**Created**: 2026-11-04
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/recap-clips.html`
(before: `recap-before-*.png`, `clips2-before-*.png`, as built: `recap-after-*.png`)

## Goal

The user asked for the Clips inner screens. Scoping showed Clips was almost entirely done (#409), but the Recap tab
had never been restyled and carried a raw-id bug. This prompt covers both: visual changes plus one bug fix.

## Approach

- **`DisciplineHero`:** the calm default is a light numeral, a sentence-case caption, no halo, and a neutral icon.
  `display: true` keeps the heavy look for share images (`ShareTemplates`). This also fixes the Kilter screens still
  on the heavy hero: Your Climbs' count and the trend screens' velocity / consistency.
- **Recap cards** (all 23 kinds through `FeedCardHeader` + `feedCard`):
  - one panel, with the discipline edge bar removed
  - a neutral icon tile, and the grade text beside the title
  - accent ribbons
- **Recap feed:**
  - lens chips are `snappetPill` (All was a Kilter-amber fill)
  - the period tiles' new-tile outline and icon use the accent (were amber / orange)
  - the freshness pill has ink text
  - the date bar is a sentence-case era with an accent progress line (was an amber→orange gradient)
- **Card detail:** sentence-case section labels; ascent chips use the `KilterAscentStyle` outline.
- **Bug:** `WorkoutExerciseInput.from` resolves a catalog exercise's name when `displayName` is nil. The Lift PR card
  showed "BARBELL_BENCH_PRESS_-_MEDIUM_GRIP". The converters are now `@MainActor` (`ExerciseCatalog.byID` is
  main-actor).
- **Clips leftovers:**
  - caption tags in the accent (were budget blue)
  - "Edited · …" / "Baked ✓" chips in sentence case, semibold; Edited in the accent (was workout orange)
  - grid badges ("✦ Reel", Sent / Flash) in sentence case, semibold
  - the year label is light
  - the media viewer's Share is ink-on-accent (was Kilter amber)
  - carousel dots and Save use the accent
- **Unchanged (output):** burned overlays, the overlay style sheet, share images, the story player.

## Acceptance

- [x] Affected suites: Clips feed / post, Feed view / wall / HR cards / media carousel, Recap story / clip export,
  Kilter stats / created gallery, Activity progress — 33 tests green. As built matches.
- [x] Unit suite alone: 2653 green.
- [x] Device: user on MrRobot 2026-11-04 ("looks good", "merge").
