import Foundation

/// The **discipline-aware bridge** from a routine's prescription to a live session's exercises
/// (workout-redesign E4 keystone). This is the pure, device-free core of `makeSession(from:)`: it maps each
/// `RoutineExercise` to a `SessionExercise`, **propagating the discipline + per-axis prescription** so a
/// routine-started session reconstructs the right card type (a climb block becomes a `.climbAttempt`
/// `SessionExercise` with the prescribed grade, a timed block a `.duration` exercise with its
/// `TimedExerciseSpec`, a run a `.duration`+distance exercise) — not always a strength reps×weight slot.
///
/// Before E4, `makeSession` set neither `kindRaw` nor `disciplineRaw`, so every routine session was
/// strength-flavored regardless of what the routine actually was. Now: `se.disciplineRaw = re.disciplineRaw`
/// and `se.kindRaw = re.discipline.defaultSetKind.rawValue`, with the climb/timed/distance metadata carried
/// through verbatim.
///
/// Pure (Foundation only — no SwiftUI/SwiftData/HealthKit) so the mapping is unit-tested without a device
/// (`RoutineSessionBuilderTests`), per the repo's pure-logic-at-a-thin-edge rule. The SwiftData edge
/// (`WorkoutTrackerModule.makeSession`) just wraps the result in a `WorkoutSession`.
enum RoutineSessionBuilder {

    /// Map a routine's prescription to the session exercises a freshly-started session begins with.
    /// `defaultUnit` is the user's preferred weight unit, used when a strength block carries no unit.
    static func exercises(from routine: Routine, defaultUnit: WeightUnit) -> [SessionExercise] {
        routine.exercises.map { sessionExercise(from: $0, defaultUnit: defaultUnit) }
    }

    /// How many times a routine block is played (prompt 139). A structured timed protocol (repeaters /
    /// tabata / EMOM) carries its own sets inside the spec, so ONE run of it is the whole block — its
    /// `sets` counts runs, not the protocol's sets. Routines saved before 139 copied `spec.sets` into the
    /// block (a 3-set protocol then asked for 3 full runs = 9 sets); that exact legacy value reads as 1.
    static func plannedRuns(for re: RoutineExercise) -> Int {
        guard re.discipline == .timed, let spec = re.timedSpec, spec.mode.isStructured else { return re.sets }
        return re.sets == spec.sets ? 1 : max(1, re.sets)
    }

    /// Map one `RoutineExercise` → one `SessionExercise`, type-aware.
    static func sessionExercise(from re: RoutineExercise, defaultUnit: WeightUnit) -> SessionExercise {
        let discipline = re.discipline
        var se = SessionExercise(
            exerciseId: re.exerciseId,
            targetSets: plannedRuns(for: re),
            targetReps: re.reps,
            targetRestSeconds: re.restSeconds,
            targetWeight: re.weight,
            targetWeightUnit: re.weightUnit ?? defaultUnit,
            // A freshly-started session begins with **no** per-set logs — every discipline grows its
            // sets as they're logged, so `sets` always means "logged efforts" and the single pager
            // renders a routine exactly like a freeform session (SSOT). The prescription that used to be
            // baked into blank sets now lives where the pager already reads it: the planned count from
            // `targetSets` (`QuickSessionPager.plannedCount`), reps/weight from `targetReps`/`targetWeight`
            // (`quickAddSeed`), rest from `targetRestSeconds`, and a climb's grade from the entity-level
            // `climbGradeLabel` (each logged attempt is stamped on completion).
            sets: [],
            displayName: re.displayName)

        // Propagate the discipline + the kind it logs efforts as (the keystone). Keep `disciplineRaw` nil
        // for a strength block (the additive-nil invariant — a strength routine session is byte-identical
        // to a pre-E4 one); set both raws for every other discipline so the player picks the right card.
        if discipline != .strength {
            se.disciplineRaw = re.disciplineRaw
            se.kindRaw = discipline.defaultSetKind.rawValue
        }

        // Carry the per-discipline prescription metadata so the live card / player can prefill + render it.
        switch discipline {
        case .climb:
            se.climbTypeRaw = re.climbTypeRaw
            se.climbGradeLabel = re.climbGradeLabel
            se.climbGradeScaleRaw = re.climbGradeScaleRaw
        case .timed:
            se.timedSpecData = re.timedSpecData
            se.timedCategory = re.timedCategory
        case .run, .dance, .other, .strength:
            break
        }
        return se
    }

    // MARK: - Seeding a routine block from the library (the E3 → E4 builder pipeline)

    /// Build a `RoutineExercise` block from a library item the user picked in the block builder
    /// (workout-redesign E4). Reads `LibraryItem.source` to seed a **typed** block: a strength item →
    /// a reps×weight block; a timed item → a `.timed` block carrying its `TimedExerciseSpec` + category; a
    /// climb starter → a `.climb` block prescribing the starter's type + a mid grade; a run starter → a
    /// `.run` block with the suggested distance. Targets stay light (fast-entry ethos — the user refines
    /// them in the editor). Pure → unit-tested.
    static func block(from item: LibraryItem, defaultUnit: WeightUnit,
                      defaultSets: Int = 3, defaultReps: String = "10", defaultRest: Int = 90) -> RoutineExercise {
        switch item.source {
        case .strength:
            return RoutineExercise(exerciseId: item.id, sets: defaultSets, reps: defaultReps,
                                   restSeconds: defaultRest, weightUnit: defaultUnit)
        case let .timed(specData, category, _):
            let spec = specData.flatMap { try? JSONDecoder().decode(TimedExerciseSpec.self, from: $0) }
            // The block's per-set target = a single fixed hold's seconds when the spec is a simple hold;
            // a structured protocol carries its sets/reps in the spec itself. Default to one set.
            let target: Double? = {
                guard let spec else { return nil }
                return spec.workSec > 0 && !spec.mode.isStructured ? Double(spec.workSec) : nil
            }()
            // A structured protocol is one run (its sets live in the spec — prompt 139); a simple hold
            // defaults to one set too.
            return RoutineExercise(exerciseId: item.id, sets: 1, reps: "", restSeconds: defaultRest,
                                   displayName: item.title, discipline: .timed,
                                   targetDurationSec: target,
                                   timedSpecData: specData, timedCategory: category.rawValue)
        case let .climb(starter):
            let scale = starter.climbType.defaultScale
            return RoutineExercise(exerciseId: item.id, sets: 3, reps: "", restSeconds: 180,
                                   displayName: starter.name, discipline: .climb,
                                   climbTypeRaw: starter.climbType.rawValue,
                                   climbGradeLabel: scale.defaultGrade, climbGradeScaleRaw: scale.rawValue)
        case let .run(starter):
            return RoutineExercise(exerciseId: item.id, sets: 1, reps: "", restSeconds: 0,
                                   displayName: starter.name, discipline: .run,
                                   targetDistanceMeters: starter.distanceMeters)
        }
    }

}
