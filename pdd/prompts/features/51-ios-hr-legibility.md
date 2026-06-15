# Prompt: iOS — share the polished HR chart/zone bar with the Kilter summary; teach the HRV/recovery colours

**File**: pdd/prompts/features/51-ios-hr-legibility.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI / Swift Charts) — code lands in this repo.
**Chain**: 2026-06-09 product review → iOS tracker [#100](https://github.com/harshal2802/Snappet/issues/100), Wave 3.
**Source**: GitHub issue [#78](https://github.com/harshal2802/Snappet/issues/78)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The same HR data shipped at two quality levels: WorkoutTracker's session detail had a smoothed,
zone-coloured, animated, axis-labelled chart + animated zone bar, while the Kilter board-session
summary — what a climber sees after every session — plotted the raw series as a hardcoded pink line
with a hidden axis. And the HRV badge ("42 ms HRV") and recovery dot ("−18 bpm rec.") never explained
their red/orange/green or that they're within-session heuristics. Unify the chart and make the colour
codes legible.

## Context the implementer needs

- Both surfaces already share the data types: `WorkoutHRStats` and `HRPoint` (`KilterSession.hrSeries`
  is `[HRPoint]`, same as `WorkoutSession`), so the extraction needs no adapter.
- `Features/WorkoutTracker/SessionDetailView.swift` held the good components as **private** structs
  `HeartRateChart` (engine resample/smooth, zone colour, Reduce-Motion-gated draw-in, labelled axes)
  and `ZoneBar` (grow-in + per-zone legend).
- `Features/Kilter/KilterSessionDetailView.swift` had a raw `.pink` `LineMark` with `.chartXAxis(.hidden)`
  and its own hand-rolled `zoneBar`/`redlineMinutesLabel`.
- `HRVBadge`/`HREffortBadge` are already shared components whose `recoveryColor(_:)` thresholds are the
  canonical colour codes (HRV: <20 red / <40 orange / ≥40 green; recovery drop: <10 / <25 / ≥25).

## Approach

1. Move `HeartRateChart` + `ZoneBar` into a shared app-target file `Features/WorkoutTracker/HeartRateComponents.swift`
   (internal, not private; `HighlightEngine` stays platform-free — the resample/smooth is reused). Both
   session-detail views render them; the Kilter raw chart + private zone bar + redline label are deleted.
2. Add `HRMetricsInfoButton` (an ⓘ → popover) to the same file: it explains the HRV and recovery-dot
   colour codes with the within-session-heuristic caveat, drawing its swatch colours **from the badge
   `recoveryColor` functions** so the legend can't drift from the badges. Render it in each summary's
   Heart-rate header — one legend per screen covers all the per-set/per-climb badge instances.

## Output

- `Features/WorkoutTracker/HeartRateComponents.swift` (new) — `HeartRateChart`, `ZoneBar`, `HRMetricsInfoButton`.
- `Features/WorkoutTracker/SessionDetailView.swift` — private structs removed; header gains the info button; unused `import Charts` dropped.
- `Features/Kilter/KilterSessionDetailView.swift` — shared chart/zone bar; private chart/zoneBar/redlineMinutesLabel removed; header gains the info button.
- `pdd/context/decisions.md` + `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [ ] Kilter session summary renders the same smoothed, zone-coloured, animated chart and zone bar as WorkoutTracker.
- [ ] HRV and recovery-dot colours are explained in-UI at both call sites, including the heuristic caveat.
- [ ] No duplicated chart code remains between the two session-detail views.

## Constraints

- On-device only; `HighlightEngine` stays platform-free.
- The legend's swatch colours derive from the badge thresholds (single source of truth).

## Test plan

`xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,id=…iPhone 17 Pro…'` — the suite
(incl. the studio/workout walkthroughs that touch the session detail) stays green. By eye on the sim:
the Kilter summary chart now has labelled axes + zone-bar legend; the ⓘ popover renders on both summaries.
