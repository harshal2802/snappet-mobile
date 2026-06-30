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
    /// Absolute URL to a still thumbnail (JPEG). Present only on exercises from the
    /// opt-in downloaded library (ext-* ids); always nil for the 873 bundled exercises.
    var imageURL: String? = nil
    /// Absolute URL to an animated GIF demonstrating the movement. Same source as imageURL.
    var gifURL: String? = nil

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
        case imageURL, gifURL
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
        imageURL = try? c.decodeIfPresent(String.self, forKey: .imageURL)
        gifURL = try? c.decodeIfPresent(String.self, forKey: .gifURL)
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
        try c.encodeIfPresent(imageURL, forKey: .imageURL)
        try c.encodeIfPresent(gifURL, forKey: .gifURL)
    }
}

// MARK: - Units, sport/level tags

enum WeightUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case kg, lb
    var id: String { rawValue }
    var display: String { rawValue }
}

/// Distance unit for the running/cardio discipline (Workout-Type Parity). Sticky per user, like
/// `WeightUnit`. Pace is **derived** (distance + duration), never stored.
enum DistanceUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case km, mi
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

/// What a logged "set" measures. Absent (`nil`) on legacy/routine data ⇒ `.repsWeight`, so adding it is
/// migration-safe. Lets a freeform session mix strength sets, timed holds, and graded climb attempts.
/// (dynamic-sessions D4) — the climbing outcome reuses `KilterAscentStatus` so the vocabulary is shared.
enum SetKind: String, Codable, CaseIterable, Sendable {
    case repsWeight, duration, climbAttempt
    var display: String {
        switch self {
        case .repsWeight: return "Reps & weight"
        case .duration: return "Time"
        case .climbAttempt: return "Climb"
        }
    }
    var symbol: String {
        switch self {
        case .repsWeight: return "dumbbell.fill"
        case .duration: return "timer"
        case .climbAttempt: return "figure.climbing"
        }
    }
    /// Label for the per-set "add" button.
    var addLabel: String {
        switch self {
        case .repsWeight, .duration: return "Add set"
        case .climbAttempt: return "Add attempt"
        }
    }
}

// MARK: - Nested value types (persisted inside `@Model`s as Codable composites)

/// One exercise slot inside a routine: a target prescription (sets × reps, rest, optional
/// starting weight and notes). `reps` is free text ("12", "8-12", "30s", "max") like the web app.
///
/// **The keystone change (workout-redesign E4).** This composite gained the entity-level `disciplineRaw`
/// axis + per-axis target prescription so a routine can mix a strength block, a timed circuit, a graded
/// climb, and a run — mirroring the shape `SessionExercise`/`SetLog` already carry on the session side, so
/// `makeSession(from:)` can reconstruct the right card type instead of always strength. **Every new field
/// is an additive `Optional`** — `RoutineExercise` is a nested `Codable` composite (inside `Routine.exercises`
/// / `RoutineRow`), not an `@Model`, so SwiftData lightweight migration doesn't reach inside the blob: a
/// non-optional new key would throw on decode of an old `Routine`, whereas synthesized `Codable` decodes a
/// *missing* optional key as `nil` AND omits a nil optional on encode (so the `SnappetBackup` golden bytes
/// stay stable — the documented `SetLog`/`SessionExercise` invariant). A legacy `RoutineExercise` therefore
/// decodes with `disciplineRaw == nil` and every target `nil`, and `discipline` derives `.strength`.
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

    /// `WorkoutDiscipline.rawValue` — the entity-level discipline axis (E4 keystone). `nil` ⇒ derive
    /// `.strength` (mirrors `SessionExercise.discipline`'s legacy fallback), so a pre-E4 routine keeps its
    /// identity with no migration. Additive optional.
    var disciplineRaw: String?

    // MARK: - Per-axis targets (the prescription for a non-strength block). All additive Optionals.
    /// Target hold/work duration in seconds for a timed (or timed-strength / running) prescription.
    var targetDurationSec: Double?
    /// Target distance in metres for a running prescription. Pace is derived (distance + duration).
    var targetDistanceMeters: Double?
    /// Target rate-of-perceived-exertion (1–10) — the non-climb effort target.
    var targetRPE: Int?

    // MARK: - Graded-climb prescription (mirrors `SessionExercise`'s climb metadata shape).
    /// `ClimbType.rawValue` (boulder/topRope/lead/sport); `nil` ⇒ boulder (default).
    var climbTypeRaw: String?
    /// The prescribed climb grade label (e.g. "V4" / "5.10c"); the source of truth for the routine.
    var climbGradeLabel: String?
    /// `GradeScale.rawValue` the grade is expressed in; `nil` ⇒ the type's default scale.
    var climbGradeScaleRaw: String?

    // MARK: - Timed prescription (reuses `TimedExerciseSpec`, like `SessionExercise`).
    /// An encoded `TimedExerciseSpec` — the structure (mode/work/rest/reps/sets). `nil` ⇒ open count-up.
    var timedSpecData: Data?
    /// `TimedExerciseCategory.rawValue`; `nil` ⇒ `.other` (default).
    var timedCategory: String?

    /// The block's discipline (E4). Falls back to `.strength` for legacy/pre-E4 routine exercises — the
    /// same identity-preserving fallback `SessionExercise.discipline` uses for legacy data.
    var discipline: WorkoutDiscipline {
        disciplineRaw.flatMap(WorkoutDiscipline.init(rawValue:)) ?? .strength
    }

    /// The climb's prescribed type (defaults to boulder for legacy/unset).
    var climbType: ClimbType { climbTypeRaw.flatMap(ClimbType.init) ?? .boulder }
    /// The grade scale the climb's grade is in (falls back to the type's default scale).
    var climbGradeScale: GradeScale { climbGradeScaleRaw.flatMap(GradeScale.init) ?? climbType.defaultScale }

    /// The prescribed timed structure (decoded from `timedSpecData`); `nil` ⇒ a plain open count-up.
    var timedSpec: TimedExerciseSpec? {
        get { timedSpecData.flatMap { try? JSONDecoder().decode(TimedExerciseSpec.self, from: $0) } }
        set { timedSpecData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    init(id: UUID = UUID(), exerciseId: String, sets: Int, reps: String, restSeconds: Int,
         weight: Double? = nil, weightUnit: WeightUnit? = nil, notes: String? = nil,
         displayName: String? = nil, discipline: WorkoutDiscipline? = nil,
         targetDurationSec: Double? = nil, targetDistanceMeters: Double? = nil, targetRPE: Int? = nil,
         climbTypeRaw: String? = nil, climbGradeLabel: String? = nil, climbGradeScaleRaw: String? = nil,
         timedSpecData: Data? = nil, timedCategory: String? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.sets = sets
        self.reps = reps
        self.restSeconds = restSeconds
        self.weight = weight
        self.weightUnit = weightUnit
        self.notes = notes
        self.displayName = displayName
        // Strength is the implicit default — keep `disciplineRaw` nil for a strength block so its bytes
        // match a legacy `RoutineExercise` (additive-nil-Optional invariant; the round-trip stays stable).
        self.disciplineRaw = (discipline == nil || discipline == .strength) ? nil : discipline?.rawValue
        self.targetDurationSec = targetDurationSec
        self.targetDistanceMeters = targetDistanceMeters
        self.targetRPE = targetRPE
        self.climbTypeRaw = climbTypeRaw
        self.climbGradeLabel = climbGradeLabel
        self.climbGradeScaleRaw = climbGradeScaleRaw
        self.timedSpecData = timedSpecData
        self.timedCategory = timedCategory
    }
}

/// One logged set during a live/finished session. The `actual*` fields cover a `.repsWeight` set; the
/// climb/duration fields below cover `.climbAttempt` / `.duration` sets in a freeform session. **All
/// additive fields are `Optional`** — `SetLog` is a nested `Codable` composite (inside `WorkoutSession`),
/// not an `@Model`, so SwiftData lightweight migration doesn't reach inside the blob; a non-optional new
/// key would throw on decode of old data, whereas synthesized `Codable` decodes a *missing* optional key
/// as `nil`. (dynamic-sessions D4)
struct SetLog: Codable, Hashable, Sendable {
    var actualReps: Int?
    var actualWeight: Double?
    var weightUnit: WeightUnit?
    var completedAt: Date?

    // .duration sets
    var durationSec: Double?
    // .climbAttempt sets — outcome stored as `KilterAscentStatus.rawValue` (shared climbing vocabulary).
    var climbGradeLabel: String?
    var climbStatusRaw: String?
    var climbAttempts: Int?

    // Workout-Type Parity effort axes — both additive Optionals (same migration-safety rationale as the
    // fields above; old `SetLog` blobs decode them as `nil` and synthesized `Codable` omits a nil optional
    // so backup golden bytes stay stable).
    /// Distance covered, in metres, for a running/cardio effort. Pace is **derived** (distance + duration),
    /// never stored, to avoid drift.
    var distanceMeters: Double?
    /// Optional rate-of-perceived-exertion (1–10) for a strength/timed effort — the non-climb analogue of a
    /// climb's outcome. Drives later milestone/quality reads; `nil` ⇒ unrated.
    var rpe: Int?
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
    /// `SetKind.rawValue`; `nil` ⇒ `.repsWeight` (legacy/routine exercises). Additive → migration-safe.
    var kindRaw: String?

    /// `WorkoutDiscipline.rawValue` — the entity-level discipline axis (Workout-Type Parity). `nil` ⇒
    /// derive from `kind` (`repsWeight→strength`, `duration→timed`, `climbAttempt→climb`) so legacy data
    /// and the three existing kinds keep their identity with no migration. Additive optional.
    var disciplineRaw: String?

    // MARK: - Climb metadata (Quick Session redesign). A `.climbAttempt` exercise IS the climb; its
    // `sets` are the attempts logged underneath it. These describe the climb itself — captured once in
    // the "Add a climb" sheet, inherited by every attempt. All additive Optionals → SwiftData lightweight
    // migration (the `SetLog`/`hrSeries` precedent); legacy climbs decode with `nil` and render as a
    // boulder with no grade.
    /// `ClimbType.rawValue` (boulder/topRope/lead/sport); `nil` ⇒ boulder (legacy/default).
    var climbTypeRaw: String?
    /// The climb's grade label — the source of truth, edited at the climb level. Each logged attempt is
    /// **stamped** with this so the pure send/pyramid/milestone reads stay per-`SetLog` and old data works.
    var climbGradeLabel: String?
    /// `GradeScale.rawValue` the grade is expressed in; `nil` ⇒ the type's default scale.
    var climbGradeScaleRaw: String?
    /// Gym / location — captured once and inherited by later climbs in the session; free text.
    var gym: String?
    /// The wall within the gym (a gym has many walls) — free text, suggested per-gym in the sheet.
    var wall: String?
    /// `ClimbColor.rawValue` — the route's hold/tape colour; `nil` ⇒ no colour tagged. Additive optional.
    var climbColorRaw: String?
    /// The route-setter's name — captured once in the "Add a climb" sheet, an optional climb-level tag
    /// (like `gym`/`wall`). `nil` ⇒ unset. Additive optional → SwiftData lightweight migration.
    var setter: String?

    // MARK: - Timed metadata (Quick Session redesign Phase 5). A `.duration` exercise IS the timed
    // exercise (the timed analogue of the climb-first hierarchy); its `sets` are the timed holds logged
    // underneath it. Captured once in the pick-or-create sheet, inherited by every set. Additive
    // Optionals → SwiftData lightweight migration (the climb-fields precedent); legacy unnamed "Timed
    // exercise" rows decode with `nil` and render as a plain open count-up.
    /// An encoded `TimedExerciseSpec` — the structure (mode/work/rest/reps/sets). `nil` ⇒ open count-up.
    var timedSpecData: Data?
    /// `TimedExerciseCategory.rawValue`; `nil` ⇒ `.other` (legacy/default).
    var timedCategory: String?

    var completedSetCount: Int { sets.filter { $0.completedAt != nil }.count }

    /// What each set in this exercise measures (defaults to reps & weight for legacy/routine data).
    var kind: SetKind { kindRaw.flatMap(SetKind.init) ?? .repsWeight }

    /// The entity's discipline (Workout-Type Parity). Falls back to deriving from `kind` for legacy
    /// entities and the three pre-parity kinds.
    var discipline: WorkoutDiscipline {
        disciplineRaw.flatMap(WorkoutDiscipline.init(rawValue:)) ?? WorkoutDiscipline(legacyKind: kind)
    }

    /// The timed exercise's structure (decoded from `timedSpecData`); `nil` ⇒ a plain open count-up.
    var timedSpec: TimedExerciseSpec? {
        get { timedSpecData.flatMap { try? JSONDecoder().decode(TimedExerciseSpec.self, from: $0) } }
        set { timedSpecData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// The climb's discipline (defaults to boulder for legacy/unset climbs).
    var climbType: ClimbType { climbTypeRaw.flatMap(ClimbType.init) ?? .boulder }
    /// The grade scale the climb's grade is in (falls back to the type's default scale).
    var climbGradeScale: GradeScale { climbGradeScaleRaw.flatMap(GradeScale.init) ?? climbType.defaultScale }
    /// The climb's tagged hold/tape colour, if any.
    var climbColor: ClimbColor? { climbColorRaw.flatMap(ClimbColor.init) }
    /// The resolved outcome for the climb = the "best" status across its logged attempts (flash > sent >
    /// project > attempt), or `nil` when no attempt is logged yet. Drives the rolled-up card badge.
    var resolvedClimbStatus: KilterAscentStatus? {
        let statuses = sets.compactMap { $0.climbStatusRaw.flatMap(KilterAscentStatus.init(rawValue:)) }
        let rank: (KilterAscentStatus) -> Int = {
            switch $0 { case .flash: return 3; case .sent: return 2; case .project: return 1; case .attempt: return 0 }
        }
        return statuses.max { rank($0) < rank($1) }
    }
}

/// One persisted heart-rate sample of a session's live HR series. `t` is seconds from
/// `WorkoutSession.startedAt` (the engine convention — same timeline as `HRSample.t`),
/// `bpm` the measured rate. Stored as a Codable composite inside `WorkoutSession` (like
/// `exercises`) — **not** a separate `@Model` — so adding `hrSeries` is an additive
/// lightweight migration, mirroring the Journal `tags` precedent (decisions.md 2026-05-31).
struct HRPoint: Codable, Hashable, Sendable {
    var t: Double
    var bpm: Double
    /// RR-intervals (ms) captured in the same packet, from a trusted chest strap (fitness-band
    /// Phase 3); drives on-device HRV. **Optional** → old persisted `HRPoint` blobs decode with `nil`
    /// (no migration), and watch / untrusted-band sessions simply carry none.
    var rrIntervalsMs: [Double]? = nil
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
    /// User max HR for %-of-max zone math, stamped from the `UserHRProfile` on a saved finish; `nil`
    /// (no profile / no resolvable max) → `HeartRateZone.defaultMaxHR` fallback and bpm-only `%HRR`.
    /// Mirrors `KilterSession` so per-set effort/zones personalize on the workout side too (Phase 2).
    var maxHR: Double?
    /// Resting HR baseline for `%HRR`, when the profile knows it; `nil` → the engine estimates it.
    var restHR: Double?
    /// `MetricsSourceKind.rawValue` of the transport that drove HR ("appleWatch"/"ble"), for the
    /// summary's source label + the BLE-only calorie gate; `nil` when no HR was captured.
    var metricsSourceRaw: String?
    /// HR-based calorie estimate (Keytel) for **BLE** sessions with a complete profile — fills the
    /// band's hardcoded `energy = 0`; `nil` for watch sessions (measured energy is preferred) or an
    /// incomplete profile. All four fields are additive Optionals → lightweight migration.
    var kcalEstimate: Double?

    init(id: UUID = UUID(), routineID: UUID? = nil, routineName: String,
         startedAt: Date = .now, completedAt: Date? = nil, exercises: [SessionExercise] = [],
         hrSeries: [HRPoint] = [], maxHR: Double? = nil, restHR: Double? = nil,
         metricsSourceRaw: String? = nil, kcalEstimate: Double? = nil) {
        self.id = id
        self.routineID = routineID
        self.routineName = routineName
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.exercises = exercises
        self.hrSeries = hrSeries
        self.maxHR = maxHR
        self.restHR = restHR
        self.metricsSourceRaw = metricsSourceRaw
        self.kcalEstimate = kcalEstimate
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
