# Prompt: History filters move into a sheet — the screen's default state is your history

**File**: pdd/prompts/features/131-ios-history-filter-sheet.md
**Created**: 2026-08-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follows prompt 130 — user: "is there a better way to show those quick filters", then chose
option **C** from the wireframes and asked to improve it ("C+").
**Design**: `docs/ux-research/history-filters/wireframes.html` (A/B/C/D + C+, rendered)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Give the History screen back to history. Prompt 130 added a Source facet, which left THREE stacked
chip rows (source · routine · tracking type) between the segmented control and the first session —
~280 pt of chrome, only two sessions above the fold, and it grew with every new routine name.

## Context the implementer needs

- The user reviewed four wireframed layouts and picked **C** (toolbar button + sheet), then asked
  for it to be improved. C's weaknesses, and the fixes agreed:
  1. **An unlabelled icon is the affordance the Kilter tester never found**
     (`kilter-ux-feedback/04-filter-obviousness`) → a **labelled "Filters" button**.
  2. **Sheet round-trips are slow** → present at `.medium` with
     `presentationBackgroundInteraction`, bind chips straight through so the list **re-filters live
     behind the sheet**, and make the primary action state the outcome: "Show 12 sessions".
  3. **State could hide** → while filtering, show removable tokens + Clear all, and a count line the
     user asked to keep **always** on ("237 sessions" idle / "12 of 237 sessions" filtering).
- `.searchable` renders the system field; a button cannot be injected into it. Since the count is
  always shown anyway, the button and count share ONE slim row (~38 pt) instead of the wireframe's
  search-row placement.
- Filters stay `@State`, never `@AppStorage`: a filter persisting out of sight would recreate the
  bug prompt 130 removed. `sectionContent.id(section)` already clears them on segment change, while
  a push into a session detail deliberately keeps them.

## Approach / Output

`HistorySectionView`: delete the three chip rows; add `filterBar` (labelled button + badge + count)
and `tokenRow`; present `HistoryFilterSheet` (new, same file) holding Source / Routine / Tracking
type; add a dead-end empty state that names the unsatisfiable Imported + tracking-type combination
and offers Clear filters. `TrackingTypeFilterTests` rewritten to drive the sheet.

## Acceptance criteria

- [ ] Idle History shows one slim row and the full session list.
- [ ] The Filters button is labelled, badges the active count, and opens the sheet.
- [ ] Tapping chips in the sheet re-filters the list live; the primary action states the match count.
- [ ] Active filters appear as removable tokens with Clear all; the count line is always visible.
- [ ] An unsatisfiable filter explains itself and offers Clear filters.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).

## Constraints

- Filters must never persist invisibly.
- Facets and their pure logic (`HistorySearch`) are unchanged — this is presentation only.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`.
2. `TrackingTypeFilterTests` — rewritten for the sheet, ending on the dead-end guard.
3. Device: idle chrome is one row; filtering shows tokens + "N of M".
