# Prompt: History shows everything by default, with a Source filter

**File**: pdd/prompts/features/130-ios-unified-history.md
**Created**: 2026-08-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follows prompt 129 — user: "i think by default in history we should show all the past
sessions with options to filter them"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the History screen mean *all* of your history. Today it renders two disjoint lists: imported
Health sessions in a section pinned above, and tracked sessions grouped by month below — and the
imported section is gated on `query.isEmpty && effectiveFilter == nil && kindFilter.isEmpty`, so
**typing anything, or tapping any chip, makes every imported row vanish**. Filtering silently
hides a whole category instead of narrowing, which is the opposite of what a filter should do.

## Context the implementer needs

- `WorkoutHomeView` deliberately splits `history` (tracked) from `watchSessions` (imported)
  because analytics, the dashboard, PRs and Studio candidates must NOT see imports — they carry no
  exercises/sets and would skew every derived stat. That split stays; only the History *screen*
  merges the two for display.
- Row shapes differ and both are worth keeping: `HistoryRow` (sets/volume) vs `WatchHistoryRow`
  (source label + measured energy/distance, per prompt 129).
- `HistorySearch` is pure and unit-tested; the facets compose (routine → kinds → query).

## Approach

- `HistorySectionView` merges `history + watchSessions`, newest first, and groups the merged list
  by month. One `ForEach`; each row picks its shape from `session.isImportedFromHealth`.
- New pure `HistorySource` facet (`tracked` / `imported`) + `HistorySearch.apply(sources:)`.
  Empty set = both = the default. Chips render only when the user actually has both kinds.
- Routine chips derive from the merged list, so an imported "Climbing" is filterable too.
- The tracking-type facet keeps excluding imports (they track no kind — that's honest, not a bug).
- Empty state keys off the merged list; the search-empty state is unchanged.

## Output

Changed: `HistorySectionView.swift` (merge + `HistorySource` + `sourceChips`, section removed),
`HistorySearchTests.swift` (+`HistorySourceFacetTests`).

## Acceptance criteria

- [ ] History opens showing tracked and imported sessions interleaved by date.
- [ ] Searching or filtering narrows both origins — imports are never silently dropped.
- [ ] Source chips isolate either origin; neither selected = both.
- [ ] Analytics/dashboard/Studio still see tracked sessions only.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).

## Constraints

- Keep both row shapes; an import has no sets to show.
- Don't let imports leak into any derived stat.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — the new facet tests.
2. `TrackingTypeFilterTests` + `FreeformFlowWalkthroughTests` UI slices (History layout changed).
3. Device: History lists everything; Tracked/Imported chips narrow it.
