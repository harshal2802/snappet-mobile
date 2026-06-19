import Foundation
import SwiftData

/// The starter routines shipped with the app. Originally ported verbatim from the web app's `starters.ts`;
/// **workout-redesign E4** re-authored them to the discipline-aware `RoutineExercise`: a timed hold is now a
/// real `.timed` block (a `targetDurationSec` + a `TimedExerciseSpec`), not a fake reps string like `"30s"`,
/// and two genuine **climb-discipline** starter routines (a boulder pyramid + a route volume night) prescribe
/// actual climbing instead of a pull-up list wearing a climbing icon. They are seeded into the SwiftData
/// store on first launch so users have something to do immediately. Deleting a starter records its key in
/// `dismissedStarters` so it is not re-seeded.
enum StarterRoutines {
    /// One prescribed block in a starter routine. `.strength` carries the classic sets × reps; `.timed` a
    /// per-rep hold duration (+ structure); `.climb` a grade prescription. A `displayName` is only set for
    /// climb/timed blocks whose `id` is a starter key (not a catalog exerciseId).
    enum Block {
        /// A reps×weight strength block from the bundled catalog (id = catalog exerciseId). Bodyweight ⇒ weight nil.
        case strength(id: String, sets: Int, reps: String, rest: Int)
        /// A timed hold/circuit: `holdSec` per rep, `sets` of them, named by `name` (id = a starter key).
        case timed(key: String, name: String, holdSec: Int, sets: Int, rest: Int, category: TimedExerciseCategory)
        /// A graded climb prescription: `count` attempts at `grade` on `type` (id = a starter key).
        case climb(key: String, name: String, type: ClimbType, scale: GradeScale, grade: String, count: Int, rest: Int)

        /// Build the `RoutineExercise` for this block.
        var routineExercise: RoutineExercise {
            switch self {
            case let .strength(id, sets, reps, rest):
                return RoutineExercise(exerciseId: id, sets: sets, reps: reps, restSeconds: rest)
            case let .timed(key, name, holdSec, sets, rest, category):
                var re = RoutineExercise(exerciseId: key, sets: sets, reps: "\(holdSec)s", restSeconds: rest,
                                         displayName: name, discipline: .timed,
                                         targetDurationSec: Double(holdSec), timedCategory: category.rawValue)
                re.timedSpec = TimedExerciseSpec.hold(holdSec)   // a fixed count-down hold
                return re
            case let .climb(key, name, type, scale, grade, count, rest):
                return RoutineExercise(exerciseId: key, sets: count, reps: "", restSeconds: rest,
                                       displayName: name, discipline: .climb,
                                       climbTypeRaw: type.rawValue, climbGradeLabel: grade,
                                       climbGradeScaleRaw: scale.rawValue)
            }
        }
    }

    /// A lightweight description used both to seed `Routine`s and as the source of truth for keys.
    struct Spec {
        let key: String
        let name: String
        let sport: SportTag
        let level: RoutineLevel?
        let detail: String?
        let tags: [String]
        let sourceLabel: String?
        let sourceURL: String?
        let blocks: [Block]
    }

    /// Convenience: a plain reps×weight strength block (the most common shape).
    private static func s(_ id: String, _ sets: Int, _ reps: String, _ rest: Int) -> Block {
        .strength(id: id, sets: sets, reps: reps, rest: rest)
    }
    /// Convenience: a timed hold block.
    private static func t(_ key: String, _ name: String, hold: Int, sets: Int = 1, rest: Int = 0,
                          category: TimedExerciseCategory = .core) -> Block {
        .timed(key: key, name: name, holdSec: hold, sets: sets, rest: rest, category: category)
    }

    static let all: [Spec] = [
        Spec(key: "starter-beginner-full-body", name: "Beginner Full Body", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, blocks: [
                s("Bodyweight_Squat", 3, "12", 60), s("Pushups", 3, "10", 60),
                s("Inverted_Row", 3, "10", 60), t("timed.plank", "Plank", hold: 30, sets: 3, rest: 45),
                s("Butt_Lift_Bridge", 3, "12", 45)]),
        Spec(key: "starter-upper-body-push", name: "Upper Body Push", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, blocks: [
                s("Pushups", 4, "8-12", 90), s("Dumbbell_Shoulder_Press", 4, "8-10", 90),
                s("Bench_Dips", 3, "10", 60), s("Side_Lateral_Raise", 3, "12", 45)]),
        Spec(key: "starter-upper-body-pull", name: "Upper Body Pull", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, blocks: [
                s("Pullups", 4, "6-10", 90), s("Dumbbell_Bicep_Curl", 3, "12", 60),
                s("Face_Pull", 3, "15", 45)]),
        Spec(key: "starter-lower-body", name: "Lower Body", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, blocks: [
                s("Goblet_Squat", 4, "10", 90), s("Dumbbell_Lunges", 3, "10 each leg", 60),
                s("Romanian_Deadlift", 3, "8-10", 90), s("Standing_Calf_Raises", 3, "15", 30)]),
        Spec(key: "starter-core-crusher", name: "Core Crusher", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, blocks: [
                t("timed.plank", "Plank", hold: 45, sets: 3, rest: 45), s("Russian_Twist", 3, "20", 30),
                s("Dead_Bug", 3, "10 each side", 30), s("Flat_Bench_Lying_Leg_Raise", 3, "12", 45)]),
        Spec(key: "starter-mobility", name: "5-Minute Mobility", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, blocks: [
                t("timed.cat-stretch", "Cat stretch", hold: 60, category: .other),
                t("timed.worlds-greatest", "World's Greatest Stretch", hold: 30, sets: 2, category: .other),
                t("timed.hamstring-stretch", "Hamstring stretch", hold: 30, sets: 2, category: .legs),
                t("timed.arm-circles", "Arm circles", hold: 60, category: .other)]),
        // A genuine climb-discipline starter: a boulder pyramid session (E4 — real climbing, not a pull-up list).
        Spec(key: "starter-bouldering-pyramid", name: "Bouldering — Session Pyramid", sport: .climbing,
             level: .intermediate,
             detail: "A classic send pyramid: warm up easy, then build to your project grade and back down.",
             tags: ["boulder", "pyramid"], sourceLabel: "General climbing canon", sourceURL: nil, blocks: [
                .climb(key: "climb.warmup", name: "Warm-up boulders", type: .boulder, scale: .vScale,
                       grade: "V1", count: 3, rest: 120),
                .climb(key: "climb.build", name: "Build", type: .boulder, scale: .vScale,
                       grade: "V3", count: 3, rest: 180),
                .climb(key: "climb.project", name: "Project", type: .boulder, scale: .vScale,
                       grade: "V5", count: 4, rest: 240),
                .climb(key: "climb.downclimb", name: "Volume down", type: .boulder, scale: .vScale,
                       grade: "V2", count: 4, rest: 120)]),
        // A genuine climb-discipline starter: a roped volume night.
        Spec(key: "starter-routes-volume", name: "Routes — Volume Night", sport: .climbing,
             level: .intermediate,
             detail: "Mileage on the rope: several routes at a steady grade to build endurance.",
             tags: ["lead", "endurance"], sourceLabel: "Lattice Training blog",
             sourceURL: "https://latticetraining.com/blog/", blocks: [
                .climb(key: "climb.route-warmup", name: "Warm-up routes", type: .topRope, scale: .yds,
                       grade: "5.8", count: 2, rest: 180),
                .climb(key: "climb.route-laps", name: "Endurance laps", type: .lead, scale: .yds,
                       grade: "5.10a", count: 4, rest: 300),
                .climb(key: "climb.route-push", name: "Push", type: .lead, scale: .yds,
                       grade: "5.10d", count: 2, rest: 360)]),
        Spec(key: "starter-climbing-max-pull", name: "Climbing — Max Pulling Strength", sport: .climbing,
             level: .intermediate, detail: "Heavy pulling work to raise your ceiling for hard climbing moves.",
             tags: ["pull", "strength"], sourceLabel: "Hörst, Training for Climbing", sourceURL: nil, blocks: [
                s("Scapular_Pull-Up", 3, "5", 60), s("Pullups", 5, "5", 180),
                s("Chin-Up", 4, "6", 120), s("Inverted_Row", 3, "8", 90),
                s("Hanging_Leg_Raise", 3, "8", 60)]),
        Spec(key: "starter-climbing-antagonist", name: "Climbing — Antagonist & Recovery", sport: .climbing,
             level: .beginner, detail: "Balance pulling-heavy climbing with pressing + forearm health.",
             tags: ["antagonist", "mobility", "recovery"], sourceLabel: "Lattice Training blog",
             sourceURL: "https://latticetraining.com/blog/", blocks: [
                s("Pushups", 3, "12", 60), s("Bench_Dips", 3, "10", 60),
                s("Handstand_Push-Ups", 3, "5", 90), s("Finger_Curls", 3, "15", 45),
                t("timed.forearm-stretch", "Kneeling forearm stretch", hold: 60, sets: 2, category: .other),
                t("timed.worlds-greatest", "World's Greatest Stretch", hold: 30, sets: 2, category: .other),
                t("timed.childs-pose", "Child's pose", hold: 60, category: .other)]),
        Spec(key: "starter-climbing-power-endurance", name: "Climbing — Power Endurance", sport: .climbing,
             level: .intermediate, detail: "Sustain pulling power across longer sequences.",
             tags: ["endurance", "pull"], sourceLabel: "Bechtel, Logical Progression", sourceURL: nil, blocks: [
                s("Pullups", 3, "max-2", 180), s("Bent_Over_Two-Dumbbell_Row", 3, "10", 90),
                s("Hanging_Pike", 3, "8", 60), t("timed.mountain-climbers", "Mountain climbers", hold: 30, sets: 3, rest: 30, category: .core),
                t("timed.plank", "Plank", hold: 60, sets: 3, rest: 45)]),
        Spec(key: "starter-climbing-core", name: "Climbing — Core for Climbers", sport: .climbing,
             level: .beginner, detail: "Climbing-specific core circuit emphasizing tension and hip drive.",
             tags: ["core"], sourceLabel: "General climbing canon", sourceURL: nil, blocks: [
                s("Hanging_Leg_Raise", 3, "8", 60), s("Hanging_Pike", 3, "8", 60),
                t("timed.plank", "Plank", hold: 45, sets: 3, rest: 30),
                t("timed.side-bridge", "Side bridge", hold: 30, sets: 3, rest: 30, category: .core),
                s("Russian_Twist", 3, "20", 30), s("Dead_Bug", 3, "10 each side", 30)]),
        Spec(key: "starter-calisthenics-starting-strength", name: "Calisthenics — Starting Strength",
             sport: .calisthenics, level: .beginner,
             detail: "Recommended-Routine-style full-body template for new lifters.",
             tags: ["full-body", "strength"], sourceLabel: "r/bodyweightfitness Recommended Routine",
             sourceURL: "https://www.reddit.com/r/bodyweightfitness/wiki/kb/recommended_routine", blocks: [
                s("Bodyweight_Squat", 3, "12", 90), s("Pushups", 3, "8", 90),
                s("Inverted_Row", 3, "8", 90), s("Glute_Ham_Raise", 3, "5", 90),
                t("timed.plank", "Plank", hold: 30, sets: 3, rest: 30), s("Hanging_Leg_Raise", 3, "6", 60)]),
        Spec(key: "starter-calisthenics-push", name: "Calisthenics — Push Strength", sport: .calisthenics,
             level: .intermediate, detail: "Pressing volume + variation for chest, shoulders, and triceps.",
             tags: ["push", "strength"], sourceLabel: "GMB Elements", sourceURL: "https://gmb.io/elements/", blocks: [
                s("Pushups", 4, "8-12", 90), s("Decline_Push-Up", 4, "8", 120),
                s("Close-Grip_Push-Up_off_of_a_Dumbbell", 3, "8", 90), s("Bench_Dips", 3, "10", 60),
                s("Handstand_Push-Ups", 3, "3-5", 120)]),
        Spec(key: "starter-calisthenics-pull", name: "Calisthenics — Pull Strength", sport: .calisthenics,
             level: .intermediate, detail: "Heavy bar work: pull-ups, chin-ups, rows.",
             tags: ["pull", "strength"], sourceLabel: "r/bodyweightfitness Move",
             sourceURL: "https://www.reddit.com/r/bodyweightfitness/", blocks: [
                s("Scapular_Pull-Up", 3, "5", 60), s("Pullups", 5, "5", 180),
                s("Chin-Up", 4, "6", 120), s("Inverted_Row", 3, "8", 90),
                s("Hanging_Leg_Raise", 3, "8", 60)]),
        Spec(key: "starter-calisthenics-lower", name: "Calisthenics — Single-Leg & Lower",
             sport: .calisthenics, level: .intermediate,
             detail: "Unilateral lower-body work for balanced strength and mobility.",
             tags: ["legs", "unilateral"], sourceLabel: "Convict Conditioning progressions", sourceURL: nil, blocks: [
                s("Bodyweight_Squat", 3, "15", 60), s("Kettlebell_Pistol_Squat", 4, "5 each leg", 90),
                s("Dumbbell_Lunges", 3, "10 each leg", 60), s("Single_Leg_Glute_Bridge", 3, "10 each side", 45),
                s("Standing_Calf_Raises", 3, "15", 30)]),
        Spec(key: "starter-calisthenics-skill", name: "Calisthenics — Skill & Conditioning",
             sport: .calisthenics, level: .advanced, detail: "High-skill work plus a conditioning finisher.",
             tags: ["skill", "conditioning"], sourceLabel: "GMB Foundations", sourceURL: "https://gmb.io/foundations/",
             blocks: [
                s("Handstand_Push-Ups", 4, "3", 120), s("One_Arm_Chin-Up", 3, "3 each arm", 180),
                s("Hanging_Pike", 3, "8", 90), s("Pushups", 3, "max", 60),
                t("timed.mountain-climbers", "Mountain climbers", hold: 30, sets: 3, rest: 30, category: .core)]),
    ]

    private static func routine(from spec: Spec) -> Routine {
        Routine(
            name: spec.name,
            exercises: spec.blocks.map { $0.routineExercise },
            // Seed all starters at a fixed early date so they sort before user routines.
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            isStarter: true, starterKey: spec.key, sport: spec.sport, level: spec.level,
            tags: spec.tags, detail: spec.detail, sourceLabel: spec.sourceLabel, sourceURL: spec.sourceURL
        )
    }

    /// Insert any starter not already present (by `starterKey`) and not previously dismissed.
    /// Safe to call on every appearance — it no-ops once everything is seeded.
    @MainActor
    static func seedIfNeeded(context: ModelContext, existing: [Routine], dismissed: Set<String>) {
        let presentKeys = Set(existing.compactMap(\.starterKey))
        var inserted = false
        for spec in all where !presentKeys.contains(spec.key) && !dismissed.contains(spec.key) {
            context.insert(routine(from: spec))
            inserted = true
        }
        if inserted { try? context.save() }
    }
}
