# Prompt: HR stat-tile "Glass HUD" redesign — the full premium catalog

**File**: pdd/prompts/features/78-ios-hr-tile-premium-catalog.md
**Created**: 2026-06-17
**Project type**: Native iOS feature (Swift / SwiftUI + Core Animation) — code lands in this repo.
**Chain**: HR overlay redesign → P2 (the remaining 6 templates), stacked on prompt 77.
**Source**: GitHub issue [#163](https://github.com/harshal2802/snappet-mobile/issues/163) + `docs/design/hr-tile-redesign/IMPLEMENTATION.md`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Phase 2 of the HR stat-tile redesign: bring the **six non-default templates** to their bespoke premium
geometry (the default Glass Hero Card shipped in prompt 77). The PR1 foundation (glass kit, value-only
chips, premium zone-banded curve, tabular fonts, anti-crop engine) already lifts every template; this
adds each design's distinctive shape so the full catalog matches the issue #163 mockups.

## Context the implementer needs

`HRTileLayout` is the pure single source of truth feeding both the SwiftUI preview (`HRTileView`) and
the Core-Animation export (`StudioOverlays`) — every new shape must render identically on both sides
(WYSIWYG), and Core Animation's bottom-left origin means new geometry needs the Y-flip handled. Two new
primitives are shared: a `.zoneBar` role (5-cell / vertical zone indicator) and a `Decoration`
(accent bar / gradient skin) the layout places so both renders draw it from the same frame.
`Reading.fraction` (0…1) carries %HRR/redline for the gauge sweep + bars.

## Approach

Per-template, in `HRTileLayout` (geometry) + `HRTileView` (SwiftUI) + `StudioOverlays` (export):
- **HR Trace** (`chartBanner`): top row (bpm hero + zone pill) · full premium curve · 4-up AVG·PEAK·KCAL·EFFORT row.
- **Broadcast** (`scorebug`): zone-coloured accent bar · bpm hero · 5-cell zone bar · right stat columns · full-width chart lane.
- **Vertical Rail** (`list`): bpm hero · vertical zone bar · label→value rows.
- **Zone Ring** (`ring`): %HRR **sweep** gauge (zone encoded in the arc colour, no zone slot) · centred bpm · ≤2 chips — fixing the old gauge+chip double-count.
- **Gradient Strain** (`bento`): the Glass Hero layout on an **effort-driven gradient skin** (colour doubles as a metric).
- **HUD Pill** (`hudPill`): already a compact glass capsule via the PR1 kit (zone dot + bpm + zone) — unchanged.
- Per-template caps reconciled so each design's focused spawn set fully shows; `hiddenCount` (distinct
  metrics) drives a `+N · enlarge` hint in the builder.

## Output

The three render files + per-template caps + the `+N` editor hint, plus extended `HRTileLayoutTests`.

## Acceptance criteria

- [x] All 7 templates render premium + crop-proof; each spawn set fully shows at its default size.
- [x] Preview == export for the gauge sweep, zone bar (incl. vertical Z5-on-top ordering), accent bar,
      gradient skin (horizontal → flip-safe), and the new field/stat layouts.
- [x] Zone Ring no longer double-renders %HRR; `hiddenCount` counts distinct metrics.
- [x] App type-checks (Swift 6, 0 new warnings); full `SnappetTests` + the studio walkthrough UITest green.
- [x] `decisions.md` + the knowledge graph updated.

## Constraints

- On-device only; the burned-in `.mp4` (incl. the gauge sweep direction + zone-bar Y-flip) is the
  manual device-burn-in checklist item.
- Keep `HRTileLayout` platform-free + scale-invariant; the 11pt floor stays out of fit/visibility gates.

## Test plan

1. `xcodebuild build` + `xcodebuild test -only-testing:SnappetTests` on iPhone 17 Pro.
2. Studio walkthrough XCUITest green.
3. Adversarial multi-agent review of the diff (WYSIWYG / Y-flip / scale-crop / logic).
4. Device burn-in: each template's exported clip matches the editor.
