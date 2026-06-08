# Prompt: Kilter Board — make the catalog download board-first (end-user friendly)

**File**: pdd/prompts/features/kilter-board/UX-download-board-first.md
**Created**: 2026-06-07
**Project type**: Native iOS + Android UX change (Swift / Kotlin) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → opt-in catalog download (#42) → end-user UX
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`,
`pdd/prompts/features/kilter-board/RESEARCH.md`

## Goal

The in-app catalog download is a 12-field power-user form (board, layout toggles, angle, grade min/max,
ascents, quality, setter, name, benchmark, listed, single-frame, board size, cap, host) — confusing for
an end user who just wants the climbs for their board. Reshape it around the one thing they know: **which
board do you have.** Download = pick your **layout + size**; everything else is a **browse-time** filter
in the installed list.

## Context the implementer needs

- The download sheet is `KilterCatalogDownloadSheet` (iOS in `KilterCatalogSyncView.swift`; Android
  `KilterCatalogDownloadSheet.kt`). It builds a `CatalogFilter` and hands it to `HostedCatalogClient`,
  which downloads the ~80 MB board file and trims it on-device via `conditions()` (mirrors the Board
  Explorer's `query.ts buildConditions`).
- Layout + size define the physical board. Size filtering keeps climbs whose `edge_*` box fits the size's
  `product_sizes.edge_*` box (added previously). The other `CatalogFilter` fields (grade/ascents/…) map to
  controls that **already exist** in the browse UI (`KilterRootView`/`KilterRoot` chips + Filters sheet).
- **The size picker must work on a first download** — no catalog is installed and the 80 MB file isn't
  fetched, so sizes can't come from the DB. Embed the well-known Kilter board sizes (layout → sizes with
  their real `product_sizes.edge_*` boxes) as static reference. This is board **dimensions** (like the
  hardcoded layout ids), not the climb catalog — consistent with #42.

## Approach

- **Static board table** in `KilterCatalogOptions` (both platforms): `boards = [KilterKnownBoard(layoutId,
  name, defaultSizeId, sizes: [KilterKnownSize(id, name, box)])]` for Original (1) + Homewall (8), from the
  real Aurora data. `board(layoutId)` / `sizeName(layoutId:sizeId:)` helpers.
- **Redesign the sheet**: a "Your board" section (single Layout picker + Size picker, seeded to a common
  size, reseeded on layout change), a "How many climbs" cap, the Download button, and an "Advanced"
  disclosure for the host URL. Remove the angle/grade/quality/ascents/setter/name/benchmark/listed/
  single-frame controls.
- **`buildFilter`**: `layoutIds = [layout]`, `sizeId`/`sizeBox` from the chosen known size, `maxClimbs`;
  leave the rest at their (no-op / listed+single-frame-on) defaults. `CatalogFilter` itself is unchanged.
- **`name(for:)`**: "Kilter · Original · 12 × 14 · top 2000" from the board + size + cap.

## Output

- `KilterCatalogSyncView.swift` / `KilterCatalogDownloadSheet.kt` — the static board table + the redesigned
  sheet + `buildFilter` + `name`.
- `docs/knowledge-graph/data.js` (`kilter-catalog-download`) + `decisions.md` + `project.md` updated.

## Acceptance criteria

- [ ] The download sheet shows only: Your board (Layout + Size), How many climbs, Download, and an
      Advanced (host) disclosure. No climbing filters at download.
- [ ] The size picker works on a first-ever download (no installed catalog), from the embedded board table.
- [ ] Picking a smaller board installs fewer climbs (the size box trims via the existing fit condition).
- [ ] The browse UI still offers angle/grade/quality/etc. (unchanged); `listedOnly`/`singleFrameOnly` stay
      on by default.
- [ ] iOS type-checks (Swift 6, 0 warnings); Android compiles; no UI test references removed controls;
      docs updated.

## Constraints

- On-device only; no Aurora API; nothing uploaded; no climb data embedded (only board dimensions, #42).
- Keep iOS + Android behavior identical; don't change `conditions()` (explorer parity) or the trim path.

## Test plan

1. iOS `xcodebuild build` + Android `:app:compileDebugKotlin` clean.
2. By eye: open Download with no catalog → pick Original / 12 × 14 / Most popular 2000 → installs; the
   browse list then filters by grade/angle/etc.
