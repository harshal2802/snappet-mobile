# Prompt: Kilter Board — "No matching" tag on the climb screen + a board-size download filter

**File**: pdd/prompts/features/kilter-board/FEAT-no-match-tag-and-size-download-filter.md
**Created**: 2026-06-07
**Project type**: Native iOS + Android feature (Swift / Kotlin) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → climb-screen fidelity + download parity with the Board Explorer
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`,
`pdd/prompts/features/kilter-board/RESEARCH.md`

## Goal

Two Kilter additions, grounded in the **real** downloaded Aurora data (not assumptions):

1. **"No matching" tag on the climb screen.** A climb can forbid **matching hands** on a hold (the Kilter
   setter rule). The climb screen never showed it. Surface it as a tag.
2. **Board-size filter in the catalog download.** The Board Explorer gained a size filter; the in-app
   download (`HostedCatalogClient`) should mirror it, so a user can fetch only the climbs that physically
   fit their board size.

## Context the implementer needs

- **Verify against the real data first.** Download `kilter.sqlite.gz` from the catalog host and inspect
  `climbs`. The match rule is the dedicated **`climbs.is_nomatch`** boolean (≈74k of ≈344k climbs; every
  flagged climb also says "no matching" in its `description` — the column is the precomputed note). `hsm`
  is **not** the match flag. The fit data is **`product_sizes.[edge_left,right,bottom,top]`** (a box in
  hole units; the real `product_sizes` carries these edges — the app's reader didn't read them).
- **The reader didn't load `description` or `is_nomatch`** (`KilterClimb` lacked both), and
  `KilterBoardSize` had no box. Both new columns are **absent from older/hand-rolled catalogs** (and the
  validator doesn't require them) — so detect presence once on open and degrade.
- **Download mirror**: `HostedCatalogClient.buildFilteredCatalog` / `conditions()` mirrors the explorer's
  `query.ts buildConditions`; the explorer's size clause is
  `c.edge_left >= ? AND c.edge_right <= ? AND c.edge_bottom >= ? AND c.edge_top <= ?` with the box bound
  `[left,right,bottom,top]`.
- **Download size picker source**: pre-download the board's sizes aren't known (the ~80 MB file isn't
  fetched; the manifest carries no sizes), and embedding Aurora sizes duplicates Aurora data (#42). Read
  the sizes (with boxes) from the **installed** catalog; hide the picker on a first-ever download.

## Approach

- **Models** — `KilterClimb` gains `description` + `isNoMatch`; `KilterBoardSize` gains `box:
  KilterSizeBox?` (a new 4-int value). A pure `kilterDescriptionForbidsMatching(_:)` detects the note (the
  `is_nomatch` fallback). All mirrored iOS/Android.
- **Catalog** — detect `climbs.is_nomatch` + `product_sizes.edge_*` once on open (`columnExists`). The
  climb reader prefers `is_nomatch`, else derives from `description`. `sizes(forLayout:)` reads the box
  when present (nil otherwise).
- **Climb screen** — a `Matching` / `No matching` chip (`hand.raised.slash` amber for no-match), always
  shown, beside the Classic/FA row.
- **Download** — `CatalogFilter` gains `sizeId` + `sizeBox`; `conditions()` adds the fit clause when
  `sizeBox` is set. The download sheet adds a **Board size** picker populated from the installed catalog
  (those sizes with a box), default "Any size", hidden when none.
- **Fixture** — add `is_nomatch` (one no-match climb with a "No matching" description) + `product_sizes`
  edge boxes (a tall box that fits every climb, a short box that fits none) across all four mirrors.

## Output

- `KilterModels.swift` / `KilterCatalog.kt` — `KilterClimb.{description,isNoMatch}`, `KilterSizeBox`,
  `KilterBoardSize.box`, `kilterDescriptionForbidsMatching`.
- `KilterCatalog.{swift,kt}` — `is_nomatch` + size-box reads, `columnExists` detection.
- `KilterClimbDetailView.swift` / `KilterDetailScreen.kt` — the match chip.
- `KilterAuroraSync.{swift,kt}` — `CatalogFilter.{sizeId,sizeBox}` + the fit condition.
- `KilterCatalogSyncView.swift` (download sheet) / `KilterCatalogDownloadSheet.kt` — the Board-size picker.
- `build_test_fixture.py` + regenerated `kilter-fixture.sqlite3` + Swift/Kotlin `KilterCatalogFixture` —
  `is_nomatch` + `product_sizes` edges.
- Tests: `KilterCatalogStoreTests.swift` / `KilterCatalogStoreTest.kt` (read), `KilterAuroraSyncTests.swift`
  / the instrumented mirror (size-fit filter), pure match-detector tests both platforms.
- `docs/knowledge-graph/data.js` (`kilter-detail`, `kilter-catalog-db`, `kilter-catalog-download`),
  `decisions.md`, `project.md` updated in the same change.

## Acceptance criteria

- [ ] The climb screen shows a Matching / No-matching tag driven by `climbs.is_nomatch` (description
      fallback when the column is absent); `kilterDescriptionForbidsMatching` is unit-tested.
- [ ] The download flow keeps only climbs whose `edge_*` box fits the chosen size's box (mirrors the
      explorer); a size picker appears when the installed catalog supplies sizes, and is hidden otherwise.
- [ ] `KilterBoardSize.box` is read from `product_sizes.edge_*` when present, nil otherwise.
- [ ] Newer columns are PRAGMA-detected and degrade on catalogs that lack them (no crash; existing tests
      stay green).
- [ ] iOS type-checks (Swift 6, 0 warnings); Android compiles; 4-mirror fixture + tests; docs updated.

## Constraints

- On-device only; no Aurora API; nothing uploaded; no Aurora data embedded (#42 — the size picker reads
  the installed catalog, doesn't hardcode sizes).
- Mirror the Board Explorer's `buildConditions` size clause exactly; keep iOS + Android behavior identical
  and the catalog logic pure/unit-testable.
- Verify the data model against the real downloaded catalog, not assumptions.

## Test plan

1. iOS: `xcodebuild test -only-testing:SnappetTests` (reader + size-fit + detector). Android:
   `:app:testDebugUnitTest` (pure detector) + the instrumented `KilterCatalogStoreTest` on an emulator.
2. Regenerate the binary fixture and confirm it validates (4 climbs).
3. By eye: a no-match climb shows the amber chip; the download sheet (with a catalog installed) offers a
   Board-size picker that shrinks the result.
