# Prompt: Kilter browse — search and filters stop lagging

**File**: pdd/prompts/features/153-ios-kilter-browse-lag.md
**Created**: 2026-10-03
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo. Small Android mirror.
**Chain**: standalone fix (tester report: "search climb becomes very laggy, as well as updating values in its filters")
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Typing in the Kilter browse search box and moving its filters (grade slider, Filters sheet, Board/Angle
chips) should feel instant on a full catalog, not stall the keyboard or the slider.

## Context the implementer needs

`KilterRootView` re-renders on every keystroke (`.searchable` binding) and every slider tick (the grade
range binds straight to `@AppStorage`). Each change did all of this **on the main thread**:

- `.task(id: filterKey) { refresh() }` ran `refresh()` synchronously: `catalog.list(filter)` (500 rows,
  `LIKE '%term%'` — no index can help), then `catalog.count(filter)` (the same scan again), plus two
  150-row climb-of-the-day pool scans whenever discovery was showing. No debounce.
- Building the view ran `catalog.layouts()` (twice) and `catalog.angles()` — each a `DISTINCT` scan over a
  whole table — because `Menu` builds its content eagerly.
- `statsSignature` decoded every `KilterSession.hrSeries` array to count sessions with HR.
- `favoriteUUIDs` (a new `Set` over all favorites) was rebuilt once per visible row.

Android already queries on `Dispatchers.IO`, but a cancelled effect can't stop a running scan, so fast
typing queued one scan per character.

## Approach

- `KilterCatalog`: memoize `layouts()` / `angles()` / `gradeScale()` until `reload()`. Pull the browse
  SQL into one shared builder (`browseSQL` + `bindBrowse`) so every list/count path uses the same WHERE.
- New `KilterCatalogBrowser` (same file, owned by the catalog as `browser`): a second read-only connection
  used only on its own serial queue. `browse(filter, includeDiscovery:)` returns the capped rows + the
  uncapped total from one scan (`COUNT(*) OVER ()`), and caches the climb of the day per
  layout/angle/day. A request whose task was cancelled before the queue reached it is skipped.
- `KilterRootView.refresh()` becomes async: debounce (250 ms when the search text changed, 120 ms for other
  changes, none on first load), then await the browser; keep the old rows until the new ones land. Saved /
  Mine stay on the main thread (small SwiftData sets). An installed-catalog change bumps a
  `catalogGeneration` in `filterKey` instead of calling `refresh()` directly. The empty state waits for
  the first results so it can't flash.
- Cheap per-render work: `statsSignature` reads `metricsSourceRaw` (stamped with a non-empty `hrSeries`) and
  the newest session's `endedAt` instead of decoding HR arrays; build the favorites set once per render.
- Android `KilterRoot`: 250 ms debounce when the search text changed.

## Output

- `ios/App/Snappet/Features/Kilter/KilterCatalog.swift` — caches, shared browse SQL, `KilterCatalogBrowser`.
- `ios/App/Snappet/Features/Kilter/KilterRootView.swift` — async debounced refresh, cheaper render.
- `ios/App/SnappetTests/KilterCatalogStoreTests.swift` — `testBrowserMatchesListAndCount`.
- `android/.../feature/kilter/KilterRoot.kt` — search debounce.
- `docs/knowledge-graph/data.js` — catalog + browse node descriptions.

## Acceptance criteria

- [x] The windowed list + total returns exactly the rows and count of the separate list/count queries
      (checked against SQLite 3.45 on a 3,000-climb synthetic table: search / no search, benchmarks,
      capped / uncapped, no matches).
- [ ] `testBrowserMatchesListAndCount`: browser rows + count equal `list` + `count` for five filters; the
      total ignores the cap; discovery matches `climbOfTheDay`. (Needs the simulator, so it runs in CI.)
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings). (CI — no Xcode on the
      authoring box.)
- [ ] Device: typing a setter name and dragging the grade slider on a full catalog no longer stalls; the
      count and list settle shortly after you stop.
- [x] `decisions.md` updated.

## Constraints

- The catalog stays read-only and on-device; no schema changes or index creation on the user's file.
- `HighlightEngine` untouched.

## Test plan

1. CI: `xcodebuild test` (unit + UI suites) — the new browser test, plus the existing Kilter UI tests
   (browse → open → log; Saved filter) that exercise the async refresh.
2. Device, full catalog: type quickly in search, drag the grade slider, flip Classics / Min ascents in
   the Filters sheet — input stays responsive and the "N climbs" count settles to the right number.
