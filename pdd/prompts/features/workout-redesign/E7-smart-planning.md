# Prompt: E7 — Smart workout planning (heuristic + on-device Apple Intelligence)

**File**: pdd/prompts/features/workout-redesign/E7-smart-planning.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-redesign/PLAN.md` → E7 (wave 3; depends on E4 — the plan emits a `[RoutineExercise]`)
**Source**: GitHub issue [#187](https://github.com/harshal2802/Snappet/issues/187) · Part of epic #179
**Design**: `docs/ux-research/workout-redesign/README.md` §1 (locked planner decision), §4 "Smart workout
planning", §9 (AI is a sharpener, never required; on-device-only, no server LLM); `research-appendix.md` §5
(Fitbod recovery / Whoop strain-target / "draft you accept-swap-tweak" / explainable); `wireframes.html` Flow 6
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-06-19 E7 entry)

## Goal

A pure, deterministic **`WorkoutRecommender`** (modelled 1:1 on `KilterRecommender`) fed by a new pure
per-muscle signal in **`WorkoutHistoryStats`** + optional recovery → a **"Today"** verb card
(REST/EASY/TRAIN/PUSH on the Pulse Pro performance ramp + a plain-language *why*) + an **editable
suggested-session draft** (strategy + constraint chips that re-generate; per-row swap / ±set / remove) →
"Start this session" or "Save as routine". Plus an **optional on-device Apple-Intelligence (Foundation
Models) sharpener** for natural-language tweaks ("15 min, no barbell"), behind a clean seam that is
availability-gated and **degrades silently to the always-on heuristic**. On-device only — no network, no
server LLM (the hard constraint).

## Context the implementer needs

- THE TEMPLATE: `KilterRecommender` (pure Strategy → StrategyConfig → Options → allocation → `recommend`,
  deterministic with stable tie-breaks + a `rerollSeed` re-roll) + `KilterPlanLogic` (the freeze-on-Start
  persisted plan) + `KilterPlanView` (the I/O edge: `@Query` → value types → the pure recommender).
- E0 shipped `WorkoutHistoryStats` as a per-discipline recency/cadence seam "with no callers yet". E7
  EXTENDS it with per-**muscle** weekly volume + last-trained recency, joining `Exercise.primaryMuscles` via
  the `@MainActor ExerciseResolver` **at the I/O edge** (the resolved value snapshots flow into the pure
  `make(history:resolved:)`; the recommender/stats never touch SwiftData or the resolver).
- E4 made `RoutineExercise` discipline-aware + shipped `RoutineSessionBuilder` (the pure routine→session
  mapping) and `RoutineSessionBuilder.sessionExercise(from:)`. The planner emits `[RoutineExercise]`, started
  as a freeform session via that builder, or handed to a pre-filled `RoutineEditorView`.
- `FoundationModels` ships in the iOS 26 SDK; the deployment target is iOS 18. So the framework is imported
  behind `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)` + a runtime
  `SystemLanguageModel.default.isAvailable` gate — it weak-links + activates only on a capable iOS 26 device,
  and the build/`#else` paths return the heuristic. Verified: the `@Generable` schema compiles in this SDK.

## Approach

1. **`WorkoutRecommender`** (NEW, pure) — `Goal` = warmUp/main/accessory/finisher; `Candidate` = a value
   snapshot of an `Exercise` (id/name/primaryMuscles/equipment/isCompound/isBodyweight); `Strategy` =
   balanced/hypertrophy/strength/recovery/timeCapped → `StrategyConfig` (count + `Mix` + a rep/rest `Scheme`).
   `recommend(candidates:signal:options:)` applies the equipment constraints, computes `focusMuscles`
   (least-recently-trained, tie-broke by lowest recent volume), ranks each goal's pool toward the freshest
   focus muscle (mains prefer compounds), and fills the allocation deterministically with the same
   largest-remainder `Mix` math + `rerollSeed` rotation as Kilter.
2. **`WorkoutHistoryStats`** gains `daysSinceByMuscle` / `lastTrainedByMuscle` / `weeklyVolumeByMuscle` +
   `make(history:resolved:)` consuming `ResolvedSession`/`ResolvedSet` value snapshots (muscles joined at the
   edge). The old `make(history:)` stays for existing callers (muscle maps empty).
3. **`WorkoutPlanLogic`** (NEW, pure) — the "Today" verb (cadence-relative readiness + an optional recovery
   sharpener that nudges the verb one step) + the `Plan → [RoutineExercise]` bridge + a default routine name.
4. **`WorkoutPlanTweak` + `WorkoutPlanTweakParser`** (NEW, pure) — a natural-language tweak as a structured
   `Options`+strategy delta; the always-on keyword/number heuristic parser. `apply(to:)` is the single place
   a tweak becomes recommender inputs (shared by both paths so they can't diverge).
5. **`WorkoutPlanIntelligence`** (NEW, Services edge) — the optional on-device Foundation Models sharpener:
   `resolve(phrase:)` computes the heuristic floor, then (when available) asks the system model to emit a
   `@Generable PlanTweakSchema` it maps to the SAME `WorkoutPlanTweak`. The model only structures the
   *inputs*; the pure recommender still builds the plan (explainable). Any failure/timeout/unavailability →
   the heuristic. The ONLY place `FoundationModels` is imported.
6. **`WorkoutPlanView`** (NEW, I/O edge) — joins history + the resolver into the value types, shows the Today
   card, strategy/constraint chips that re-generate, the AI tweak field, the editable draft
   (swap/±/remove), and Start / Save-as-routine. Wired from a dashboard "Plan a session" entry +
   `TodayDigest.workoutPlan` (the Home card, sibling to `climbPlan`).

## Constraints / invariants

- The recommender + history stats + plan logic + tweak parser stay **pure value types** (Foundation only),
  unit-tested in `SnappetTests` with no device. `HighlightEngine` stays platform-free.
- Apple Intelligence is a **sharpener, never required**: the heuristic is the always-on path; the FM pass is
  gated + degrades silently. **On-device only — no network, no server LLM.**
- The suggestion is an **editable draft**, never forced (the locked decision).
- `RoutineExercise`s the planner emits are strength blocks (`disciplineRaw == nil` — the additive-nil
  invariant); v1 plans strength sessions (the discipline-mixed plan is a later tier).

## Tested by

- unit: `WorkoutRecommenderTests` (determinism, allocation sums, muscle-focus bias, strategy schemes,
  equipment constraints, re-roll determinism); `WorkoutHistoryStatsTests` (per-muscle recency/volume window);
  `WorkoutPlanLogicTests` (verb thresholds, recovery nudge, Plan→routine bridge); `WorkoutPlanTweakTests`
  (heuristic parse + the degrade-to-heuristic seam, FM call SDK/device-gated).
- UITest: `WorkoutPlanFlowTests` (open the planner → tweak chip re-generates → Save as routine) if feasible.
- The FoundationModels seam is proven to degrade cleanly: with the model unavailable (the sim), `resolve`
  returns `.heuristic` and the heuristic tweak.

## Not in scope (deferred)

- Discipline-mixed plans (a climb/run/timed block in the suggestion) — v1 plans strength; the bridge already
  emits `[RoutineExercise]` so a later tier can widen it.
- The streaming / multi-turn FM conversation; a real device burn-in of the FM path (sim has no model).
- Android (its own wave).
