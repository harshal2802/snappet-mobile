# Prompt: Library redesign L4b — every picker is the Library

**File**: pdd/prompts/features/187-ios-library-pickers.md
**Created**: 2026-10-16
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo.
**Chain**: Library redesign wireframes (`docs/ux-research/library-redesign/wireframes.html`, screen 7, §08 L4 —
split into L4a create (186) · L4b pickers · L4c Kilter); builds on prompts 183–186
**Context**: `pdd/context/decisions.md`

## Goal

Mid-workout picking is one tap, not a scroll through 870: Quick Session "Add exercises" and the routine builder open on
**Yours · Most used** with "Last: …", the catalog one tap away under **Explore**.

## Approach

- `LibraryCatalog.Row.last` + pure `LibraryCatalog.lastLine` — the most recent instance in a few words
  ("4 × 8 @ 75 kg", "1:03", "V4 · 2 attempts", "5 km · 5:33/km").
- Pure `LibraryPick`: which Yours rows a picker offers (launchable — no festival nights / overviews — and not hidden),
  search + discipline filter, most used first, created-not-done after; its subtitle; opens on Yours only when there's
  something in it. `Choice` = catalog id | your key, in tick order.
- `LibraryPickSource` builds the rows once per presentation (the Library's own `yours` + `WorkoutLibraryView.title`)
  and converts a pick through `ActivityLauncher` — a Quick Session pick comes back set up the way you left it
  (`sessionExercise`), a routine pick prescribes last time (`routineBlock`), same as Log it now / Add to routine.
- `ExercisePickerView` now returns `[SessionExercise]` (Yours can be any discipline); `LibraryPickerView` returns
  `[Pick]` (`.item` for the editor to seed, `.block` already built).
- Out of scope: the timed pick-or-create sheet (it already leads with your recents).

## Acceptance criteria

- [x] `LibraryPickTests`: most used + Last is the latest (not best) session, 42.5 kg kept, hidden + festival not
      offered, created-not-done last, discipline/search filter, opens on Explore with nothing logged.
- [x] `LibraryPickerUITests`: Quick Session picker opens on Yours with "Last:", Explore is the catalog, the bench is
      added; routine builder picks from Yours → a bench block.
- [x] Fresh-store picker tests still open on the catalog (no history → Explore).
- [ ] Device: add your usual lifts mid-session from Yours.
