import Foundation
import SwiftData

/// The 15 starter routines shipped with the app (ported verbatim from the web app's
/// `starters.ts`). They are seeded into the SwiftData store on first launch so users have
/// something to do immediately. Deleting a starter records its key in `dismissedStarters`
/// so it is not re-seeded.
enum StarterRoutines {
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
        let exercises: [(id: String, sets: Int, reps: String, rest: Int)]
    }

    static let all: [Spec] = [
        Spec(key: "starter-beginner-full-body", name: "Beginner Full Body", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, exercises: [
                ("Bodyweight_Squat", 3, "12", 60), ("Pushups", 3, "10", 60),
                ("Inverted_Row", 3, "10", 60), ("Plank", 3, "30s", 45),
                ("Butt_Lift_Bridge", 3, "12", 45)]),
        Spec(key: "starter-upper-body-push", name: "Upper Body Push", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, exercises: [
                ("Pushups", 4, "8-12", 90), ("Dumbbell_Shoulder_Press", 4, "8-10", 90),
                ("Bench_Dips", 3, "10", 60), ("Side_Lateral_Raise", 3, "12", 45)]),
        Spec(key: "starter-upper-body-pull", name: "Upper Body Pull", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, exercises: [
                ("Pullups", 4, "6-10", 90), ("Dumbbell_Bicep_Curl", 3, "12", 60),
                ("Face_Pull", 3, "15", 45)]),
        Spec(key: "starter-lower-body", name: "Lower Body", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, exercises: [
                ("Goblet_Squat", 4, "10", 90), ("Dumbbell_Lunges", 3, "10 each leg", 60),
                ("Romanian_Deadlift", 3, "8-10", 90), ("Standing_Calf_Raises", 3, "15", 30)]),
        Spec(key: "starter-core-crusher", name: "Core Crusher", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, exercises: [
                ("Plank", 3, "45s", 45), ("Russian_Twist", 3, "20", 30),
                ("Dead_Bug", 3, "10 each side", 30), ("Flat_Bench_Lying_Leg_Raise", 3, "12", 45)]),
        Spec(key: "starter-mobility", name: "5-Minute Mobility", sport: .general, level: nil,
             detail: nil, tags: [], sourceLabel: nil, sourceURL: nil, exercises: [
                ("Cat_Stretch", 1, "60s", 0), ("Worlds_Greatest_Stretch", 1, "30s each side", 0),
                ("Hamstring_Stretch", 1, "30s each leg", 0), ("Arm_Circles", 1, "60s", 0)]),
        Spec(key: "starter-climbing-max-pull", name: "Climbing — Max Pulling Strength", sport: .climbing,
             level: .intermediate, detail: "Heavy pulling work to raise your ceiling for hard climbing moves.",
             tags: ["pull", "strength"], sourceLabel: "Hörst, Training for Climbing", sourceURL: nil, exercises: [
                ("Scapular_Pull-Up", 3, "5", 60), ("Pullups", 5, "5", 180),
                ("Chin-Up", 4, "6", 120), ("Inverted_Row", 3, "8", 90),
                ("Hanging_Leg_Raise", 3, "8", 60)]),
        Spec(key: "starter-climbing-antagonist", name: "Climbing — Antagonist & Recovery", sport: .climbing,
             level: .beginner, detail: "Balance pulling-heavy climbing with pressing + forearm health.",
             tags: ["antagonist", "mobility", "recovery"], sourceLabel: "Lattice Training blog",
             sourceURL: "https://latticetraining.com/blog/", exercises: [
                ("Pushups", 3, "12", 60), ("Bench_Dips", 3, "10", 60),
                ("Handstand_Push-Ups", 3, "5", 90), ("Finger_Curls", 3, "15", 45),
                ("Kneeling_Forearm_Stretch", 1, "60s each side", 0),
                ("Worlds_Greatest_Stretch", 1, "30s each side", 0), ("Childs_Pose", 1, "60s", 0)]),
        Spec(key: "starter-climbing-power-endurance", name: "Climbing — Power Endurance", sport: .climbing,
             level: .intermediate, detail: "Sustain pulling power across longer sequences.",
             tags: ["endurance", "pull"], sourceLabel: "Bechtel, Logical Progression", sourceURL: nil, exercises: [
                ("Pullups", 3, "max-2", 180), ("Bent_Over_Two-Dumbbell_Row", 3, "10", 90),
                ("Hanging_Pike", 3, "8", 60), ("Mountain_Climbers", 3, "30s", 30),
                ("Plank", 3, "60s", 45)]),
        Spec(key: "starter-climbing-core", name: "Climbing — Core for Climbers", sport: .climbing,
             level: .beginner, detail: "Climbing-specific core circuit emphasizing tension and hip drive.",
             tags: ["core"], sourceLabel: "General climbing canon", sourceURL: nil, exercises: [
                ("Hanging_Leg_Raise", 3, "8", 60), ("Hanging_Pike", 3, "8", 60),
                ("Plank", 3, "45s", 30), ("Side_Bridge", 3, "30s each side", 30),
                ("Russian_Twist", 3, "20", 30), ("Dead_Bug", 3, "10 each side", 30)]),
        Spec(key: "starter-calisthenics-starting-strength", name: "Calisthenics — Starting Strength",
             sport: .calisthenics, level: .beginner,
             detail: "Recommended-Routine-style full-body template for new lifters.",
             tags: ["full-body", "strength"], sourceLabel: "r/bodyweightfitness Recommended Routine",
             sourceURL: "https://www.reddit.com/r/bodyweightfitness/wiki/kb/recommended_routine", exercises: [
                ("Bodyweight_Squat", 3, "12", 90), ("Pushups", 3, "8", 90),
                ("Inverted_Row", 3, "8", 90), ("Glute_Ham_Raise", 3, "5", 90),
                ("Plank", 3, "30s", 30), ("Hanging_Leg_Raise", 3, "6", 60)]),
        Spec(key: "starter-calisthenics-push", name: "Calisthenics — Push Strength", sport: .calisthenics,
             level: .intermediate, detail: "Pressing volume + variation for chest, shoulders, and triceps.",
             tags: ["push", "strength"], sourceLabel: "GMB Elements", sourceURL: "https://gmb.io/elements/", exercises: [
                ("Pushups", 4, "8-12", 90), ("Decline_Push-Up", 4, "8", 120),
                ("Close-Grip_Push-Up_off_of_a_Dumbbell", 3, "8", 90), ("Bench_Dips", 3, "10", 60),
                ("Handstand_Push-Ups", 3, "3-5", 120)]),
        Spec(key: "starter-calisthenics-pull", name: "Calisthenics — Pull Strength", sport: .calisthenics,
             level: .intermediate, detail: "Heavy bar work: pull-ups, chin-ups, rows.",
             tags: ["pull", "strength"], sourceLabel: "r/bodyweightfitness Move",
             sourceURL: "https://www.reddit.com/r/bodyweightfitness/", exercises: [
                ("Scapular_Pull-Up", 3, "5", 60), ("Pullups", 5, "5", 180),
                ("Chin-Up", 4, "6", 120), ("Inverted_Row", 3, "8", 90),
                ("Hanging_Leg_Raise", 3, "8", 60)]),
        Spec(key: "starter-calisthenics-lower", name: "Calisthenics — Single-Leg & Lower",
             sport: .calisthenics, level: .intermediate,
             detail: "Unilateral lower-body work for balanced strength and mobility.",
             tags: ["legs", "unilateral"], sourceLabel: "Convict Conditioning progressions", sourceURL: nil, exercises: [
                ("Bodyweight_Squat", 3, "15", 60), ("Kettlebell_Pistol_Squat", 4, "5 each leg", 90),
                ("Dumbbell_Lunges", 3, "10 each leg", 60), ("Single_Leg_Glute_Bridge", 3, "10 each side", 45),
                ("Standing_Calf_Raises", 3, "15", 30)]),
        Spec(key: "starter-calisthenics-skill", name: "Calisthenics — Skill & Conditioning",
             sport: .calisthenics, level: .advanced, detail: "High-skill work plus a conditioning finisher.",
             tags: ["skill", "conditioning"], sourceLabel: "GMB Foundations", sourceURL: "https://gmb.io/foundations/",
             exercises: [
                ("Handstand_Push-Ups", 4, "3", 120), ("One_Arm_Chin-Up", 3, "3 each arm", 180),
                ("Hanging_Pike", 3, "8", 90), ("Pushups", 3, "max", 60),
                ("Mountain_Climbers", 3, "30s", 30)]),
    ]

    private static func routine(from spec: Spec) -> Routine {
        Routine(
            name: spec.name,
            exercises: spec.exercises.map {
                RoutineExercise(exerciseId: $0.id, sets: $0.sets, reps: $0.reps, restSeconds: $0.rest)
            },
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
