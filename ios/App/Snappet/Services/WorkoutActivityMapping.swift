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
        case .cardio: return .running
        case .plyometrics: return .jumpRope
        case .stretching: return .flexibility
        }
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
