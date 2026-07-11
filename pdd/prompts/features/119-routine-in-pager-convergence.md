# Prompt: Play saved routines through the Quick-Session pager (one player, one source of truth)

**File**: pdd/prompts/features/119-routine-in-pager-convergence.md
**Created**: 2026-07-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Workout-tracker convergence (follows the Quick Session pager, prompt 109)
**Source**: User request — "when I play a previously-saved routine it should play like Quick Session, and stay expandable."
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

A saved routine used to open the guided set-by-set `WorkoutPlayerView` (a fixed index-walk with
full-screen Rest/Done phases), while a routineless session opened the glass **pager**
(`FreeformPlayerView` — swipe between exercises, ± steppers, inline history, add-on-the-fly). Two
players, two feels. This routes **every** session — routine and freeform — through the one pager, so a
saved routine plays like Quick Session and stays expandable (extra sets, add exercise, history drawer),
rendered and logged through a single code path (single source of truth).

## Context the implementer needs

Both players already read/write the same model (`WorkoutSession → [SessionExercise] → [SetLog]`,
`WorkoutModels.swift`) and the pager's logic (`QuickSessionPager.swift`) is pure and model-driven with
no `routineID`/freeform branch — so the substrate is already shared. Three concepts diverged and would
silently re-introduce a fork if left alone:

1. **Two "planned-sets" fields.** `targetSets` (routine prescription) vs `plannedSets` (pager's
   per-session intent). `QuickSessionPager.planState` read only `plannedSets`.
2. **Pre-seeded empty sets.** `RoutineSessionBuilder.emptySets` filled N blank `SetLog`s (the guided
   player walked them by index); the pager treats `sets` as *logged* sets, so blanks leaked into the
   ghost ledger.
3. **Prescribed rest ignored.** The pager armed rest from remembered/suggested defaults, never the
   routine's `targetRestSeconds`.

## Approach

- **Pure logic (unit-tested):**
  - `QuickSessionPager.plannedCount(for:) = plannedSets ?? (targetSets>0 ? targetSets : nil)`; route
    `planState` and `isUnfinished` through it.
  - `RestTimerDefaults.remembered(for:in:prescribed:)` — stored → prescribed → suggested, clamped.
  - `RoutineSessionBuilder` builds session exercises with `sets: []` (grow-as-you-go); drop `emptySets`.
- **Views:** `WorkoutTrackerModule` always presents `FreeformPlayerView` (delete the `routineID == nil`
  fork). In `FreeformPlayerView`, seed the plan editor from `plannedCount`, seed the first rest from
  `targetRestSeconds`, and land on the first **unfinished** exercise (mirror `resumePosition`). The
  Live-Activity "Set 1 of N" label reads `plannedCount` (not `sets.count`).
- **Delete** the guided `WorkoutPlayerView.swift` (now dead) and stale references to it.

## Output

- Edited: `QuickSessionPager.swift`, `RestTimerDefaults.swift`, `RoutineSessionBuilder.swift`,
  `WorkoutTrackerModule.swift`, `FreeformPlayerView.swift` (+ two comment fixes in `Haptics.swift` /
  `LiveMetricsPanel.swift`).
- Deleted: `WorkoutPlayerView.swift`.
- Tests: `QuickSessionPagerTests`, `RestTimerDefaultsTests`, `RoutineSessionBuilderTests` (new SSOT
  cases); routine UITests (`WorkoutWalkthroughTests`, `WorkoutPauseBackgroundTests`,
  `LiveWorkoutStudioWalkthroughTests`) repointed to the pager's log/finish flow.
- Docs: `docs/knowledge-graph/data.js` (retire `wt-player`, fold its edges into `wt-freeform-player`),
  `pdd/context/decisions.md`.

## Acceptance criteria

- [ ] Starting a saved routine opens the pager, its exercises on the rail with plan counts from
  `targetSets`, steppers seeded from `targetReps`/`targetWeight`, and the first rest = `targetRestSeconds`.
- [ ] The routine is expandable: "1 extra set" beyond the plan, add off-plan exercises, History › drawer.
- [ ] No blank ghost-ledger chips (sessions start with no pre-seeded sets).
- [ ] Landing page is the first unfinished exercise (routine opens on exercise 1, not the last).
- [ ] `WorkoutPlayerView` is gone; no references remain (except intentional "retired" comments).
- [ ] App changes type-check (Swift 6, 0 warnings); new/edited unit tests pass.
- [ ] `decisions.md` + the knowledge graph updated.

## Constraints

- On-device only; no backend. Keep the HR selector pluggable (unchanged).
- The guided player is **removed**, not hidden behind a toggle (user-approved; matches "cleanup dead code").

## Test plan

1. Unit gate: `make ios-test SIMULATOR='iPhone 17 Pro'` — new `plannedCount`/`isUnfinished`/prescribed-rest
   and `sets == []` builder cases pass; engine `swift test` sanity.
2. Build: `make ios-sim SIMULATOR='iPhone 17 Pro'`.
3. Device (MrRobot): start a saved routine → pager opens, targets/plan/rest seeded, expandable, Finish →
   summary. (Runtime leg; user to confirm.)
