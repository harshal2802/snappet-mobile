# Prompt: P0 — Kilter all-time stats engine (keystone)

**File**: pdd/prompts/features/kilter-improvement/P0-all-time-stats-engine.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift) — pure value type, code lands in this repo.
**Chain**: PLAN.md → P0 (no dependencies; spine of P3 + P4)
**Source**: GitHub issue — Kilter Improvement P0
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Lift the pure per-session engine `KilterSessionStats.make` into a new pure, unit-tested **all-time
aggregator** `KilterAllTimeStats` that aggregates the full climbing log into the numbers three later phases
need (dashboard P3, history roll-ups + adaptive card facts P4). This is the keystone: it lets P3/P4 consume
tested aggregates instead of re-deriving math in the view, and it lets P3 **delete** the untested inline
aggregation currently embedded in `KilterHistoryView.swift:59-78`. No UI, no schema change.

## Context the implementer needs

- `KilterSessionStats` (`KilterSessionStats.swift:34`) is a pure value type with a `.make([KilterClimbLog], …)`
  factory (`:105`) and a plain-value bridge `KilterClimbLog.from` (`:200`); it is unit-tested in
  `KilterSessionStatsTests` with **no** SwiftData/device dependency. Mirror this shape exactly.
- The persisted ascent rows are `KilterLogEntry` (`@Model`, `KilterModels.swift`); callers read them via
  `@Query`. The aggregator must operate on plain values (`[KilterClimbLog]`) so it stays device-free.
- Today the only all-time math is hand-rolled inline in `KilterHistoryView.swift:59-78` (total sends /
  this-month / hardest + a CSS-bar pyramid) — untested. P0 produces the replacement; P3 deletes the inline.
- `GradeCount` (in `FreeformClimbSummaryComponents.swift:31`, used by `ClimbGradePyramid`) currently lacks
  per-style breakdown; the segmented pyramid needs attempt/project counts per grade.
- **Kilter-board only** (decision): aggregate `KilterLogEntry` / created climbs — do **not** fold in
  Quick-Session freeform climbing.

## Approach

- Add `KilterAllTimeStats` (a pure `struct`, new file under `Features/Kilter/`) built from `[KilterClimbLog]`
  via `KilterClimbLog.from`. Compute: total sends, send rate, flash rate, attempts-to-send velocity,
  max-grade (Climbing Level seed window), max-grade progression series, sends-per-week volume buckets,
  angle distribution (sends/attempts per angle), and per-period roll-ups (`(period) → {sessions, sends,
  hardest}`) for month/week buckets.
- Extend `GradeCount` with `attempt`/`project` counts (additive) so `ClimbGradePyramid` can segment by style
  (flash | send | project) — keep the existing fields/behavior intact.
- Formalize the ascent-style color vocabulary (flash/send/project/attempt) as **derived helpers** over the
  existing perf ramp + Wong/Okabe-Ito nominal palette — **no new `SnappetColor` brand tokens**, always
  paired with glyph+label (design rule 3/6).
- Keep everything a value type with no `@Model`/SwiftData/UIKit dependency. No views.

## Output

- `KilterAllTimeStats.swift` — the pure aggregator + period roll-up helpers.
- Additive `attempt`/`project` on `GradeCount` (in its existing file) + any small segmentation helper.
- An ascent-style color/glyph helper (small, pure) for reuse by P3/P4/P5.
- `KilterAllTimeStatsTests.swift` in `SnappetTests`.

## Acceptance criteria

- [ ] `KilterAllTimeStats` computes send/flash rate, attempts-to-send, max-grade trend, weekly-volume
      buckets, angle distribution, and month/week roll-ups from `[KilterClimbLog]`.
- [ ] `GradeCount` gains attempt/project counts additively; existing `ClimbGradePyramid` callers compile
      unchanged.
- [ ] `KilterAllTimeStatsTests` cover: empty history, single session, multi-session, send/flash rate,
      attempts-to-send, max-grade trend, weekly buckets, angle distribution, roll-ups. `swift`/XCTest green.
- [ ] Existing `KilterSessionStatsTests` stay green.
- [ ] No new `@Model`, no schema change, no `SnappetColor` brand token added.
- [ ] No platform imports in the engine (pure value type). `decisions.md` updated.

## Constraints

- On-device only; pure value type; Kilter-board data only (no Quick-Session fold-in).
- Recompute from rows — no denormalized persistence in P0 (defer caching unless a real history lags).

## Test plan

1. `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (or build the
   `SnappetTests` target) — `KilterAllTimeStatsTests` + `KilterSessionStatsTests` green.
2. Sanity: feed a known fixture log and assert the pyramid segmentation + roll-up strings by eye.
