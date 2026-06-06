# Prompt: Kilter — in-app catalog download from a hosted dataset (Phase 2)

**File**: pdd/prompts/features/23-kilter-aurora-in-app-sync.md
**Created**: 2026-06-06
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo. Android to follow.
**Chain**: Kilter opt-in catalog (#42, prompt 22) → Phase 2 (the previously-inert sync seam).
**Source**: GitHub issue [#42](https://github.com/harshal2802/snappet-mobile/issues/42) (Phase 2)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Let the user get the Kilter catalog **without** the `boardlib` + Files dance: a **Download from Kilter**
button that fetches a board's catalog as a gzipped SQLite from a static host the user controls (the
Snappet **Board Explorer** GitHub Pages site by default), trims it on-device to the chosen filters, and
installs it through the same path as a file import.

**Personal / sideload use only** — see Constraints. The file-import path stays the recommended/safe route
and is unchanged.

## Context the implementer needs

- The install orchestration (`KilterCatalogInstaller`: fetch → validate → install → notify) is
  source-agnostic and done — a real provider just returns a local `.sqlite3` URL.
- **Don't fetch Aurora directly.** Aurora's `/sync` host rejects all TLS handshakes (dead from any normal
  client), and the APK-extraction path `boardlib` actually uses is a 108 MB scrape from apkpure — heavy,
  fragile, worst legal posture. The user already publishes per-board datasets on their own Pages via the
  **Board Explorer** (`src/frontend/apps/board-explorer`), so download from there.
- The host serves `board-data/manifest.json` (boards + `importableToMobile` + `file` + sizes) and
  `board-data/<board>.sqlite.gz` (gzipped full SQLite; Kilter ≈ 81 MB gz → ~165 MB raw, 344k climbs).
  The schema matches the reader exactly (it's built to import into this app — `exportDb.ts` references
  `KilterCatalogValidator`).
- iOS has no public unzip/gzip API — link `libz.tbd` and `#import <zlib.h>` and stream-inflate
  (`inflateInit2_(…, 47)`).
- The full DB is far too big to install whole (~165 MB); it **must** be trimmed. The Board Explorer's
  `query.ts buildConditions` + `exportDb.ts` are the exact filter + subset algorithm to mirror.

## Approach

- `Features/Kilter/KilterAuroraSync.swift` = `HostedCatalogClient`: `importableBoards()` (reads the
  manifest), then `buildCatalog(board:filter:progress:)` = download `<board>.sqlite.gz` (progress) →
  stream-gunzip via zlib → **trim** (`buildFilteredCatalog`) → return a small `.sqlite3`. Trim mirrors
  `exportDb.ts`: `ATTACH` source, recreate tables from source DDL, copy `FULL_TABLES` whole, subset climb
  tables to a `_keep` set of filtered uuids, recreate indexes, `VACUUM`. `CatalogFilter` mirrors
  `buildConditions` + a `maxClimbs` top-N-most-climbed cap.
- `HostedCatalogProvider` (in `KilterCatalogProvider.swift`) wraps the client for the installer.
- UI: replace the inert button in `KilterCatalogSyncView` with **Download from Kilter…** → a
  `KilterCatalogDownloadSheet` (board picker from the manifest, top-N cap, Kilter-layouts/benchmarks
  toggles, editable host URL, progress, errors). No accounts.
- Tests: `KilterAuroraSyncTests` covers the real zlib gunzip (round-trip) and the filtered build (top-N,
  empty-match → throw, benchmark-only) by feeding `KilterCatalogFixture` as a synthetic source through
  the real reader.

## Output

- `KilterAuroraSync.swift` (rewritten), `KilterCatalogProvider.swift` (provider), `KilterCatalogSyncView.swift`
  (sheet + button), `SnappetTests/KilterAuroraSyncTests.swift`, `Snappet-Bridging-Header.h` + `project.yml`
  (libz). `decisions.md` + `docs/knowledge-graph/data.js` updated.

## Acceptance criteria

- [x] Button lists importable boards, downloads + trims + installs; browse/detail/log/illuminate work
      offline after. Real-data check: top-2000 → ~6 MB importable catalog.
- [x] Filters (top-N cap, layouts, benchmarks) narrow the installed set; empty match errors instead of
      installing junk; a failure leaves any prior catalog intact.
- [x] App type-checks against the iOS 18 SDK (Swift 6); zlib gunzip + filtered build are unit-tested.
- [x] No platform imports added to `HighlightEngine`; user-data model unchanged.
- [ ] **Device-verified**: the 81 MB download → gunzip → trim → install on the physical iPhone.

## Constraints

- **Not for public App Store distribution** (Aurora ToU + Guideline 5.2.2). Personal/sideload only; narrow
  named carve-out.
- No Aurora API calls; egress is one GET to the configured host; user-initiated only; no analytics, no
  backend, nothing uploaded. Don't touch the user-data model; don't re-bundle a catalog; file-import stays
  primary.
