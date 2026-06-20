# Prompt: P3 — Climbing analytics dashboard

**File**: pdd/prompts/features/kilter-improvement/P3-analytics-dashboard.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI + Swift Charts).
**Chain**: PLAN.md → P3 (depends on P0; sequence **before** P4 — both touch `KilterHistoryView`)
**Source**: GitHub issue — Kilter Improvement P3
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Design**: `docs/ux-research/kilter-improvement/README.md` §4 (Flow 3) · wireframes `03_dashboard`, `03b_trend`

## Goal

Give Kilter a real climbing analytics dashboard built on the P0 aggregator: a tiered Pulse Pro screen — one
hero (Climbing Level) → the signature segmented grade pyramid → send/flash rings → trends → angle
distribution → a kindly consistency surface. Delete the untested hand-rolled aggregation in History.

## Context the implementer needs

- P0 shipped `KilterAllTimeStats` (pure, tested) + segmented `GradeCount`. This phase is **UI only over
  tested aggregates** — add no new math in the view; any new pure helper (range bucketing, recap
  composition) goes to `SnappetTests`.
- Reusable charts: `ClimbGradePyramid` / `ClimbEffortSection` / `ClimbTimelineList`
  (`FreeformClimbSummaryComponents.swift:31-110`); `WorkoutDashboardSection.volumeChart` BarMark +
  grow-on-appear (`WorkoutDashboardSection.swift:207`); `WorkoutHRStats` + `HeartRateChart` + `ZoneBar`
  (`WorkoutHRStats.swift:11`).
- Climbing-Level seed: `KilterRecommender.workingDifficulty` (`KilterRecommender.swift:147-155`), windowed.
- `KilterHistoryView.swift:59-78` holds the inline summary strip + CSS-bar pyramid to **remove**.
- Pulse Pro primitives: `DisciplineHero` / `StatRibbon` / `pulseGlassChrome` (`PulsePro.swift:12-112`),
  `SnappetColor.kilter` (wayfinding) + perf ramp (effort). Pyramid must encode order by position+label and
  style by Wong/Okabe-Ito + pattern + label (design rule 6 / research-appendix §3).

## Approach

- Add `KilterStatsView` on a new `KilterStatsRoute` (shared path; reachable from the Kilter root, optional
  Home tile). Tier-1: hero Climbing Level + perf-ramp delta; doorway tiles (headline + sparkline, `.chev`).
- Promote the grade pyramid to a Swift Charts `BarMark` via `ClimbGradePyramid` — segment flash/send/project,
  dashed current-max marker, **tap a grade → filter the ascent log**.
- Tiles drilling into tier-2 trend screens: send/flash rings; intensity-zone bar (relative to personal max);
  volume / sends-per-week trend (clone `volumeChart`) with 30d/3m/1y/all range chips + vs-previous ghost;
  max-grade progression step-line; attempts-to-send velocity; angle distribution; consistency strip; HR
  trend when band data exists. A low-cost "Month in Send" shareable recap from the same aggregator.
- **Delete** the inline History aggregation (`KilterHistoryView.swift:59-78`) and link History → this
  dashboard. Coordinate the History edit with P4 (which regroups the same file) to avoid a merge collision.

## Output

- `KilterStatsView.swift` + tier-2 trend detail screens + route registration.
- Any new pure helper (range bucketing / recap composition) + its `SnappetTests`.
- `KilterHistoryView` inline math removed + a link to the dashboard.
- `docs/knowledge-graph/data.js` dashboard + trend nodes/edges. XCUITest for the dashboard.

## Acceptance criteria

- [ ] Dashboard renders hero Climbing Level + delta, the segmented tappable grade pyramid (with max marker),
      send/flash rings, volume trend with range chips + vs-previous ghost, max-grade step-line, velocity,
      angle distribution, and a consistency surface — all from `KilterAllTimeStats`.
- [ ] Tapping a grade filters the ascent log; tapping a tile opens its full trend screen.
- [ ] `KilterHistoryView` inline summary/pyramid math is deleted; History links to the dashboard; its
      remaining sections don't regress.
- [ ] One hero numeral; amber = wayfinding only; perf ramp = pyramid/delta/rings/zones only; pyramid passes
      colorblind encoding (position+label + Wong palette + pattern). App type-checks (Swift 6, 0 warnings).
- [ ] Any new pure helper unit-tested; `decisions.md` updated.

## Constraints

- On-device only; Kilter-board data only. No new math in views (consume P0). No new `@Model`.
- Recompute from rows; cache only if a real history shows lag (note, don't build the cache here).

## Test plan

1. Unit: new helpers green; build-for-testing.
2. XCUITest: open Stats → pyramid renders + tap-to-filter → tile → trend screen with range chips. Verify
   History still loads after the inline-math deletion. Sim wedge → `xcrun simctl shutdown all`.
