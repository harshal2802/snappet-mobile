# Prompt: HR stat-tile "Glass HUD" redesign — foundation + Glass Hero Card default

**File**: pdd/prompts/features/77-ios-hr-tile-glass-redesign.md
**Created**: 2026-06-17
**Project type**: Native iOS feature (Swift / SwiftUI + Core Animation) — code lands in this repo.
**Chain**: HR overlay redesign (supersedes the #160–#162 catalog) → P1 (default + foundation).
**Source**: GitHub issue [#163](https://github.com/harshal2802/snappet-mobile/issues/163) + `docs/design/hr-tile-redesign/IMPLEMENTATION.md` (branch `design/hr-tile-mockups`).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The #160–#162 HR stat tile gave all ~10 metrics equal, too-small slots, so on a real phone the text
**crops** and looks unpolished. Rebuild the visual language as a premium **"Glass HUD"** with a strict
**hero → secondary → tertiary** hierarchy and an **anti-crop layout engine**, bring back the live HR
chart as a premium **zone-banded trace**, and make **Glass Hero Card the default with the sparkline ON**.
This prompt ships the shared foundation + the default design; prompt 78 ships the rest of the catalog.

## Context the implementer needs

The architecture from #160–#162 stays: the pure `HRTileLayout` is the single source of truth feeding
BOTH the SwiftUI preview (`HRTileView`) and the Core-Animation export burn-in
(`StudioOverlays.hrTileLayer`) — so what the user places is what burns into the file (WYSIWYG). The
model `rawValue`s are unchanged (persisted tiles + the walkthrough UITest's `studioTileTemplate.<raw>`
ids keep working); only the visual language, default frames, and spawn sets change. Migration-safe
Codable + the SwiftData phantom-empty-tile→nil normalization stay.

## Approach

- **`HRTile.swift`** — add the shared `HRTileStyle` glass kit (hex/alpha/fraction-radii, pure so both
  render sides read the same numbers). New default frames + raised minimums (`minWidth 0.18`,
  `minHeight 0.09`), focused per-template `spawnMetrics` (never all 10), `spawnShowChart` per the issue
  table, and `minHeightWithChart`. Default template = `hero`.
- **`HRChartGeometry.swift`** — pure premium-curve recipe: `smoothedPath` (Catmull-Rom→bézier `CGPath`,
  consumed by both `Path(cgPath)` and `CAShapeLayer`), `peakIndex`/`peakBPM`, `zoneStops` (zone-banded
  stroke gradient stops by bpm).
- **`HRTileLayout.swift`** — anti-crop engine: per-template hard `visibleCap` + `hiddenCount` (→ `+N`),
  honest value-only width estimate (em-advance 0.66, real value-only char counts), premium Glass Hero
  Card layout (zone pill · giant hero · sparkline · ≤3 value-only chips), fraction-based chart carve.
- **`HROverlayValues.swift`** — `Reading.value`/`unit` (value-only + inline unit) alongside the legacy
  `text`; `ResolvedHRTile.maxHR` so the export chart tints against the same bound as the preview.
- **`HRTileView.swift`** — glass-card backing, premium hero/zone-pill/chip/field renders (tabular
  rounded), and `PremiumHRCurve` (smooth zone-banded stroke + area + glow + playhead dot).
- **`StudioOverlays.swift`** — mirror the glass kit + premium curve (`CAGradientLayer` masked by the
  stroke shape, paced dot riding the smoothed path, baked peak label) + **tabular rounded `UIFont`**
  (the export's missing-tabular fix) in every text layer.
- **`StudioEditorViewModel.swift`** — default `hero`; the chart toggle nudges `tile.height` up to
  `minHeightWithChart` so the curve always has room.

## Output

The files above, plus extended `HRTileLayoutTests` / `HRTileTests` / `HRTileResolveTests`.

## Acceptance criteria

- [x] Default tile = Glass Hero Card with the sparkline ON; reads cleanly the instant it's placed.
- [x] Every template honors a hard visible cap; "toggle all 10 on" parks the overflow as `hiddenCount`
      (`+N`) instead of cropping.
- [x] Preview == export: same shared smooth `CGPath` + zone stops; full curve + moving dot (no
      `strokeEnd` draw-on, which the per-frame SwiftUI preview can't replicate).
- [x] Migration-safe Codable + the SwiftData phantom-tile→nil normalization unchanged.
- [x] App type-checks against the iOS SDK (Swift 6, 0 warnings); full `SnappetTests` green.
- [x] No platform imports added to `HighlightEngine`.
- [x] `decisions.md` + the knowledge graph updated.

## Constraints

- On-device only; the burned-in `.mp4` (glass over footage, gradient-stroke orientation, font metrics,
  Y-flip) is the manual device-burn-in checklist item — type-check + sim tests ≠ device pixels.
- Keep `HRTileLayout` platform-free (CoreGraphics only) and scale-invariant (decisions in points vs
  pixels must not diverge) — the 11pt floor stays OUT of the fit math.

## Test plan

1. `xcodebuild build` (0 warnings) + `xcodebuild test -only-testing:SnappetTests` on iPhone 17 Pro.
2. The studio walkthrough XCUITest still drives the tile builder (enable → catalog → toggle a metric).
3. Device burn-in of an exported clip (manual): the Glass Hero Card + sparkline matches the editor.
