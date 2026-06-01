import Foundation
import SwiftData

// MARK: - Exercise taxonomy (mirrors the web app's `types.ts`, which follows the
// Free Exercise DB shape — yuhonas/free-exercise-db). Raw values match the bundled
// `exercises.json` exactly so decoding is a straight rawValue lookup.

enum ExerciseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case strength, cardio, stretching, plyometrics, powerlifting
    case olympicWeightlifting = "olympic weightlifting"
    case strongman
    var id: String { rawValue }
    var display: String {
        self == .olympicWeightlifting ? "Olympic" : rawValue.capitalized
    }
    /// SF Symbol used in place of the web app's photo for each exercise.
    var symbol: String {
        switch self {
        case .strength, .powerlifting: return "dumbbell.fill"
        case .cardio: return "figure.run"
        case .stretching: return "figure.cooldown"
        case .plyometrics: return "figure.jumprope"
        case .olympicWeightlifting: return "figure.strengthtraining.traditional"
        case .strongman: return "figure.strengthtraining.functional"
        }
    }
}

enum ExerciseLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case beginner, intermediate, expert
    var id: String { rawValue }
    var display: String { rawValue.capitalized }
}

enum Force: String, Codable, CaseIterable, Sendable {
    case pull, push
    case staticForce = "static"
    var display: String { self == .staticForce ? "Static" : rawValue.capitalized }
}

enum Mechanic: String, Codable, CaseIterable, Sendable {
    case compound, isolation
    var display: String { rawValue.capitalized }
}

enum Muscle: String, Codable, CaseIterable, Identifiable, Sendable {
    case abdominals, abductors, adductors, biceps, calves, chest, forearms
    case glutes, hamstrings, lats
    case lowerBack = "lower back"
    case middleBack = "middle back"
    case neck, quadriceps, shoulders, traps, triceps
    var id: String { rawValue }
    var display: String { rawValue.capitalized }
}

enum Equipment: String, Codable, CaseIterable, Identifiable, Sendable {
    case bodyOnly = "body only"
    case machine, other
    case foamRoll = "foam roll"
    case kettlebells, dumbbell, cable, barbell, bands
    case medicineBall = "medicine ball"
    case exerciseBall = "exercise ball"
    case ezCurlBar = "e-z curl bar"
    var id: String { rawValue }
    var display: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .bodyOnly: return "figure.strengthtraining.functional"
        case .barbell, .ezCurlBar: return "figure.strengthtraining.traditional"
        case .dumbbell: return "dumbbell.fill"
        case .kettlebells: return "figure.cross.training"
        case .machine, .cable: return "gearshape.fill"
        case .bands: return "scribble"
        case .medicineBall, .exerciseBall: return "circle.circle.fill"
        case .foamRoll: return "cylinder.fill"
        case .other: return "questionmark.circle"
        }
    }
}

// MARK: - Exercise (value type)

/// A single exercise. Bundled catalog exercises decode from `exercises.json`;
/// user-created ones are produced from a `CustomExercise` `@Model` with `isCustom == true`.
/// Decoding is lenient: an unrecognised muscle/equipment string is dropped rather than
/// failing the whole catalog load.
struct Exercise: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let force: Force?
    let level: ExerciseLevel
    let mechanic: Mechanic?
    let equipment: Equipment?
    let primaryMuscles: [Muscle]
    let secondaryMuscles: [Muscle]
    let instructions: [String]
    let category: ExerciseCategory
    var isCustom: Bool = false

    var allMuscles: [Muscle] { primaryMuscles + secondaryMuscles }

    /// Short subtitle for list rows, e.g. "Barbell · Compound · Chest".
    var subtitle: String {
        var parts: [String] = []
        if let equipment { parts.append(equipment.display) }
        if let primary = primaryMuscles.first { parts.append(primary.display) }
        parts.append(level.display)
        return parts.joined(separator: " · ")
    }
}

extension Exercise: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, force, level, mechanic, equipment
        case primaryMuscles, secondaryMuscles, instructions, category, isCustom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        force = Force(rawValue: (try? c.decodeIfPresent(String.self, forKey: .force)) ?? nil ?? "")
        level = ExerciseLevel(rawValue: (try? c.decode(String.self, forKey: .level)) ?? "beginner") ?? .beginner
        mechanic = Mechanic(rawValue: (try? c.decodeIfPresent(String.self, forKey: .mechanic)) ?? nil ?? "")
        equipment = Equipment(rawValue: (try? c.decodeIfPresent(String.self, forKey: .equipment)) ?? nil ?? "")
        primaryMuscles = (try? c.decode([String].self, forKey: .primaryMuscles))?.compactMap(Muscle.init) ?? []
        secondaryMuscles = (try? c.decode([String].self, forKey: .secondaryMuscles))?.compactMap(Muscle.init) ?? []
        instructions = (try? c.decode([String].self, forKey: .instructions)) ?? []
        category = ExerciseCategory(rawValue: (try? c.decode(String.self, forKey: .category)) ?? "strength") ?? .strength
        isCustom = (try? c.decodeIfPresent(Bool.self, forKey: .isCustom)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(force?.rawValue, forKey: .force)
        try c.encode(level.rawValue, forKey: .level)
        try c.encodeIfPresent(mechanic?.rawValue, forKey: .mechanic)
        try c.encodeIfPresent(equipment?.rawValue, forKey: .equipment)
        try c.encode(primaryMuscles.map(\.rawValue), forKey: .primaryMuscles)
        try c.encode(secondaryMuscles.map(\.rawValue), forKey: .secondaryMuscles)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(category.rawValue, forKey: .category)
        try c.encode(isCustom, forKey: .isCustom)
    }
}

// MARK: - Units, sport/level tags

enum WeightUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case kg, lb
    var id: String { rawValue }
    var display: String { rawValue }
}

enum SportTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case general, climbing, calisthenics
    var id: String { rawValue }
    var display: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "figure.mixed.cardio"
        case .climbing: return "figure.climbing"
        case .calisthenics: return "figure.gymnastics"
        }
    }
}

enum RoutineLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case beginner, intermediate, advanced
    var id: String { rawValue }
    var display: String { rawValue.capitalized }
}

// MARK: - Nested value types (persisted inside `@Model`s as Codable composites)

/// One exercise slot inside a routine: a target prescription (sets × reps, rest, optional
/// starting weight and notes). `reps` is free text ("12", "8-12", "30s", "max") like the web app.
struct RoutineExercise: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var exerciseId: String
    var sets: Int
    var reps: String
    var restSeconds: Int
    var weight: Double?
    var weightUnit: WeightUnit?
    var notes: String?
    var displayName: String?
}

/// One logged set during a live/finished session.
struct SetLog: Codable, Hashable, Sendable {
    var actualReps: Int?
    var actualWeight: Double?
    var weightUnit: WeightUnit?
    var completedAt: Date?
}

/// An exercise as it appears in a session: a snapshot of the routine target plus the
/// per-set log the user fills in while training.
struct SessionExercise: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var exerciseId: String
    var targetSets: Int
    var targetReps: String
    var targetRestSeconds: Int
    var targetWeight: Double?
    var targetWeightUnit: WeightUnit?
    var sets: [SetLog]
    var skipped: Bool = false
    var displayName: String?

    var completedSetCount: Int { sets.filter { $0.completedAt != nil }.count }
}

/// One persisted heart-rate sample of a session's live HR series. `t` is seconds from
/// `WorkoutSession.startedAt` (the engine convention — same timeline as `HRSample.t`),
/// `bpm` the measured rate. Stored as a Codable composite inside `WorkoutSession` (like
/// `exercises`) — **not** a separate `@Model` — so adding `hrSeries` is an additive
/// lightweight migration, mirroring the Journal `tags` precedent (decisions.md 2026-05-31).
struct HRPoint: Codable, Hashable, Sendable {
    var t: Double
    var bpm: Double
}

// MARK: - SwiftData models

/// A workout routine: an ordered list of exercise prescriptions. Starter routines are
/// seeded with `isStarter == true` and a stable `starterKey`; user edits/creations have
/// `isStarter == false`. The exercise list is stored as a Codable composite (no SwiftData
/// relationship) because it is always loaded and edited whole, mirroring the web app's
/// single-object shape.
@Model
final class Routine {
    var id: UUID
    var name: String
    var exercises: [RoutineExercise]
    var createdAt: Date
    var updatedAt: Date
    var isStarter: Bool
    /// Stable key for a seeded starter (e.g. "starter-beginner-full-body"); nil for user routines.
    var starterKey: String?
    /// Raw `SportTag`/`RoutineLevel` values (stored as strings so the top-level schema stays simple).
    var sportRaw: String?
    var levelRaw: String?
    var tags: [String]
    var detail: String?
    var sourceLabel: String?
    var sourceURL: String?

    init(id: UUID = UUID(), name: String, exercises: [RoutineExercise] = [],
         createdAt: Date = .now, updatedAt: Date = .now, isStarter: Bool = false,
         starterKey: String? = nil, sport: SportTag? = nil, level: RoutineLevel? = nil,
         tags: [String] = [], detail: String? = nil,
         sourceLabel: String? = nil, sourceURL: String? = nil) {
        self.id = id
        self.name = name
        self.exercises = exercises
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isStarter = isStarter
        self.starterKey = starterKey
        self.sportRaw = sport?.rawValue
        self.levelRaw = level?.rawValue
        self.tags = tags
        self.detail = detail
        self.sourceLabel = sourceLabel
        self.sourceURL = sourceURL
    }

    var sport: SportTag? {
        get { sportRaw.flatMap(SportTag.init) }
        set { sportRaw = newValue?.rawValue }
    }
    var level: RoutineLevel? {
        get { levelRaw.flatMap(RoutineLevel.init) }
        set { levelRaw = newValue?.rawValue }
    }

    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets } }
}

/// A workout session. While live, `completedAt == nil` (at most one such "active" session
/// exists at a time). When the user finishes or saves-and-exits, `completedAt` is stamped
/// and the session becomes part of history.
@Model
final class WorkoutSession {
    var id: UUID
    var routineID: UUID?
    var routineName: String
    var startedAt: Date
    var completedAt: Date?
    var exercises: [SessionExercise]
    /// The live heart-rate series captured during the session (flushed from the active
    /// `MetricsSource` buffer in `finishWorkout` on a saved finish). Empty when there was
    /// no live HR source (e.g. on the simulator, or a phone-only workout) — the summary's
    /// HR chart/stats hide cleanly in that case. **Additive** property (default `[]`) →
    /// SwiftData lightweight migration; `SnappetSchema.models` is unchanged (the Journal
    /// `tags` precedent, decisions.md 2026-05-31 / 2026-06-01 B2).
    var hrSeries: [HRPoint] = []

    init(id: UUID = UUID(), routineID: UUID? = nil, routineName: String,
         startedAt: Date = .now, completedAt: Date? = nil, exercises: [SessionExercise] = [],
         hrSeries: [HRPoint] = []) {
        self.id = id
        self.routineID = routineID
        self.routineName = routineName
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.exercises = exercises
        self.hrSeries = hrSeries
    }

    var isActive: Bool { completedAt == nil }
    var duration: TimeInterval { (completedAt ?? .now).timeIntervalSince(startedAt) }
    var completedSetCount: Int { exercises.reduce(0) { $0 + $1.completedSetCount } }
    var completedExerciseCount: Int { exercises.filter { !$0.skipped && $0.completedSetCount > 0 }.count }
}

/// A user-created exercise. Stored separately from the bundled catalog and merged into the
/// browse list at runtime. Converts to/from the `Exercise` value type for display.
@Model
final class CustomExercise {
    /// Stable id, prefixed "custom-" so it never collides with bundled ids.
    var id: String
    var name: String
    var categoryRaw: String
    var levelRaw: String
    var forceRaw: String?
    var mechanicRaw: String?
    var equipmentRaw: String?
    var primaryMuscles: [String]
    var secondaryMuscles: [String]
    var instructions: [String]
    var createdAt: Date

    init(id: String = "custom-\(UUID().uuidString)", name: String,
         category: ExerciseCategory = .strength, level: ExerciseLevel = .beginner,
         force: Force? = nil, mechanic: Mechanic? = nil, equipment: Equipment? = nil,
         primaryMuscles: [Muscle] = [], secondaryMuscles: [Muscle] = [],
         instructions: [String] = [], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.categoryRaw = category.rawValue
        self.levelRaw = level.rawValue
        self.forceRaw = force?.rawValue
        self.mechanicRaw = mechanic?.rawValue
        self.equipmentRaw = equipment?.rawValue
        self.primaryMuscles = primaryMuscles.map(\.rawValue)
        self.secondaryMuscles = secondaryMuscles.map(\.rawValue)
        self.instructions = instructions
        self.createdAt = createdAt
    }

    var asExercise: Exercise {
        Exercise(
            id: id, name: name,
            force: forceRaw.flatMap(Force.init),
            level: ExerciseLevel(rawValue: levelRaw) ?? .beginner,
            mechanic: mechanicRaw.flatMap(Mechanic.init),
            equipment: equipmentRaw.flatMap(Equipment.init),
            primaryMuscles: primaryMuscles.compactMap(Muscle.init),
            secondaryMuscles: secondaryMuscles.compactMap(Muscle.init),
            instructions: instructions,
            category: ExerciseCategory(rawValue: categoryRaw) ?? .strength,
            isCustom: true
        )
    }

    /// Overwrite all editable fields from an `Exercise` value (used by the editor).
    func apply(_ e: Exercise) {
        name = e.name
        categoryRaw = e.category.rawValue
        levelRaw = e.level.rawValue
        forceRaw = e.force?.rawValue
        mechanicRaw = e.mechanic?.rawValue
        equipmentRaw = e.equipment?.rawValue
        primaryMuscles = e.primaryMuscles.map(\.rawValue)
        secondaryMuscles = e.secondaryMuscles.map(\.rawValue)
        instructions = e.instructions
    }
}
