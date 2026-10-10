import Foundation

// MARK: - Clips feed — what activity a post is (prompt 170, pure)
//
// The feed used to know only "Kilter session vs workout-tracker session": the Climbs chip matched Kilter
// board sessions only (missing Quick Session climbs, every climbing workout imported from Apple Health /
// Google Health, …) and "Gym" was a catch-all for everything else — runs, yoga, dance, hangboard, imported
// climbs, a festival night's untagged clips. A post now carries the ACTIVITY it actually was
// (`ClipFeedPost.Discipline`), resolved here from the best evidence available, in order:
//
//   1. festival-tagged set, or any clip from a festival night → festival
//   2. a Kilter board session                                  → climbing
//   3. a clip tagged to an exercise → that exercise's discipline (climb → climbing · strength → strength ·
//      run → cardio · dance → dance · timed → strength — hangboard included, the user's call · other → other)
//   4. untagged clips / reels → the SESSION's activity: an Apple Health import by its workout type label
//      (the importer's own closed label set, `HealthKitService.label`), a tracked session by its most common
//      exercise activity.
//
// Pure — unit-tested in `ClipActivityTests`.

enum ClipActivity {

    typealias Activity = ClipFeedPost.Discipline

    /// Display order for the chips (only activities that have posts are shown).
    static let chipOrder: [Activity] = [.climbing, .strength, .cardio, .dance, .mobility, .festival, .general]

    /// One tracked exercise → its activity. `timed` (holds, hangboard, core) counts as strength.
    static func forExercise(_ discipline: WorkoutDiscipline) -> Activity {
        switch discipline {
        case .climb: return .climbing
        case .strength, .timed: return .strength
        case .run: return .cardio
        case .dance: return .dance
        case .other: return .general
        }
    }

    /// An Apple Health import → its activity, from the label the importer stored as the session name
    /// (`HealthKitService.label(_:)` — a closed set this table mirrors; unknown → other).
    static func forImportLabel(_ label: String) -> Activity {
        switch label {
        case "Climbing": return .climbing
        case "Strength Training", "Functional Strength", "Core Training", "Kickboxing", "Boxing": return .strength
        case "Run", "Walk", "Hike", "Cycling", "Swim", "Rowing", "Elliptical", "HIIT", "Cardio",
             "Jump Rope", "Stairs": return .cardio
        case "Dance", "Barre": return .dance
        case "Yoga", "Pilates", "Flexibility", "Cooldown": return .mobility
        default: return .general
        }
    }

    /// A tracked session → its most common exercise activity (ties → `chipOrder` order); none → other.
    static func dominant(_ activities: [Activity]) -> Activity {
        let counts = Dictionary(activities.map { ($0, 1) }, uniquingKeysWith: +)
        guard let best = counts.values.max() else { return .general }
        return chipOrder.first { counts[$0] == best } ?? .general
    }

    /// The activities present in `posts`, in chip order — the chips the strip shows.
    static func present(in posts: [ClipFeedPost]) -> [Activity] {
        let have = Set(posts.map(\.discipline))
        return chipOrder.filter(have.contains)
    }
}

extension ClipFeedPost.Discipline {
    /// Chip / header / search label.
    var label: String {
        switch self {
        case .climbing: return "Climbing"
        case .strength: return "Strength"
        case .cardio: return "Cardio"
        case .dance: return "Dance"
        case .mobility: return "Mobility"
        case .festival: return "Festival"
        case .general: return "Other"
        }
    }

    /// SF Symbol for the chip, the post's avatar and the session header.
    var symbol: String {
        switch self {
        case .climbing: return "figure.climbing"
        case .strength: return "figure.strengthtraining.traditional"
        case .cardio: return "figure.run"
        case .dance: return "figure.dance"
        case .mobility: return "figure.mind.and.body"
        case .festival: return "music.mic"
        case .general: return "sparkles"
        }
    }
}
