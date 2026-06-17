# Prompt: HR stat tile — editor UX (catalog, toggles, drag/resize)

**File**: pdd/prompts/features/76-ios-hr-tile-editor.md
**Created**: 2026-06-17
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: live-workout-studio/PLAN.md → Track B (studio) — HR overlay redesign, PR 3 of 3. Depends on NN 74 (visually completes NN 75).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The editor side of the unified HR tile: a design-catalog picker, per-metric ON/OFF rows (all on by
default), and a draggable + corner-resizable tile rendered WYSIWYG on the studio canvas — so the user
builds the overlay they'll see in the export.

## Context the implementer needs

All HR edits flow through the existing single seam `vm.updateHROverlay(config) → editOverlaysOnly →
undo.commit + persist` (no preview rebuild — the overlay is export-only). The tile is rendered as a
sibling over the preview (like `StudioHRChartView`), NOT inside `StudioOverlayCanvas`, so it carries
its own drag + corner-resize (a free-aspect adaptation of `ResizableFrame`'s flicker-free pattern:
handles anchored at the committed size, model written once on gesture end). The preview must run the
SAME `HRTileLayout` the export uses so resizing reflows the metrics live. Loading a session must
upgrade any legacy `elements[]` overlay to a tile (the pure `HRTileMigration` from NN 74).

## Approach

- `HRTileView` (pure SwiftUI render via `HRTileLayout` + `HROverlayValues`, incl. a per-template
  sparkline) + `HRTileEditorView` (the draggable/corner-resizable frame), in `HRTileView.swift`.
- Wire the tile sibling into `StudioEditorView` (supersedes the legacy chart + badge siblings when a
  tile exists). Rewrite `StudioHRControls`: a "Show heart-rate tile" enable, a horizontal design
  catalog (`HRTileTemplate.allCases`), per-metric ON/OFF rows + Live/Animate (made scrollable). Keep
  the legacy badge controls only as a pre-migration fallback.
- VM mutators (all via `updateHROverlay`): `selectTileTemplate` / `toggleTileMetric` /
  `setTileMetricLive` / `setTileMetricAnimated` / `setTileShowChart` / `setTileFrame`; `toggleHROverlay`
  spawns a Scorebug tile; `migrateHRTileIfNeeded()` on overlay-context load.
- Add `studioActionBar` accessibility id so the UITest can scroll the HR tool into view.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/HRTileView.swift`
- `StudioHRControls` rewrite + tile sibling in `StudioEditorView.swift`
- Tile mutators + migration hook in `StudioEditorViewModel.swift`
- The studio-walkthrough XCUITest exercises the tile builder (enable → pick design → toggle a metric → dismiss)

## Acceptance criteria

- [ ] The catalog switches templates preserving toggles; metrics are all-on by default and individually toggleable; the tile drags + corner-resizes and commits via `editOverlaysOnly` (no rebuild).
- [ ] The preview renders the tile via the same `HRTileLayout` as the export (WYSIWYG, reflows on resize).
- [ ] A loaded legacy `elements[]` overlay is migrated to a tile on appear (zero data loss).
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` green; the studio XCUITest passes.
- [ ] `decisions.md` + knowledge-graph updated; mark `HROverlayElementsView` legacy.

## Constraints

- This PR changes real UI → run the XCUITest suite (per the UI-suite policy). Drag/corner-resize feel is device-only.
- The overlay is export-only — no playback rebuild on a tile edit.

## Test plan

1. `xcodebuild test -only-testing:SnappetTests` (no regressions).
2. `xcodebuild test -only-testing:SnappetUITests/LiveWorkoutStudioWalkthroughTests` (the tile builder steps).
3. Sanity by eye via the captured walkthrough screenshots (`11f`/`11g`).
