# Prompt: P4 — Redesigned session history

**File**: pdd/prompts/features/kilter-improvement/P4-session-history.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI; additive SwiftData migration).
**Chain**: PLAN.md → P4 (depends on P0; sequence **after** P3 — both touch `KilterHistoryView`)
**Source**: GitHub issue — Kilter Improvement P4
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Design**: `docs/ux-research/kilter-improvement/README.md` §4 (Flow 4) · wireframes `04_history`, `04b_detail`

## Goal

Turn the flat reverse-chron session list into a grouped, scoped, filterable timeline with roll-up headers,
a consistency heatmap **and** a tappable month calendar, adaptive session cards, and a session detail that
gains naming + notes + date/angle editing.

## Context the implementer needs

- Today `KilterHistoryView` is one flat list: `KilterSession.sessionId` join + sessions filter (`:166`),
  leaf row `KilterAscentRow` (`:194`), no grouping/search/filter/naming. (P3 already removed its inline
  aggregation — build on that; coordinate to avoid a merge collision.)
- `KilterSession` (`@Model`, `KilterModels.swift`) currently stores only `angle` + `source` — no
  title/notes/layout. Per the decision, add **additive optional** `title` / `notes` / `layoutId`
  (lightweight migration).
- Roll-ups + adaptive card facts come from `KilterAllTimeStats` (P0). Grade labels honor
  `kilterDisplayGrade` (`KilterSessionDetailView.swift:631`).
- The template for month-group + faceted-chip + stale-filter-recovery is the WorkoutTracker
  `HistorySectionView`; the all-axis metadata-edit pattern is the gym tracker `SessionDetailView` edit
  (commit `6f8d2a9`). Lifecycle `KilterSessionManager.end/recover` (`KilterBoardController.swift:350`) and
  the `KilterSessionRoute`/detail route stay unchanged.
- Any new `@Model` field pays the `SnappetBackup` mirror tax (`KilterSessionRow` template) +
  `SnappetSchema.models` (`SnappetCore.swift:39-53`); both `SnappetBackupTests` tripwires must stay green.

## Approach

- Regroup `KilterHistoryView` into month/week/all buckets; sticky headers double as roll-ups
  ("June — 7 sessions · 41 sent · hardest V7"). Add a scope switcher (Week/Month/All), faceted filter chips
  (board/angle/grade/status/source) + search with stale-filter recovery, and **both** a GitHub-style
  consistency heatmap and a tappable month calendar (each doubling as navigation).
- Adaptive 3-4-fact session cards (Strava rule, one badge max): default Sends · Hardest · Duration, swapping
  in a Flash-rate chip / PR badge / # projects when notable; a BLE/Manual provenance glyph+label; a live
  pulse on active sessions. Cards keep pushing the unchanged `KilterSessionRoute`.
- Add additive optional `title`/`notes`/`layoutId` to `KilterSession` + the backup mirror; add
  naming + notes + date/angle edit to `KilterSessionDetailView` (mirror the gym all-axis edit). Add
  swipe-to-edit on ascent rows (keep swipe-to-delete).

## Output

- `KilterHistoryView` regrouped (scope + filters + search + heatmap + calendar + adaptive cards).
- New consistency-heatmap + month-calendar components.
- `KilterSession` additive fields + `SnappetBackup` Row/File/recordCount/snapshot/restore + schema reg.
- `KilterSessionDetailView` naming/notes/metadata edit. Pure helpers (bucketing/scope/filter/adaptive-fact)
  + `SnappetTests`. `docs/knowledge-graph/data.js` edited History node + edges. XCUITest.

## Acceptance criteria

- [ ] History groups into month/week/all buckets with roll-up headers; scope switcher, faceted filters +
      search (with stale-filter recovery), heatmap + calendar (both navigate), and adaptive cards (one badge
      max) all work; cards open the unchanged detail route.
- [ ] Session detail can name a session, add notes, and edit date/angle (additive fields); ascent rows have
      swipe-to-edit + swipe-to-delete; `KilterSessionManager.end/recover` lifecycle unchanged.
- [ ] New `KilterSession` fields round-trip through `SnappetBackup`; `SnappetBackupTests.testCodecCoversEverySchemaModel`
      + the count tripwire stay green; a pre-change `KilterSession` blob decodes (migration).
- [ ] Pure bucketing/scope/filter/adaptive-fact helpers unit-tested; `KilterSessionRecovery`/`LiveSnapshot`
      tests stay green. App type-checks (Swift 6, 0 warnings); `decisions.md` updated.

## Constraints

- On-device only; Kilter-board data only. Additive optionals only (lightweight migration) — no destructive
  schema change. Enum raw strings mirrored verbatim in the backup Row.

## Test plan

1. Unit: helpers + migration decode + backup round-trip green; build-for-testing.
2. XCUITest: grouped timeline → scope/filter/search → heatmap/calendar nav → card → detail → name + notes +
   edit date/angle → swipe-edit an ascent. Sim wedge → `xcrun simctl shutdown all`.
