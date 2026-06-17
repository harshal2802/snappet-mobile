# Prompt: HR stat-tile — transparency control + plain-English metric explanations

**File**: pdd/prompts/features/79-ios-hr-tile-opacity-legend.md
**Created**: 2026-06-17
**Project type**: Native iOS feature (Swift / SwiftUI + Core Animation) — code lands in this repo.
**Chain**: HR overlay redesign → P3 (on-device feedback polish), stacked on prompts 77–78.
**Source**: on-device feedback after #164/#165 — "transparency can be controlled" + "explain what the info means".

## Goal

Two small additions after seeing the redesigned tiles on a real phone: (1) a **whole-tile transparency
(opacity) control** so the footage can show through more/less, and (2) **plain-English explanations** of
each metric in the builder so the user knows what they're putting on the video and what it means.

## Approach

- **`HRTile.opacity`** (Double, default 1.0, clamped to `minOpacity = 0.25`, migration-safe Codable);
  threaded through `ResolvedHRTile`.
- **Render both sides:** SwiftUI applies `.opacity(...)` to the whole tile; the export multiplies it into
  the tile container — composed with the per-clip gate by adding a `level:` to `gateSegmentOpacity`
  (gated tile ramps to `opacityF`; whole-timeline tile sets `container.opacity`), so preview == export.
- **`HROverlayMetric.explanation`** — a one-line description per metric, shown as a secondary caption
  under each toggle in `HRTileMetricRow`.
- **Builder UI:** an `Opacity` slider (`HRTile.minOpacity…1`) under the chart toggle + a one-line "what
  the captions are" hint.

## Acceptance criteria

- [x] Tile opacity is user-adjustable, clamped to a legible floor, identical in preview + export.
- [x] Each metric shows a plain-English explanation in the builder.
- [x] Migration-safe (old blobs decode `opacity = 1.0`); round-trips; clamps a too-faint persisted value.
- [x] App type-checks (Swift 6, 0 new warnings); `SnappetTests` green (opacity Codable/clamp/resolve +
      explanation-coverage tests) + the studio walkthrough UITest.

## Constraints

- On-device only for the burn-in; keep `HRTileLayout` platform-free (opacity is a render/model concern,
  not layout).

## Test plan

1. `xcodebuild build` + `xcodebuild test -only-testing:SnappetTests` on iPhone 17 Pro; studio walkthrough UITest.
2. Device burn-in: a low-opacity tile shows more footage; the burned-in clip matches the editor.
