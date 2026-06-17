# Prompt: HR stat tile — model + pure layout engine

**File**: pdd/prompts/features/74-ios-hr-tile-model-and-layout.md
**Created**: 2026-06-17
**Project type**: Native iOS feature (Swift) — code lands in this repo.
**Chain**: live-workout-studio/PLAN.md → Track B (studio) — HR overlay redesign, PR 1 of 3.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Replace the scattered, free-floating HR/fitness overlay badges (`HROverlayConfig.elements`, each
independently placed) with **one** resizable, draggable **stat tile**: a design chosen from a catalog,
with every metric individually toggleable and **all on by default**. This PR is the foundation — the
model + the *pure* layout function — with no UI and no export wiring, so it's the most heavily
unit-tested piece and the shared dependency of the other two PRs.

## Context the implementer needs

The 10 metrics already exist (`HROverlayMetric`) and `HROverlayValues` already resolves each to
text + `#RRGGBB`; reuse both unchanged. The tile must place itself with a normalized centre + size
(the same convention as a PiP / base-frame cell), so the existing `ClipEditGeometry.pipRect` +
`ResizableFrame` gesture can drive it later. **WYSIWYG is the hard constraint**: the SwiftUI preview
(PR 76) and the Core-Animation export (PR 75) must lay the tile out identically even though one works
in points (~hundreds wide) and the other in output pixels (~1080 wide).

## Approach

- New `HRTile.swift`: `HRTileTemplate` (7-case catalog: `scorebug` default, `hero`, `bento`, `list`,
  `ring`, `hudPill`, `chartBanner`) with per-template `spawnMetrics` / default frame; `HRTileMetricEntry`
  (ordered per-metric toggle, `on` defaults true); `HRTile` (template + entries + normalized
  centre/size + `showChart`); `HRTileMigration` (pure: folds legacy `elements[]` into a tile, zero
  data loss). Hand-written `Codable` (`decodeIfPresent ?? default`) — the documented gotcha.
- Add `HROverlayConfig.tile: HRTile?` (additive-optional, migration-safe). **Normalize SwiftData's
  phantom empty tile** (a nil nested-optional composite round-trips as an entries-empty tile with a
  random id) back to `nil` in `init(from:)` — a real tile always has every metric entry.
- New `HRTileLayout.swift`: a PURE (CoreGraphics only) `layout(template:enabledMetrics:tileRect:hasChart:)`
  → per-metric slot frames + roles + font sizes + optional chart rect. **Scale-invariant**: decisions
  from the rect's proportions, the 11pt floor only on the reported font (not the fit math); reflow
  drops trailing low-priority metrics (never bpm/zone) before going below the floor.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/HRTile.swift`
- `ios/App/Snappet/Features/WorkoutTracker/HRTileLayout.swift`
- `HROverlayConfig.tile` + migration-safe decode in `StudioProject.swift`
- Tests: `HRTileTests`, `HRTileLayoutTests`, `HRTileCodableTests`, `HRTileMigrationTests`

## Acceptance criteria

- [ ] `HRTile.make(.bento)` has all metrics on; `.hero` spawns only bpm+zone; toggling preserved on template switch.
- [ ] Layout invariants hold: scorebug bpm hero leftmost+largest, reflow drops trailing (keeps bpm/zone), bento 2→1 column reflow, list single-column truncate-from-bottom, ring collapse, font ≥ 11 everywhere, deterministic, order preserved.
- [ ] Legacy `elements[]` migrates with zero data loss; legacy/missing-field JSON still decodes; SwiftData phantom empty tile → nil (determinism regression).
- [ ] App type-checks (Swift 6, 0 warnings); no platform imports in `HRTileLayout`.
- [ ] `decisions.md` + knowledge-graph updated.

## Constraints

- On-device only; pure layout is platform-free + unit-tested with no simulator.
- Codable changes to persisted composites must be migration-safe (a non-optional field with a default still throws on a missing key).

## Test plan

1. `xcodebuild test -only-testing:SnappetTests` (the four new suites + the existing backup determinism test).
2. Confirm `swift`/type-check is clean and no `HighlightEngine` import leaks into the pure layout.
