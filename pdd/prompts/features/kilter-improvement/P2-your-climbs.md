# Prompt: P2 — Your Climbs gallery (the climbs you set)

**File**: pdd/prompts/features/kilter-improvement/P2-your-climbs.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI).
**Chain**: PLAN.md → P2 (independent; can run in parallel with P0/P1)
**Source**: GitHub issue — Kilter Improvement P2
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Design**: `docs/ux-research/kilter-improvement/README.md` §4 (Flow 2) · wireframes `02_yourclimbs`, `02b_actions`

## Goal

Promote the buried, layout-scoped, text-only **Mine** filter into a first-class **Your Climbs** gallery — a
board-thumbnail grid of the climbs you authored, global across layouts, with status + filter/sort + the
canonical per-card actions. The lit-holds render *is* the climb's identity, so lead with thumbnails.

## Context the implementer needs

- Created climbs persist as `KilterCreatedClimb` (`@Model`, `KilterCreatedClimb.swift`) with an `asClimb`
  adapter to `KilterClimb` for render/detail/share; `KilterCreatedClimb.delete(_:in:)` (`:153`) is the
  canonical delete — it **keeps logged ascents**, drops the favorite, de-indexes Spotlight.
- Today "Mine" is `createdListItems()` + the Mine filter query (`KilterRootView.swift:621-634`), rendered in
  the private text-only `KilterClimbRow` with quality/ascents zeroed and **no thumbnail**; climbs set on
  other layouts vanish.
- The thumbnail primitive exists but is unused in lists: `KilterBoardView(geometry:holds:)`
  (`KilterBoardView.swift:13-15`) fed by `catalog.holds(for:sizeId:)` + `boardGeometry(forLayout:sizeId:)`
  (`KilterCatalog.swift:318-343,403-408`) from a created climb.
- Per-climb own status = count `KilterLogEntry where climbUUID == created.uuid` (the `logCount` pattern,
  `KilterClimbDetailView.swift:674`). **No community signals** (none on-device).
- Edit re-opens `CreateClimbView(editing:)`; Duplicate clones holds as a new draft (use
  `KilterDuplicateChecker` + `KilterClimbIdentity` to de-dup at save, never in the gallery); Share = QR via
  `KilterShareView(climb:gradeLabel:angle:)` (`:48`).

## Approach

- Add `KilterCreatedView` on a new `KilterCreatedRoute` (pushed on the shared `NavigationPath`, the
  `KilterSessionRoute` pattern at `KilterRootView.swift:229`). Header = `DisciplineHero` "N climbs set" +
  coral "Set a climb" CTA.
- Default 2-up board-thumbnail grid (cached `KilterBoardView` per cell) with a grid/list toggle (persisted),
  **global across layouts** (a board/layout facet), a Draft/Saved/All status segment, filter+sort chips
  (status · board · angle · source; sort Recently-set [default] / grade / most-climbed-by-you), search.
- Per-card meta: grade badge, provenance (Hand-set / Generated) glyph+label, angle, own-status chip
  (Sent / Project / Untried). Per-card actions: Edit / Duplicate / Share / Delete (delete confirm makes the
  keep-ascents guarantee visible). Tap → existing climb detail (`resolveClimb` falls back to `asClimb`).
- Real empty state (`ContentUnavailableView`: figure.climbing + "Set a climb" + secondary "Generate one").
- Extract the private `KilterClimbRow` only if the list view reuses it. **Prefer deriving a Draft state**
  from a failed `kilterValidate` over adding a schema flag (assess; avoid a `KilterCreatedClimb` schema add).

## Output

- `KilterCreatedView.swift` (gallery, grid + list) + route registration in `KilterRootView`.
- A pure helper for the gallery's query/sort/filter + own-status join (testable).
- `docs/knowledge-graph/data.js` new screen node + nav edges.
- Unit tests in `SnappetTests`; XCUITest for browse + card actions.

## Acceptance criteria

- [ ] Your Climbs shows a thumbnail grid of authored climbs **across all layouts**, with status segment,
      filter/sort, search, per-card provenance + own-status, and Edit/Duplicate/Share/Delete.
- [ ] Delete keeps logged ascents (confirm copy states it); tapping a card opens the existing climb detail.
- [ ] Pure query/sort/filter + own-status-join helper is unit-tested (global vs layout-scoped, status
      segmentation, sort orders, own-status count). XCUITest covers browse + actions.
- [ ] No `KilterCreatedClimb` schema change unless a Draft field is unavoidable; if added, backup Row +
      schema + `SnappetBackupTests` stay green.
- [ ] App type-checks (Swift 6, 0 warnings); `decisions.md` updated.

## Constraints

- On-device only; local data only (no community ascents/quality). Per-cell thumbnails call SQLite-backed
  `catalog.holds(...)` — cache/lazy-decode so a large grid doesn't jank.

## Test plan

1. Unit: gallery helper + own-status join green; build-for-testing.
2. XCUITest: open Your Climbs → grid renders thumbnails → filter/sort → per-card action sheet → delete
   confirm keeps ascents → tap opens detail. Sim wedge → `xcrun simctl shutdown all`.
