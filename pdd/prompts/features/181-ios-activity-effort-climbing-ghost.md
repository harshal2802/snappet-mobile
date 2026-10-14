# Prompt: Activity progress P4 — effort, climbing overview, ghost compare

**File**: pdd/prompts/features/181-ios-activity-effort-climbing-ghost.md
**Created**: 2026-10-13
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: activity-progress ideation (`docs/ux-research/activity-progress/ideation.html`, §05 screens D–E, §06 "Effort",
§07 decision 1 = both levels, §08 P4); builds on prompts 178–180
**Context**: `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Finish the activity-progress chain: the HR insight only Snappet can show (the same work costing fewer beats), a
climbing overview with every named climb drillable into its own page, and an opt-in ghost overlay for Then vs Now.

## Approach

- `ActivityKey.discipline(_:)` + `matches(_:)`: one key spans a whole discipline; the index and dashboard use
  `matches` instead of `==`. Climbs are identified by name whenever they have one (library climbs share ids like
  `climb.boulder`).
- Pure `ActivityInsights.effort`: per-set peak HR via `WorkoutHRStats.setEfforts`; strength compares the load done
  in the most sessions (≥ 2) — "fitter" only for that like-for-like case and a ≥ 3 bpm drop; otherwise neutral.
- Pure `ActivityInsights.climbs`: named climbs with sessions, attempts, sent, clips, latest grade.
- Dashboard: Effort card (Swift Charts), Climbs card (climbing overview), "All climbing" link from a climb's page,
  climb filmstrip labelled by outcome, hardest-send KPI reads "▲ from V3" (grades are ranks, not percentages).
- Library adaptive items (climb / run / timed) get "View progress" → the discipline dashboard.
- `ActivityCompareView` Ghost: "then" at 40 % over "now".

## Acceptance criteria

- [x] `ActivityInsightsTests` (discipline keys, climb identity, like-for-like effort, neutral fallback, climbs list).
- [x] UI tests: effort card + ghost toggle; climb dashboard → all climbing → climbs list → a climb.
- [ ] Device: effort trend with real watch HR; ghost overlay usefulness with a fixed camera.
- [ ] PRE-EXISTING (reproduced on `main` 2026-10-13 with a probe UI test): tapping a climb item in the Library
      doesn't open its detail in the simulator, so the new "View progress" row there is unreachable until that's
      fixed. The UI test reaches the climbing overview from session detail instead. Separate fix.
