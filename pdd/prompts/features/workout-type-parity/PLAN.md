# PLAN: Workout-Type Parity — every type logs like climbing

**Created**: 2026-06-19
**Source**: `docs/ux-research/workout-type-parity/` (deep-review + adversarial-verify workflows, wireframes) · follow-on to `quick-session-redesign/PLAN.md`
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`
**Branch**: `claude/workout-type-parity` (single branch, all phases)
**Deferred**: running distance Tier-2 (watch auto-distance) + Tier-3 (phone GPS/route) → GitHub issue [#177](https://github.com/harshal2802/snappet-mobile/issues/177)

## Why

The climb-first redesign (PR #175) gave **climbing** a rich entity→effort structure: an expandable card,
last-time prefill, a live stats ribbon, per-set clips, and a type-adaptive summary. That richness is uneven
elsewhere: **strength** is a flat List section (`liftingOrTimedSection`) whose add-flow drops the prescription
(`addLifting` hardcodes `targetSets:0, targetReps:""`); **timed** (`.duration`) is *already* a climb-style card
but its sets render flat; and **running / dance / other don't exist** as disciplines (`SetKind` has only
`repsWeight/duration/climbAttempt`). Timing is a separate top-level type, so a strength set can never *also* be
timed even though `SetLog.durationSec` already exists.

This brings **Strength, Running, Dance, Other** to climbing's structure, makes **timing an orthogonal per-set
axis**, and gives clips/photos the same per-set + entity-level attach across every discipline.

## The spine (the contract every phase follows)

Split the monolithic `SetKind` into **two orthogonal axes**:

- **Discipline** on the entity — a new `WorkoutDiscipline` (`strength/climb/run/dance/timed/other`) stored as
  `SessionExercise.disciplineRaw`; `nil` ⇒ derive from `kind` (`repsWeight→strength`, `duration→timed`,
  `climbAttempt→climb`). Drives icon, add-sheet, card chrome, summary branch, rest context, and the watch HK type.
- **Measurement axes** on each effort — `SetLog` is already an all-optional union; a leaf can carry reps,
  weight, `durationSec`, `distanceMeters` (new), outcome **independently**. `SetMeasure` renders whichever axes
  are present (climbing already proves the combined "V4 · Sent · 3 tries · 0:42" row).

**All new persisted fields are additive `Optional`** on the existing Codable composites (`SetLog`,
`SessionExercise`) → SwiftData lightweight migration, no `SnappetSchema` change, and (because synthesized
`Codable` omits nil optionals via `encodeIfPresent`) the backup golden bytes stay stable for old data. We add
**no new `@Model`** (the per-entity history table is deferred). `SetKind` is **not** extended — the discipline
axis carries the new types; run/dance/other entities are `kind: .duration` (time-based) distinguished by
`discipline`, with run additionally populating `distanceMeters`.

## Reuse, don't rebuild

`climbSection`/`climbHeader`/`climbFooter` → a discipline-parameterized `EntitySection`; `QuickAddRow`;
`AddClimbSheet`/`PickTimedExerciseSheet`/`ExercisePickerView` templates; `updateClimb`/`EditClimbTarget`
edit-in-place; `TimedAttemptCover` (generalize); `StructuredTimedRunner`+`IntervalSchedule` (already
type-agnostic in `Shared/`); `RestTimerDefaults.Context` (already orthogonal); `SetMediaStrip` +
`SessionMediaAssignment` (already kind-blind); `FreeformClimbStats → KilterSessionStats` bridge pattern;
`statsRibbonSection`/`LiveClimbStatsSheet`; `WorkoutHRStats`/`ZoneBar` (type-agnostic); `appendLog` funnel.

## Design tokens

Per-discipline accents from `SnappetColor`: strength = `.workout` (ember), climb = `.kilter` (amber),
run = `.budget` (azure), timed = `.pomodoro` (tomato), dance = `.journal` (violet), other = `.expenses` (teal).
Primary CTAs stay ember (the module accent, as the climb redesign decided). Reuse `snappetCard`, the glass HUD,
`StopwatchView`, `CelebrationBurst`, the docked command bar.

## Phases (each = build-green + unit-tests-green before moving on; one commit; PDD prompt + decisions.md ship alongside)

0. **Model + discipline axis + summary enum.** `WorkoutDiscipline.swift` (+ tests); `DistanceUnit`;
   `SessionExercise.disciplineRaw`+`discipline`; `SetLog.distanceMeters`+`rpe`; `SetMeasure` combined
   reps×weight×time + `formatDistance`/`formatPace`/`runSummary`; widen `FreeformSummary.Dominant` +
   `dominant()` (count by discipline) + `stats()` headline (running→distance, dance/other→active). **No new UI.**
1. **Extract `EntitySection`.** Generalize `climbSection` into a discipline-parameterized card; re-point
   **climb AND `timedSection`** onto it with **no behavior change**; gate timed sets behind expand. Publish the
   a11y-identifier inventory (`freeform.expand`/`entityMenu`/`logSet`/`timeThisSet`/`logLeg`…). Existing climb
   UITests **+ `TimedSetTimerTests`** stay green.
2. **Strength parity.** Hybrid add (`⚙` per-exercise default sets×reps×weight×unit → `AddStrengthParams` →
   `addStrengthFromSheet`); strength rich card + rollup (top set · volume · e1RM PR); `QuickAddRow` inline unit
   toggle; recent-prescription chips; rest timer; **inline edit-entity** (`updateStrength`); per-set media strip
   on every set.
3. **Timed-orthogonal.** Generalize/audit `TimedAttemptCover` (entity header); "⏱ Time this set" on
   strength/run/other; count-up default + optional count-down target hold; consolidate the two climb-timing
   entry points; persist + render the combined reps×weight×time row.
4. **Running.** `distanceMeters` axis + derived pace; running card + add-leg sheet (manual distance+duration);
   time-in-zone reuse; entity photo. (Watch/GPS distance → #177.)
5. **Dance / Other + chooser.** Expand the type chooser to six; lightweight open-count-up entity; offer the
   entity grammar only on the second logged thing.
6. **Stats + ribbon + mixed summary.** Pure `StrengthSessionStats`/`RunSessionStats`/`TimedSessionStats`
   (mirror `FreeformClimbStats`); live ribbon for all disciplines; mixed-session summary (roll up each
   discipline); cross-type milestones (e1RM PR / longest hold / farthest-fastest run); deep-tap clip menu on all
   disciplines with discipline-aware "Move to set/leg/attempt".

### Cross-cutting (fold into the relevant phase, not a separate one)
- **Watch HK type:** `WorkoutDiscipline → HKWorkoutActivityType` (`WorkoutActivityMapping`) + the
  mixed/unknown-at-start behaviour for `LiveMetricsCoordinator`'s single `HKWorkoutSession` (Phase 4/6).
- **Saved-session detail:** the *second* `kind` switch `SetTileRow` (`SessionDetailView.swift`) — thread the new
  axes/disciplines (Phase 1/3/4).
- **History filter:** the `SetKind`-keyed facet (`HistorySectionView.swift`) → discipline chips (Phase 5/6).
- **Backup:** update `SnappetBackupTests` golden + Android `BackupRoundTripTest` in the wave that first writes a
  non-nil new field (Phase 2 onward).

## Out of scope (v1) — see `docs/ux-research/workout-type-parity/README.md` §10
Guided **routine player/builder** stays reps×weight-only; GPS/route running (#177); discipline-aware Live
Activity/widget/Spotlight (follow-up); per-entity history `@Model`; Studio caption overlay stays climb-only.

## Test strategy
- Pure logic (`WorkoutDiscipline`, `SetMeasure`, `FreeformSummary`, the stats bridges) → `SnappetTests` (XCTest,
  no device) — the primary gate, run every phase.
- Build-for-testing green every phase (Swift 6, 0 warnings).
- Migration: decode a pre-change `WorkoutSession` blob and assert it still renders.
- Update affected UITests; keep them compiling. Full UITest suite is ~14–30 min + sim-flaky (decisions.md) — run
  targeted UITests where cheap; lean on unit + build + on-device for the rest.

## Android
A separate wave after iOS lands (its own `WorkoutModels.kt`/`WorkoutDao.kt`/`WorkoutPlayerScreen.kt` + a possible
Room migration for new columns + `BackupRoundTripTest.kt` mirror).
