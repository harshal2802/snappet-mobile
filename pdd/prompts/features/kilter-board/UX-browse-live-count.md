# Prompt: Kilter Board — live climb count + friendlier search in the catalog browse

**File**: pdd/prompts/features/kilter-board/UX-browse-live-count.md
**Created**: 2026-06-07
**Project type**: Native iOS + Android UX change (Swift / Kotlin) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → browse/search UX
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The catalog browse gives no feedback on how a search/filter narrows the catalog. Show a **live count of
matching climbs** for the selected search parameters, and make the search feel more responsive — with a
quick **Clear** when a search/filter is active.

## Context the implementer needs

- Browse is `KilterRootView` (iOS) / `KilterRoot` (Android); it queries `KilterCatalog.list(filter)`,
  which is **capped** (LIMIT 500), so its size understates the true match count.
- `KilterFilter` already carries the full browse criteria (layout/angle/grade/search/sort/benchmarks/
  ascents/quality). `activeExtras` counts the Filters-sheet extras.

## Approach

- Add **`KilterCatalog.count(_ filter:)`** (both platforms): the same WHERE as `list` (one `climb_stats`
  row per climb at the angle → `COUNT(*)`), no LIMIT/sort. Saved-mode count is the filtered favorites' size.
- Show a **count bar** under the filter chips: "N climbs" updating live with the filter + search, plus a
  **Clear** action (resets search + Saved + Filters-sheet extras; keeps board/angle/grade) shown when any
  of those is active.

## Output

- `KilterCatalog.{swift,kt}` — `count(filter)`.
- `KilterRootView.swift` / `KilterRoot.kt` — the count bar + Clear + wiring (set count on each refresh).
- `KilterCatalogStoreTests.swift` / `KilterCatalogStoreTest.kt` — a `count` test over the fixture.
- `docs/knowledge-graph/data.js` (`kilter-catalog`, `kilter-catalog-db`) + `decisions.md` + `project.md`.

## Acceptance criteria

- [ ] The browse shows a live "N climbs" count for the current search + filters (true count, not capped).
- [ ] A Clear action appears when search/Saved/extra filters are active and resets them (keeps board/grade).
- [ ] `count(filter)` is unit-tested (== uncapped list size where applicable; varies with angle/grade/search).
- [ ] iOS type-checks (0 warnings); Android compiles; docs updated.

## Constraints

- On-device only; keep the catalog logic pure; mirror iOS + Android; keep `count`'s WHERE in lockstep
  with `list`'s.

## Test plan

1. iOS `xcodebuild test -only-testing:SnappetTests`; Android `:app:testDebugUnitTest` + instrumented mirror.
2. By eye: type in search / change filters → the count updates; Clear resets.
