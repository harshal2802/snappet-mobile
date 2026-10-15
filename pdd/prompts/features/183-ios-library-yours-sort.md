# Prompt: Library redesign L1 — Yours | Explore, sorting, one climb identity

**File**: pdd/prompts/features/183-ios-library-yours-sort.md
**Created**: 2026-10-14
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Library redesign wireframes (`docs/ux-research/library-redesign/wireframes.html`, option B, §08 L1) — user
approved all five decisions, amending #2 with a date: gyms reset climbs every 3–4 weeks.
**Context**: `pdd/context/decisions.md`

## Goal

The Library only listed a catalog (strength moves, timed protocols, four climb/run templates), always A–Z. The climbs,
runs and holds you actually log never appeared, and nothing could be sorted by use. Make the Library yours first.

## Approach

- Pure `ActivityIdentity`: ONE answer to "same activity?" for the Library, past clips, dashboards and insights.
  Non-climbs → `ActivityKey.plain`. A climb = base (name + gym; unnamed → grade + gym + wall + colour; a bare grade has
  none) + **set window**: consecutive logs ≤ 28 days apart stay one climb, a longer gap is a new climb (the gym reset
  it), keyed by the day the set was first logged. The library id (`climb.boulder` vs `adhoc-climbAttempt`) is not part
  of it. `ActivityKey.of` is gone (`plain` returns nil for climbs) so no caller can bypass the window.
- Pure `LibraryCatalog`: your activities from history — sessions all-time / last 90 days, last done, headline
  ("75 kg × 8", "5:33/km", "1:03 · +11 kg", grade), climb details (type, grade, best status, attempts, gym, set start,
  reset). Sorts per discipline (Most used · Recently done · Best e1RM / Hardest grade / Fastest pace / Longest hold ·
  Most attempts · Name), climb filters (projects / sent), search over title, headline, grade, gym, wall.
- `WorkoutLibraryView`: Yours | Explore. Yours = the catalog rows (`LibraryYoursRow`) with a sort menu remembered per
  discipline (`library.sorts`); a row opens the activity dashboard. Explore = the previous catalog + facets. With no
  history the Library opens on Explore; an explicit choice is remembered (`library.mode`). The "Recent across all
  types" band is gone — Yours sorted by Recently done replaces it.
- The climbing overview's climbs card now renders `LibraryCatalog` rows (one source with the Library);
  `ActivityInsights.climbs` is deleted.

## Follow-up (2026-10-14, device feedback)

"Why does 'ALLDAT: Crankdat B2B …' show 32× most used?" — every festival set is logged under `festival-set`, so all
festivals merged into one row named after the latest artist. Now one row per festival, named as in the Festival app
(`ActivityIdentity.festivalName`), counting nights and total time danced.

Then: "it counts each set as a repeat — misleading; make it customizable". Ending the night after each set makes one
session per set. Rows now count **days** (5 am boundary) by default, with a per-discipline **Count by** (Days ·
Sessions · Sets/Attempts/Legs) in the sort menu; **Most used** ranks on active days.

## Acceptance criteria

- [x] `ActivityIdentityTests` (window keeps a project, a gap resets, adjustable window, gym splits, unnamed climbs,
      bare grade, live placement) · `LibraryCatalogTests` (rows + usage, reset rows, sorts, climb filters, titles).
- [x] UI: `LibraryYoursUITests` (default tab, logged activities listed, climbing → Hardest grade → dashboard, sort
      remembered); Library/activity/guide/walkthrough/insights/pager suites green.
- [ ] Device: your real climbs show with sensible sets; the window feels right for your gym.
