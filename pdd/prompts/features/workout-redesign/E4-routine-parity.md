# Prompt: E4 — Routine parity (THE KEYSTONE)

**File**: pdd/prompts/features/workout-redesign/E4-routine-parity.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-redesign/PLAN.md` → E4 (wave 2; depends on E3; the spine E5/E6/E7 all consume)
**Source**: GitHub issue [#184](https://github.com/harshal2802/Snappet/issues/184) · Part of epic #179
**Design**: `docs/ux-research/workout-redesign/README.md` §2 (keystone diagram), §4 "Routines", §5 (keystone in
detail), §6 (E4 row), §9 (scope guards), §10 (Q1 mixed-HK, Q2 SportTag vs discipline, Q3 actuals→prescription);
`wireframes.html` Flow 4 (block builder) + Flow 5 (routine detail)
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-06-19 E4 entry)

## Goal

The freeform Quick Session already carries the rich two-axis model (`WorkoutDiscipline` on the entity +
measurement axes on each `SetLog`), but **`RoutineExercise` had no discipline field at all** — so routines,
the guided `WorkoutPlayerView`, and the builder were reps×weight-locked: a "climbing" routine was a pull-up
list with an amber icon, and a timed hold was faked as a `"30s"` reps string. Propagate the discipline model
to the routine side so a routine can mix a strength block, a timed circuit, a graded climb, and a run — the
one keystone that unblocks save-as-routine (E5), QR share (E6), and smart planning (E7), all routine-shaped.

## Context the implementer needs

- `RoutineExercise` (`WorkoutModels.swift`) is a nested `Codable` composite inside `Routine.exercises` /
  `SnappetBackup.RoutineRow` — NOT an `@Model`. So additive `Optional` fields are migration-free AND
  byte-stable: synthesized `Codable` decodes a missing key as nil and OMITS a nil optional on encode (the
  documented `SetLog`/`SessionExercise` invariant). Verified empirically before relying on it.
- `makeSession(from:)` set neither `kindRaw` nor `disciplineRaw` → every routine session was strength.
- E3 shipped `LibraryItem` + `LibraryItem.Source` (the typed backing) + `LibraryBuilder.discipline(for:)` —
  the builder consumes these to seed typed blocks; `ClimbStarter`/`RunStarter` are in-memory templates.
- The guided player (826 lines) is device-verified + stateful (resume/prefill/step-back/rest/Live-Activity).

## Approach

1. **`RoutineExercise` gains additive-`Optional` fields**: `disciplineRaw` (nil ⇒ `.strength`), per-axis
   `targetDurationSec`/`targetDistanceMeters`/`targetRPE`, graded-climb (`climbTypeRaw`/`climbGradeLabel`/
   `climbGradeScaleRaw`), timed (`timedSpecData`/`timedCategory`) — mirroring `SessionExercise`. Computed
   `discipline`/`climbType`/`climbGradeScale`/`timedSpec`. The init keeps `disciplineRaw` nil for a strength
   block so its bytes match a legacy row.
2. **`RoutineSessionBuilder`** (NEW, pure) — extract makeSession's mapping: each block → a `SessionExercise`
   with `se.disciplineRaw = re.disciplineRaw` + `se.kindRaw = discipline.defaultSetKind.rawValue` + the
   climb/timed/distance metadata carried through; a fresh climb attempt is stamped with the prescribed grade.
   `block(from: LibraryItem)` is the inverse — the E3→E4 builder pipeline. Unit-tested.
3. **Block-based builder** — `RoutineEditorView` rebuilt to type-tagged blocks (discipline-tinted rows,
   adaptive columns from the measure), the picker is the E3 `LibraryPickerView` (any `LibraryItem`).
   `RoutineDetailView` becomes a discipline-rhythm of `RoutineBlockRow`s. Targets stay OPTIONAL.
4. **Discipline-aware guided `WorkoutPlayerView`** — the input block + `completeSet` switch on
   `current.discipline` (climb grade+outcome via the rung rail + `KilterAscentStatus` relabels · timed/dance/
   other via the shared `StopwatchView` · run distance+duration · strength reps×weight unchanged), reusing the
   freeform input vocabulary. The resume/prefill/step-back/rest/Live-Activity machinery is untouched.
5. **`WorkoutDiscipline → HKWorkoutActivityType`** in `WorkoutActivityMapping` (run→.running, climb→.climbing,
   dance→.cardioDance, timed→.HIIT, other→.other); `activityType(disciplines:sport:category:)` records a
   single-discipline routine's type, a **mixed** routine as `.mixedCardio`, else the legacy sport/category
   path. Threaded via `LiveMetricsCoordinator.start(for:disciplines:…)`. Re-author the climbing starters as
   real climb-discipline routines (a boulder pyramid + a route volume night) + the timed holds as `.timed`
   blocks (stop faking `"30s"`/`"60s"` as reps strings).

## Output

- `WorkoutModels.swift` (the keystone `RoutineExercise` fields + computed accessors + a designated init).
- `RoutineSessionBuilder.swift` (pure: `exercises(from:)` discipline-propagating mapping + `block(from:)`).
- `WorkoutTrackerModule.swift` (`makeSession` → builder; `startLiveMetrics` passes disciplines).
- `WorkoutActivityMapping.swift` + `LiveMetricsCoordinator.swift` (discipline → HK + the mixed-session call).
- `RoutineEditorView.swift` (block builder + discipline-aware `RoutineBlockEditor`), `LibraryPickerView.swift`,
  `RoutineDetailView.swift` (`RoutineBlockRow`), `WorkoutPlayerView.swift` (discipline-aware inputs/completeSet),
  `StarterRoutines.swift` (real climb routines + timed-hold blocks).
- `SnappetTests/RoutineSessionBuilderTests.swift`, `RoutineExerciseMigrationTests.swift`; HK cases in
  `LiveWorkoutTests.swift`. Graph + decisions updated.

## Acceptance criteria

- [x] `RoutineExercise` gains discipline + per-axis target Optionals; a legacy blob decodes with
      `discipline == .strength` + nil targets; a strength block encodes WITHOUT the new keys (byte-stable).
- [x] `makeSession` propagates discipline + kind + climb/timed/distance metadata; a mixed routine
      reconstructs each block's type (strength/timed/climb/run), tested per discipline.
- [x] The builder is block-based (discipline-tinted blocks, adaptive columns); it consumes `LibraryItem`
      and seeds typed blocks; targets stay optional.
- [x] The guided player is discipline-aware (climb/timed/run/strength inputs + per-discipline `completeSet`),
      without regressing resume/prefill/step-back/rest/Live-Activity.
- [x] `WorkoutDiscipline → HKWorkoutActivityType` added; a run never logs as strength; a mixed routine is
      `.mixedCardio`; the climbing starters are real climb routines + the holds are `.timed` blocks.
- [x] `SnappetBackupTests` golden round-trip + determinism stay green (additive nils didn't shift bytes).
- [x] App type-checks against the iOS SDK; `HighlightEngine` untouched.

## Constraints

- iOS only — the Android mirror (model + Room migration + backup round-trip) is deferred to wave H (tracked).
- No new `@Model` (composite fields only); the pure cores (`RoutineSessionBuilder`, the HK mapping) stay
  device-free + unit-tested.

## Test plan

1. `xcodebuild build-for-testing` + the full `SnappetTests` unit suite (incl. `RoutineExerciseMigrationTests`
   + `RoutineSessionBuilderTests` + `LiveWorkoutTests` + `SnappetBackupTests` golden bytes), 0 failures.
2. `WorkoutWalkthroughTests` (starts a routine → drives the discipline-aware guided player → finishes) — green.
