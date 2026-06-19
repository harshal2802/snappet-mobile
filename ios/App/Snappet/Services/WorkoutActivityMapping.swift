import Foundation
import HealthKit

/// Maps a WorkoutTracker routine's `SportTag` / `ExerciseCategory` to the
/// `HKWorkoutActivityType` the watch should start for a live session.
///
/// This is the **inverse** of `HealthKitService.map(_:)` (which collapses an
/// `HKWorkoutActivityType` *down* to the engine's coarse `Activity` for post-hoc
/// highlight detection). The live path needs the opposite direction — from the
/// routine the user is about to run *up* to the concrete HealthKit type the watch
/// should record — so it lives in its own helper and never entangles the post-hoc
/// `HealthKitService` (decisions.md 2026-06-01: WorkoutTracker's live path is new).
///
/// Pure value-mapping, no platform I/O, so it is unit-testable in the app test
/// target with no device (`HKWorkoutActivityType` is a plain enum).
enum WorkoutActivityMapping {
    /// Resolve the activity type for a routine, preferring its `SportTag` and
    /// falling back to the dominant `ExerciseCategory` of its exercises, then to
    /// `.traditionalStrengthTraining` (a gym routine's sensible default) or `.other`.
    ///
    /// - Parameters:
    ///   - sport: the routine's `SportTag` (climbing / calisthenics / general), if set.
    ///   - category: the routine's dominant exercise category, if known.
    static func activityType(sport: SportTag?, category: ExerciseCategory?) -> HKWorkoutActivityType {
        // Sport is the stronger signal — it is an explicit per-routine label.
        if let sport {
            switch sport {
            case .climbing: return .climbing
            case .calisthenics: return .functionalStrengthTraining
            case .general: break   // fall through to category
            }
        }
        if let category {
            return activityType(for: category)
        }
        // A WorkoutTracker routine with no sport/category is a generic gym session.
        return .traditionalStrengthTraining
    }

    /// Category → type. `.other` is the explicit fallback the spec requires.
    static func activityType(for category: ExerciseCategory) -> HKWorkoutActivityType {
        switch category {
        case .strength, .powerlifting: return .traditionalStrengthTraining
        case .olympicWeightlifting, .strongman: return .functionalStrengthTraining
        case .cardio: return .mixedCardio   // generic: a cardio routine may be cycling/rowing, not running
        case .plyometrics: return .jumpRope
        case .stretching: return .flexibility
        }
    }

    /// **`WorkoutDiscipline` → `HKWorkoutActivityType`** (workout-redesign E4). The discipline axis is now
    /// the identity axis (it sits on every `RoutineExercise`/`SessionExercise`), so the live watch type
    /// follows it directly: a running block records `.running`, a climb `.climbing`, a dance `.cardioDance`,
    /// a timed circuit `.highIntensityIntervalTraining`. Strength stays `.traditionalStrengthTraining`;
    /// `.other` is the honest fallback. This NEVER silently logs a run as strength (README §10 Q1).
    static func activityType(for discipline: WorkoutDiscipline) -> HKWorkoutActivityType {
        switch discipline {
        case .strength: return .traditionalStrengthTraining
        case .climb:    return .climbing
        case .run:      return .running
        case .dance:    return .cardioDance
        case .timed:    return .highIntensityIntervalTraining
        case .other:    return .other
        }
    }

    /// Resolve the activity type for a **discipline-aware** routine (E4). Prefers the routine's own
    /// disciplines over the legacy `SportTag`/category signals — the discipline is the explicit per-block
    /// label the user chose. A single-discipline routine records that discipline's type; a **mixed** routine
    /// (a strength block + a timed circuit + a run) records `.mixedCardio` — one `HKWorkoutSession` holds one
    /// activity type, so a mixed session can't faithfully be any single one, and `.mixedCardio` is the honest
    /// umbrella (never silently a run-as-strength). Falls back to the `sport`/`category` path when a routine
    /// carries no discipline tags (a pre-E4 / all-strength routine).
    static func activityType(disciplines: [WorkoutDiscipline],
                             sport: SportTag?, category: ExerciseCategory?) -> HKWorkoutActivityType {
        let distinct = Set(disciplines)
        if distinct.count == 1, let only = distinct.first, only != .strength {
            return activityType(for: only)
        }
        if distinct.count > 1 {
            return .mixedCardio   // mixed-session: one HK type can't be all → the honest umbrella (§10 Q1)
        }
        // Empty, or a single all-strength routine → the legacy sport/category resolution (unchanged).
        return activityType(sport: sport, category: category)
    }

    /// The dominant category across a set of exercises (the most common one), or
    /// `nil` when the list is empty. Lets a routine without a `SportTag` still pick
    /// a sensible type from what the user is actually doing.
    static func dominantCategory(of categories: [ExerciseCategory]) -> ExerciseCategory? {
        guard !categories.isEmpty else { return nil }
        let counts = Dictionary(categories.map { ($0, 1) }, uniquingKeysWith: +)
        // Tie-break deterministically by rawValue so the result is stable.
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key.rawValue > b.key.rawValue
        }?.key
    }
}
