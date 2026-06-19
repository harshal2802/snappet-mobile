# Prompt: E5 — Save a Quick Session as a repeatable routine

**File**: pdd/prompts/features/workout-redesign/E5-save-as-routine.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-redesign/PLAN.md` → E5 (wave 3; depends on E4 — the keystone routine model)
**Source**: GitHub issue [#185](https://github.com/harshal2802/Snappet/issues/185) · Part of epic #179
**Design**: `docs/ux-research/workout-redesign/README.md` §4 "Save Quick Session → routine" (Flow 7), §5 (the
`RoutineExercise` keystone), §9/§10 Q3 (actuals→prescription is lossy + user-reviewable); `wireframes.html` Flow 7
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-06-19 E5 entry)

## Goal

Close the **runtime → template** loop: let a finished freeform Quick Session be saved as a repeatable
routine. The freeform side already proved the rich two-axis model and E4 made `RoutineExercise`
discipline-aware; E5 writes the **inverse of `RoutineSessionBuilder`** (session actuals → a per-discipline
routine prescription) and surfaces a **"Save as routine"** affordance on the completion summary that
pre-fills the routine editor for review — so a climb/timed/run session becomes a *typed* routine, not a
degraded strength slot, and the user trims warm-ups / renames before anything is inserted.

## Context the implementer needs

- `RoutineSessionBuilder` (E4) is the pure forward map `routine → session`. E5 is its inverse — keep the
  per-discipline `switch` symmetric so a freeform → routine → freeform round-trip preserves discipline.
- `FreeformDoneSummaryView.actionBar` is the seam: Done (coral, the finish CTA) / View detail / Discard.
  Add "Save as routine" alongside — but the screen's one *brand-coral* moment is the save-as-routine CTA
  per the two-axis color contract (Done stays `SnappetColor.workout`).
- `RoutineEditorView` already has the new-routine INSERT path (`routine == nil` → `context.insert` + log).
  Reuse it: add an optional `prefill` so the same Save path inserts a brand-new `Routine` from reviewed
  state. Never silently insert.
- A session is a record; a routine is a plan — the conversion is **lossy** and makes judgement calls
  (which weight? how many sets?). Make every call defensible + user-overridable in the editor.

## Approach

1. **`SessionToRoutine`** (NEW, pure, device-free) — `routineExercises(from: WorkoutSession) -> [RoutineExercise]`,
   one block per `SessionExercise` with ≥ 1 *completed* set (an exercise with nothing logged is dropped).
   Per discipline:
   - **strength** → completed-set count × **modal** completed reps × the **top (weight×reps)** set's weight
     in its own unit; `disciplineRaw` stays nil (the additive-nil strength default).
   - **climb** → the climb is the slot: type + grade + scale; `sets` = the logged attempt count.
   - **timed** → the `TimedExerciseSpec` + category carried through verbatim; a structured protocol keeps its
     own set count + no extra target, a simple hold uses the completed-set count + a **median** hold target.
   - **run** → a single block targeting Σ completed distance (pace derived, never prescribed).
   - **dance / other** → a duration-based block with a median active-duration target.
   Plus `suggestedName` (the session's name unless generic → a dominant-discipline label), `suggestedSport`,
   `canConvert`, and a `RoutineDraft` value (the reviewable output, before any store write). Unit-tested.
2. **"Save as routine"** on `FreeformDoneSummaryView.actionBar` — a coral (`SnappetColor.brand`) affordance
   (`freeform.saveAsRoutine`), shown only when `SessionToRoutine.canConvert(session)`. Builds the draft and
   presents the editor.
3. **Pre-fill `RoutineEditorView`** — an optional `prefill: RoutineDraft?` (used when `routine == nil`) seeds
   the local state for review; Save takes the existing new-routine INSERT path (fresh UUID). The user trims/
   renames/adjusts targets first.
4. The saved routine appears in Routines and starts through E4's `makeSession` (round-trip preserved).

## Output

- `SessionToRoutine.swift` (NEW, pure: the converter + `RoutineDraft` + name/sport/canConvert helpers).
- `FreeformDoneSummaryView.swift` (the coral "Save as routine" action + the pre-filled editor sheet).
- `RoutineEditorView.swift` (the additive `prefill` parameter + `loadExisting` seeding; Save reuses INSERT).
- `SnappetTests/SessionToRoutineTests.swift` (per-discipline rules + the `RoutineSessionBuilder` round-trip).
- `SnappetUITests/FreeformFlowWalkthroughTests.swift` (`testSaveQuickSessionAsRoutine`).
- Graph (`docs/knowledge-graph/data.js`) + `pdd/context/decisions.md` updated.

## Acceptance criteria

- [x] A pure `SessionToRoutine.routineExercises(from:)` emits a `RoutineExercise` per completed-discipline
      exercise; an exercise with no completed set is dropped; unit-tested per discipline.
- [x] A climb / timed / run session saves as a real TYPED routine (not a degraded strength slot) — proven by
      a freeform → routine → freeform round-trip through `RoutineSessionBuilder` that preserves discipline.
- [x] The converter is the deliberate inverse of E4's `RoutineSessionBuilder` (symmetric per-discipline map).
- [x] "Save as routine" (coral, `freeform.saveAsRoutine`) is on the completion summary, gated on a completed
      set; it opens the editor PRE-FILLED (never silently inserts).
- [x] The editor's Save inserts a brand-new `Routine` (fresh UUID) from the reviewed state; the saved routine
      appears in Routines and can be started.
- [x] App type-checks against the iOS SDK; `HighlightEngine` untouched; the pure converter has no
      SwiftUI/SwiftData/HealthKit imports.

## Constraints

- iOS only — the Android mirror is deferred to wave H (tracked).
- `SessionToRoutine` stays pure (Foundation only) + unit-tested; the UI/SwiftData edge just wraps it.
- No new `@Model` (the draft is a value type; the editor inserts the existing `Routine`).

## Test plan

1. `xcodebuild build-for-testing` (iPhone 17 Pro Max) → SUCCEEDED.
2. `SessionToRoutineTests` + `RoutineSessionBuilderTests` + `FreeformSummaryTests` +
   `RoutineExerciseMigrationTests` → 0 failures.
3. `FreeformFlowWalkthroughTests/testSaveQuickSessionAsRoutine` (Quick Start → log → Finish → Save as routine
   → review → Save → routine appears in Routines) → green.
