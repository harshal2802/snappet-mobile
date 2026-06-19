import Foundation

/// The **discipline** of a freeform workout entity (Workout-Type Parity, Phase 0). This is the
/// entity-level axis that the climb-first redesign's `ClimbType` is to climbing: it drives the card
/// icon, the add-sheet, the rolled-up rollup, the completion-summary branch, the rest-timer context,
/// and (later, behind the HealthKit edge) the watch `HKWorkoutActivityType`.
///
/// It is the first half of the two-axis model that replaces the monolithic `SetKind`: discipline lives
/// on the entity (`SessionExercise.disciplineRaw`); the *measurement axes* (reps · weight · duration ·
/// distance · outcome) live independently on each `SetLog`. We deliberately do **not** extend `SetKind`
/// — run/dance/other entities are `kind == .duration` (time-based), distinguished by their discipline,
/// with running additionally populating `SetLog.distanceMeters`.
///
/// Pure (Foundation only — no SwiftUI/SwiftData/HealthKit) so the mapping is unit-tested without a
/// device (the repo's pure-logic-at-a-thin-edge rule). The per-discipline accent `Color` is a view
/// concern and lives with the views, not here.
enum WorkoutDiscipline: String, Codable, CaseIterable, Sendable, Identifiable {
    case strength, climb, run, dance, timed, other
    var id: String { rawValue }

    /// Derive a discipline from a legacy `SetKind` for entities saved before `disciplineRaw` existed
    /// (and for the default of any entity whose `disciplineRaw` is unset). The inverse-ish of
    /// `defaultSetKind` for the three legacy kinds.
    init(legacyKind kind: SetKind) {
        switch kind {
        case .repsWeight:   self = .strength
        case .duration:     self = .timed
        case .climbAttempt: self = .climb
        }
    }

    var label: String {
        switch self {
        case .strength: return "Strength"
        case .climb:    return "Climbing"
        case .run:      return "Running"
        case .dance:    return "Dance"
        case .timed:    return "Timed"
        case .other:    return "Other"
        }
    }

    /// SF Symbol for the entity card header / type chip / chooser tile.
    var symbol: String {
        switch self {
        case .strength: return "dumbbell.fill"
        case .climb:    return "figure.climbing"
        case .run:      return "figure.run"
        case .dance:    return "figure.dance"
        case .timed:    return "timer"
        case .other:    return "figure.mixed.cardio"
        }
    }

    /// The `SetKind` a new entity of this discipline logs its efforts as. Strength is reps&weight,
    /// climbing is a climb attempt; everything else (run/dance/timed/other) is the time-based
    /// `.duration` kind, distinguished by discipline (run also carries `distanceMeters`).
    var defaultSetKind: SetKind {
        switch self {
        case .strength: return .repsWeight
        case .climb:    return .climbAttempt
        case .run, .dance, .timed, .other: return .duration
        }
    }

    /// The hero measurement for this discipline — drives the rolled-up header stat + the completion
    /// headline. (Card chrome reads this in later phases.)
    var primaryAxis: MeasurementAxis {
        switch self {
        case .strength: return .repsWeight
        case .climb:    return .outcome
        case .run:      return .distance
        case .timed, .dance, .other: return .duration
        }
    }
}

/// What a single effort (`SetLog`) is primarily measured by — the *measurement axis*, orthogonal to the
/// entity's `WorkoutDiscipline`. A leaf may carry several axes at once (a timed strength set is reps &
/// weight **and** duration); this names the one a discipline leads with.
enum MeasurementAxis: String, Codable, Sendable {
    case repsWeight, duration, distance, outcome
}
