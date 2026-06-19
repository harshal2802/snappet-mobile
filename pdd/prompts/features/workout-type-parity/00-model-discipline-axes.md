# Prompt: Workout-Type Parity — model + discipline axis + summary enum (Phase 0)

**File**: pdd/prompts/features/workout-type-parity/00-model-discipline-axes.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-type-parity/PLAN.md` → Phase 0
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`; design in `docs/ux-research/workout-type-parity/README.md` (§2–§3, §6)

## Goal

Lay the pure-logic foundation for type parity with **zero new UI and zero SwiftData migration**: a
`WorkoutDiscipline` axis on the entity, two new effort axes (`distanceMeters`, `rpe`) on the leaf, the
`SetMeasure` formatters for combined + distance rows, and a `FreeformSummary` that classifies by discipline
(so Running/Dance/Other no longer mislabel). Everything ships unit-tested in `SnappetTests`, no simulator.

## Context the implementer needs

- The model is `WorkoutSession (@Model)` → `[SessionExercise] (Codable)` → `[SetLog] (Codable)` in
  `WorkoutModels.swift`. `SetLog` (226-238) and `SessionExercise` (242-314) are nested Codable composites —
  **additive `Optional` fields are migration-safe** (the documented invariant at `WorkoutModels.swift:220-225`)
  and, because synthesized `Codable` omits nil optionals, do NOT change backup golden bytes for existing data.
- `SetKind` (179-202) has exactly 3 cases and is **NOT** extended here. New disciplines ride the discipline
  axis; run/dance/other entities will be `kind: .duration`, distinguished by `discipline`.
- Enum conventions to mirror: `ClimbType`/`GradeScale` in `ClimbGrade.swift` (pure, `String, Codable,
  CaseIterable, Sendable`, `label`/`symbol`). `WeightUnit` lives in `WorkoutModels.swift:151`.
- `SetMeasure.swift` is the one pure formatter; its `.climbAttempt` branch already appends `durationSec`
  ("V4 · Sent · 3 tries · 0:42") — extend `.repsWeight` to do the same, and add distance/pace formatters.
- `FreeformSummary.swift` `dominant(for:)` (43-59) switches over `ex.kind` (3 cases) and `Dominant` has
  `lifting/climbing/timed/none`. Widen to classify by discipline and add `running/dance/other`.

## Approach

Stay pure (Foundation only — no SwiftUI/SwiftData/HealthKit). The HK activity-type mapping is **NOT** here (it
imports HealthKit; it lands in `WorkoutActivityMapping` in a later phase). No accent `Color` on the enum (that's
a view concern) — provide only `label`/`symbol` and a deferred `accentTokenName: String` if useful.

1. **`WorkoutDiscipline.swift`** (new, WorkoutTracker, pure):
   - `enum WorkoutDiscipline: String, Codable, CaseIterable, Sendable, Identifiable { case strength, climb, run, dance, timed, other }`
   - `label` ("Strength"/"Climbing"/"Running"/"Dance"/"Timed"/"Other"), `symbol` (SF: dumbbell.fill /
     figure.climbing / figure.run / figure.dance / timer / figure.mixed.cardio — pick sensible SF Symbols).
   - `init(legacyKind: SetKind)` → `.repsWeight→.strength`, `.duration→.timed`, `.climbAttempt→.climb`.
   - `var defaultSetKind: SetKind` → strength→`.repsWeight`, climb→`.climbAttempt`, timed/run/dance/other→`.duration`.
   - `var primaryAxis` enum or flags describing the hero measurement (reps&weight / outcome / duration /
     distance) — used later by the card; keep minimal.
2. **`DistanceUnit`** in `WorkoutModels.swift` next to `WeightUnit`:
   `enum DistanceUnit: String, Codable, CaseIterable, Identifiable, Sendable { case km, mi }` with `display`.
3. **`SetLog`** (`WorkoutModels.swift`): add additive optionals `var distanceMeters: Double?` and `var rpe: Int?`
   with doc comments matching the existing additive-Optional rationale. (Pace is derived, not stored.)
4. **`SessionExercise`** (`WorkoutModels.swift`): add `var disciplineRaw: String?` + computed
   `var discipline: WorkoutDiscipline { disciplineRaw.flatMap(WorkoutDiscipline.init(rawValue:)) ?? WorkoutDiscipline(legacyKind: kind) }`.
5. **`SetMeasure.swift`**:
   - `.repsWeight` branch: append `formatDuration(durationSec)` when `durationSec > 0` → combined
     "8 × 60 kg · 0:42" (mirror the `.climbAttempt` precedent). Don't change the no-duration output.
   - Add `static func formatDistance(_ meters: Double, unit: DistanceUnit) -> String` ("5.2 km" / "3.23 mi").
   - Add `static func formatPace(secPerKm: Double, unit: DistanceUnit) -> String` ("5:01/km" / "8:03/mi").
   - Add `static func runSummary(_ set: SetLog, unit: DistanceUnit) -> String` → "5.2 km · 26:04 · 5:01/km"
     (distance + duration + derived pace; omit pace if distance or duration is 0). Pure, tested; wired in Phase 4.
6. **`FreeformSummary.swift`**:
   - `Dominant`: add `case running, dance, other` (keep `lifting/climbing/timed/none`).
   - `dominant(for:)`: count completed sets by `ex.discipline`; map strength→`.lifting`, climb→`.climbing`,
     run→`.running`, timed→`.timed`, dance→`.dance`, other→`.other`. Deterministic tie order:
     lifting→climbing→running→timed→dance→other.
   - `stats(for:)`: extend the headline switch (now exhaustive over the wider `Dominant`):
     running → `Stat(SetMeasure.formatDistance(totalDistanceMeters(session), unit:.km), "Distance")`;
     dance/other → `Stat(SetMeasure.formatDuration(activeSeconds(session)), "Active")`.
   - Add `totalDistanceMeters(_:)` (Σ `set.distanceMeters` over `discipline == .run`) and reuse/add
     `activeSeconds(_:)` (Σ `durationSec` over completed sets). Keep `sendCount`/`holdTimeSeconds` as-is.
   - Leave `milestones`/`milestoneHeadline` unchanged this phase (new milestone cases land in Phase 6).

## Output

- `WorkoutDiscipline.swift` (new) + `WorkoutDisciplineTests.swift`.
- `WorkoutModels.swift` (`DistanceUnit`; `SetLog.distanceMeters`/`rpe`; `SessionExercise.disciplineRaw`/`discipline`).
- `SetMeasure.swift` (combined `.repsWeight`; `formatDistance`/`formatPace`/`runSummary`) + extended `SetMeasureTests`.
- `FreeformSummary.swift` (widened `Dominant`/`dominant`/`stats` + helpers) + extended `FreeformSummaryTests`.
- A `decisions.md` entry (two-axis discipline split; run/dance/other are `.duration` kind + discipline; no
  SetKind extension; additive-Optional keeps backup golden stable; pace derived not stored).

## Acceptance criteria

- [ ] `WorkoutDiscipline(legacyKind:)` and `discipline` derive correctly for all 3 legacy kinds; round-trips via `rawValue`.
- [ ] A decoded **legacy** `WorkoutSession` blob (no `disciplineRaw`/`distanceMeters`/`rpe`) still decodes and
      `discipline` falls back via `kind` (add a decode test fixture).
- [ ] `SetMeasure.summary(.repsWeight)` returns "8 × 60 kg" with no duration and "8 × 60 kg · 0:42" with one.
- [ ] `formatDistance`/`formatPace`/`runSummary` produce the documented strings; pace omitted when undefined.
- [ ] `FreeformSummary.dominant` returns `.running` for a run-discipline-dominant session and `.lifting`/
      `.climbing`/`.timed` exactly as before for legacy sessions (regression-safe); `stats` headline exhaustive.
- [ ] App changes type-check against the iOS SDK (Swift 6, 0 warnings). No platform imports in the new pure files.
- [ ] `decisions.md` updated.

## Constraints

- Pure logic only; no SwiftUI/SwiftData/HealthKit in the new files. No `@Model` added; no `SnappetSchema` change.
- Do not extend `SetKind`. Do not change existing `SetMeasure.summary` outputs except the additive combined-duration case.
- On-device only; no backend/network.

## Test plan

1. `xcodebuild build-for-testing -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
   compiles with 0 warnings.
2. `xcodebuild test -scheme Snappet -only-testing:SnappetTests/WorkoutDisciplineTests
   -only-testing:SnappetTests/SetMeasureTests -only-testing:SnappetTests/FreeformSummaryTests …` green.
3. The legacy-decode test proves migration safety by eye.
