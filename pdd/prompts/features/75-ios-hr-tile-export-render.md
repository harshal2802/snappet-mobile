# Prompt: HR stat tile — export burn-in

**File**: pdd/prompts/features/75-ios-hr-tile-export-render.md
**Created**: 2026-06-17
**Project type**: Native iOS feature (Swift) — code lands in this repo.
**Chain**: live-workout-studio/PLAN.md → Track B (studio) — HR overlay redesign, PR 2 of 3. Depends on NN 74.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Burn the unified HR stat tile into the exported video — one composite card (scrim + per-metric slots +
an optional chart register) laid out by the **same** pure `HRTileLayout` the editor preview uses, so
the file matches what the user placed (WYSIWYG). Replaces the per-badge `hrElementLayers` path when a
tile is configured.

## Context the implementer needs

The export render tree is bottom-left origin (the `AVVideoCompositionCoreAnimationTool`'s layer space),
so the top-left slot frames `HRTileLayout` returns must be Y-flipped into the tile container. Live
metrics still cross-fade per-value opacity layers (Core Animation can't redraw text per frame). The
composer already threads per-clip HR (`StudioClipHRContent` / `PlacedClipHR` / `clipHRByID`) and a
session-wide fallback through `makeAnimationTool`; the tile follows the SAME plumbing. The value layer
stays pure: `HROverlayValues` resolves the tile (`resolveTile`) into a `Sendable ResolvedHRTile` that
crosses the export actor — the device renderer stays dumb.

## Approach

- `HROverlayValues.resolveTile(_:) → ResolvedHRTile?` (pure): each enabled metric's segments, dropping
  no-data metrics; nil when nothing renders (no metric + no chart).
- `StudioOverlays.hrTileLayer(_:samples:canvas:totalDuration:slotStartSec:slotDurationSec:)`: a card
  CALayer at the tile's flipped rect; runs `HRTileLayout`; one child per slot by role (pill / value+caption
  / gauge ring / chart sparkline), per-segment opacity-gated for animated-live metrics; the whole tile
  opacity-gated to its clip slot (multi-clip). Reuse `gateSegmentOpacity` + the chart dot's
  strictly-increasing-keyTimes pattern.
- `makeAnimationTool` gains a tile branch (per-clip + session-wide) that supersedes `hrElementLayers`.
  Thread `ResolvedHRTile` through `StudioComposer` (makeComposition / assemble / single-track +
  transitions / export) and `StudioClipHRContent.tile` / `PlacedClipHR.tile`. VM resolves per-clip +
  session tiles; suppress the legacy badge path when a tile is set.

## Output

- `ResolvedHRTile` / `ResolvedTileMetric` + `resolveTile` in `HROverlayValues.swift`
- `hrTileLayer` + render helpers in `StudioOverlays.swift`; tile path in `makeAnimationTool`
- `tile` field on `StudioClipHRContent` / `PlacedClipHR`; `hrTile:` threaded through `StudioComposer`
- VM: `resolvedSessionTile()` / `resolveClipTile(_:samples:)`; export passes `hrTile:`

## Acceptance criteria

- [ ] `resolveTile` drops no-data metrics, keeps a chart-only tile, returns nil for nothing, preserves order; a live metric yields multiple segments, a static one a single `[0,1]` segment.
- [ ] App type-checks; the whole composer/export chain compiles; legacy badge path still works when no tile is set.
- [ ] Device-only burn-in verification noted as a manual checklist item (sim can't render the `.mp4`).
- [ ] `decisions.md` + knowledge-graph updated.

## Constraints

- Honor the device-only limits: tool attached only for export (`forPlayback == false`), strictly-increasing keyTimes, per-value cross-fade for live text.
- The pure value layer (`HROverlayValues`) gains the tile resolver but stays platform-free + unit-tested.

## Test plan

1. `xcodebuild test -only-testing:SnappetTests/HRTileResolveTests` (+ full suite green).
2. `xcodebuild build-for-testing` clean (the composer threading compiles).
3. Device: record a session, film clips early/late, export, confirm each clip's tile shows its OWN window's metrics (Core-Animation burn-in can't render on the sim).
