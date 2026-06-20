# Prompt: F7 — iOS WallView masonry send-wall + grid toggle

**File**: pdd/prompts/features/feed/F7-ios-wallview.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: PLAN.md → F7 (depends on F1)
**Source**: GitHub epic "Recap Feed" → issue "F7 iOS Wall/send-wall"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §3 (IA sub-surface 2 + flow), §5 (card taxonomy, the corpus), §6.1 (Pillar 1 visual cards), §11 wireframe 15

## Goal

Build the **Wall** — the "send wall" masonry/waterfall surface that re-renders the *same* `FeedComposer` corpus as a visual portfolio grid (`_locked-design.md:43`), and wire the **grid toggle** in the `FeedView` header (the affordance F1 stubbed, `_locked-design.md:42`, F1 prompt:25) so it actually opens the Wall. This is the **identity-at-a-glance retention surface** — Instagram-grid + Pinterest-masonry grammar — that lets a user feel the *shape* of their climbing/training history in one scroll, and one tap from any tile into the existing `CardDetailView` (`_locked-design.md:43-44`, flow `:56-57`). It reuses the composer and card payloads verbatim; it introduces zero new math and zero new card kinds.

## Context the implementer needs

- **Same corpus, different layout.** The Wall reads the **identical** `FeedComposer.compose(window: .allTime, …)` output that `FeedView` renders (`_locked-design.md:43`, F1 prompt:19). It must **not** re-derive stats, re-query stores, or compose its own cards — it consumes the already-composed `[FeedCard]` value snapshots (`TodayDigest` derive-on-read pattern, `ios_models.md:533`). The only difference from F1 is the geometry: a multi-column waterfall instead of a single `LazyVStack` column.
- **Keystone rule — no new cards, no ordering edits.** F7 adds **zero** `FeedCardKind` cases and makes **zero** changes to F0's ordering/eligibility/salience core or the `FeedComposer` registry. The Wall is purely a *view* over existing composer output. If a tile needs a compact visual, derive it from the existing `FeedCardPayload` (`_locked-design.md:124`) — never by adding a composer entry.
- **iOS layout = waterfall columns, not a uniform grid** (`_locked-design.md:43`: "waterfall `LazyVStack` columns on iOS"). Build N balanced columns (2 on compact width, 3 on regular) each as a `LazyVStack`, distributing cards by shortest-running-column height so tiles of differing intrinsic heights pack tightly (Pinterest masonry). The column-assignment + height-balancing is **pure** and must be unit-tested (stable, deterministic, no card dropped or duplicated across columns). Do **not** use a fixed-row `LazyVGrid` — that loses the masonry feel the design names.
- **Tile rendering reuses Pillar-1 components** (`_locked-design.md:194`, reuse table `:271-272`). Each tile is a compact `FeedCard` built from `PulsePro.DisciplineHero` (climbing-native hero: hardest grade / mini-pyramid, **not** a route map) + a trimmed `StatRibbon` + `.snappetCard()` on `SnappetColor` tokens with the discipline edge-accent (`SnappetColor.kilter`/`.workout`). Reuse `PulsePro.swift:11` and `SnappetCard.swift:28` verbatim; reuse F1's `FeedSessionCard` styling vocabulary in a denser tile form rather than inventing a new visual language. A tile with no media uses the **generated `DisciplineHero` fallback** (same chain F1 established).
- **Tap → CardDetailView (push).** Tapping a tile pushes the same `CardDetailView` F2 built (`_locked-design.md:44`, flow `:57`); F7 does **not** create a new detail surface. Route the tapped `FeedCard` into the existing detail destination.
- **Grid toggle in the FeedView header.** F1 shipped the toggle as an honest placeholder routed to a Stage-0 target (F1 prompt:25, `:60`). F7 replaces that placeholder so the toggle now switches `FeedView` ↔ `WallView` (a header control, e.g. a list/grid `Picker` or icon button) — no dead button, no separate tab. State (which layout is active) lives in `FeedView` and persists for the session; the Lens bar selection (`_locked-design.md:42`) carries through so the Wall honors the active lens via the same F0 pure post-filters.
- **Keyset pagination is inherited, not reinvented.** Reuse F1's `FeedPagination` `(published,id)` cursor (F1 prompt:33, `_locked-design.md:96`) to lazily decode the next page; the waterfall appends new cards into the shortest columns as pages load. Do not add a second pagination path.
- **No HR-only / media-only hardwiring; degrade by absence.** Tiles render from whatever payload the card carries — a card that lacks media simply shows the generated hero; the Wall never shows an empty/greyed tile (`_locked-design.md:188`, §7). Android is FA5 (out of scope here).
- New files land in `ios/App/Snappet/Features/Feed/` (F0/F1 created the dir).

## Approach

- `Feed/WallView.swift`: a `ScrollView` containing an `HStack` of N `LazyVStack` columns (column count chosen by horizontal size class — 2 compact / 3 regular). Each column lazily renders the `FeedWallTile`s assigned to it. Drives lazy next-page loading via F1's `FeedPagination` cursor; appends incoming cards into the shortest column.
- `Feed/FeedWallLayout.swift`: a **pure** masonry distributor — input `[FeedCard]` (+ an estimated intrinsic height per `FeedCardKind`/payload), output `[[FeedCard]]` (one array per column) via shortest-column-height packing. Deterministic and total (every input appears exactly once). This is the unit-tested core.
- `Feed/FeedWallTile.swift`: the compact tile view (`DisciplineHero` + trimmed `StatRibbon` + `.snappetCard()` + edge accent + generated-hero fallback), tappable → pushes the existing `CardDetailView` with the card.
- `Feed/FeedView.swift` (edit): replace the F1 grid-toggle placeholder with a real toggle that flips an `@State` layout mode (`.feed` / `.wall`), rendering `WallView` when `.wall`; pass the active lens/post-filter selection through to it.
- Pure helpers (column assignment, height estimation, no-drop/no-dup invariants) go in the testable layout file; XCUITest covers toggle → Wall → tap-tile → detail → back-to-feed.

## Output

- `Feed/WallView.swift` — waterfall masonry surface (N `LazyVStack` columns) over the F1 composer corpus + lens pass-through + inherited keyset pagination.
- `Feed/FeedWallLayout.swift` — pure masonry distributor (`[FeedCard]` → balanced `[[FeedCard]]` columns by shortest-column packing; deterministic, total).
- `Feed/FeedWallTile.swift` — compact Pulse-Pro tile (DisciplineHero + trimmed StatRibbon + `.snappetCard()` + generated-hero fallback) tapping into the existing `CardDetailView`.
- `Feed/FeedView.swift` (edit) — grid toggle now flips Feed ↔ Wall; lens selection carries through.
- `SnappetTests/FeedWallLayoutTests.swift` — pure column-distribution tests: no card dropped/duplicated; balanced (shortest-column) packing; deterministic given identical input; correct column count by size class input.
- `SnappetUITests/FeedWallUITests.swift` — Recap tab → grid toggle → Wall renders multi-column tiles → tap a tile → `CardDetailView` pushes → back returns to the Wall (and toggle back to Feed restores list).
- `docs/knowledge-graph/data.js` — add a `wall` (screen) node; `navigate` edge feed→wall (grid toggle) and wall→card-detail (tap tile); `feeds` edge feed-composer→wall (same corpus). (No new card/composer nodes — keystone unchanged.)

## Acceptance criteria

- [ ] The `FeedView` header grid toggle flips between the F1 list feed and the new `WallView` (no dead button, no new tab); toggling back restores the list. The active **Lens** selection carries through to the Wall via F0's pure post-filters.
- [ ] `WallView` renders the **same** `FeedComposer.compose(window:.allTime)` corpus as a **waterfall** of 2 columns (compact width) / 3 columns (regular width), each a `LazyVStack`; tiles of differing heights pack tightly (Pinterest masonry, not a uniform grid).
- [ ] Each tile is a compact `FeedCard` on `PulsePro.DisciplineHero` + trimmed `StatRibbon` + `.snappetCard()` with discipline edge accents; a card with no media uses the generated `DisciplineHero` fallback. **No new `FeedCardKind` cases and no edits to F0's composer registry / ordering core** (keystone preserved).
- [ ] Tapping a tile pushes the **existing** `CardDetailView` for that card (no new detail surface); back returns to the Wall at the same scroll position.
- [ ] The masonry distributor is pure and unit-tested: every card appears in exactly one column (no drop/dup), packing is shortest-column-balanced and deterministic, and column count follows the size-class input.
- [ ] Lazy next-page loading reuses F1's `(published,id)` keyset cursor (no second pagination path); new cards append into the shortest columns. App type-checks (Swift 6, 0 warnings); `decisions.md` updated if a non-obvious choice was made.

## Constraints

- On-device only; derive-on-read (no card persistence). Reuse `PulsePro`/`SnappetCard`/`SnappetColor` — no new brand tokens, no new card visual language beyond a denser form of F1's tile. Reuse F0's composer + lens post-filters and F1's pagination cursor; do not re-derive stats or re-compose cards in the Wall.
- **Keystone rule:** new cards are only ever added as `FeedComposer` registry entries + `FeedCardKind` cases — F7 adds none and must not touch the F0 ordering core. The Wall is a layout over existing output.
- The grid toggle and tile-tap route to real surfaces (`WallView`, the existing `CardDetailView`) — never dead buttons. Masonry is waterfall `LazyVStack` columns, not a fixed-row grid.

## Test plan

1. Unit: `FeedWallLayoutTests` green — assert no-drop/no-dup over the F0 golden corpus, shortest-column balance within tolerance, deterministic output for identical input, and 2-vs-3 column count by size-class input; build-for-testing.
2. XCUITest: launch `--start-tab feed` → tap the grid toggle → assert multi-column Wall tiles render → tap a tile → assert `CardDetailView` pushes → back → assert Wall scroll position preserved → toggle back → assert list feed restored. Sim wedge → `xcrun simctl shutdown all`, re-run.
3. Sanity by eye: confirm masonry packs tiles of differing heights tightly (no large ragged gaps) and the discipline edge accents/heroes match F1's card vocabulary; share/HR/media paths remain device-burn items owned by F2–F4 (none introduced here).
