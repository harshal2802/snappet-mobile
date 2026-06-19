# Prompt: E2 — Session detail redesign (type-adaptive recap, parity with Finish)

**File**: pdd/prompts/features/workout-redesign/E2-session-detail-redesign.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-redesign/PLAN.md` → E2 (wave 1; depends on E0)
**Design**: `docs/ux-research/workout-redesign/README.md` §4 (Session detail); `wireframes.html` Flow 2
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`

## Goal

Make the completed-session detail a **creative, type-adaptive recap** that improves visibility of the workout
+ stats. Today `SessionDetailView` is a flat `List` of `LabeledContent` rows, identical for every discipline,
and **strictly poorer** than the `FreeformDoneSummaryView` recap the user just saw — tapping "View detail"
*loses* information. Unify both on the shared `SessionRecap` scaffold from E0.

## Context the implementer needs

- `Features/WorkoutTracker/SessionDetailView.swift` (899 lines): summary stats (`:60-70`, flat, discipline-
  blind), the HR section (`HeartRateSummarySection :183-270`, gated on a real `hrSeries`), and the unified
  media + per-set breakdown (`SessionMediaSection :284-713`). It serves **both** freeform and guided-routine
  sessions (`WorkoutTrackerModule.swift:132-139`); routine sessions derive `.strength` — degrade cleanly.
- **Two drifting `kind` switches** drive set rendering: `SetTileRow.detailText` branches `discipline==.run`
  then `switch kind`, and **re-implements** the reps×weight formatting inline (`:789-801`) — which carries a
  kg conversion `SetMeasure.summary` does NOT (`:776-781`). Consolidate onto `SetMeasure` **with a
  unit-preserving path + a legacy-row regression test** (don't silently change how old lifting rows render).
- Edit mode is reps/weight-only (`SessionSetEditing.swift:30-31`); the Edit button doesn't even appear for a
  pure climb/timed/run session (`:102`).
- **SwiftData presentation fragility:** the Studio `fullScreenCover` + media sheet MUST stay hosted on the
  parent `List` (documented `:298-303`, `:123-130`); a card redesign that re-nests sections can reintroduce
  the "cover collapses on first open" bug — preserve the single `activeSheet` enum + parent-hosted state.
- Reuse: E0's `SessionRecap`/`DisciplineHero`/`StatRibbon`; `FreeformSummary.dominant/.stats`;
  `FreeformClimbStats→ClimbGradePyramid`/`ClimbTimelineList`; `StrengthStats` e1RM; `RunStats`;
  `WorkoutHRStats`+`ZoneBar`+`HeartRateChart`; `SetMediaStrip`; `CelebrationBurst` (PR only).

## Approach

Re-skin `SessionDetailView` onto `SessionRecap`: **hero** = the type-chosen metric (climb hardest send /
strength volume / run distance·pace / timed TUT) via `DisciplineHero`; **secondary viz** = climb grade
pyramid + intensity band / strength per-exercise volume minibars / run+timed time-in-zone `ZoneBar`;
**breakdown** = expandable per-exercise/per-climb cards with prior value in gray + a coral PR pill (e1RM /
first-send / longest hold / fastest split). Route **every** set row through `SetMeasure` (kill the inline
copy, preserving unit conversion). Extend `SessionSetEditing` to all axes so Edit appears for every
discipline. Keep media + HR + the cover-hosting exactly where they are.

## Output

- A rebuilt `SessionDetailView` body on `SessionRecap` (hero/viz/breakdown), discipline-skinned (degrades to
  `.strength` for routine sessions).
- `SetMeasure` consolidation (one set-row grammar, unit-preserving) + legacy-row regression test.
- `SessionSetEditing` extended to duration/distance/climb-grade/RPE axes (+ tests).
- A per-exercise rollup header (e1RM / sends / distance·pace / TUT) reusing the pure stats types.

## Acceptance criteria

- [ ] A climbing session detail shows a grade pyramid + send hero; a strength one shows volume + e1RM PR
      pills; both via the SAME scaffold (parity with `FreeformDoneSummaryView`).
- [ ] All set rows render through `SetMeasure`; a legacy reps×weight row renders byte-identically (regression test).
- [ ] Edit appears + works for every discipline (duration/distance/climb persist + round-trip).
- [ ] The Studio cover + media sheet still open from a clip without collapsing (the `:298-303` hazard not regressed).
- [ ] App type-checks (Swift 6, 0 warnings); UI suite + the workout walkthrough green.

## Constraints

- On-device only. Preserve the SwiftData cover-hosting workarounds; don't introduce a per-entity history `@Model` (deferred).
- Degrade honestly: routine (no-discipline) sessions render the strength skin; HR viz only when a real `hrSeries` exists.

## Test plan

1. `SnappetTests`: `SetMeasure` consolidation (incl. legacy unit conversion), `SessionSetEditing` per axis, the rollup selectors.
2. UITest: open a climb session + a strength session from History → correct hero/viz; edit a set per discipline; tap a clip → Studio.
3. Eyeball Flow 2 (climbing + strength variants) against the build.
