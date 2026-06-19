import Foundation

/// Pure, device-free history signals for the Gym Tracker — the seam the **smart planner (E7)** will read.
/// Shipped in E0 as a small, tested skeleton ("no callers yet" first, like `StopwatchTiming`) with the two
/// always-derivable signals: per-discipline **recency** (last trained / days since) and training **cadence**
/// (median days between sessions). E7 extends this with per-**muscle** volume/recency by joining
/// `Exercise.primaryMuscles` at the I/O edge (`ExerciseResolver` is `@MainActor`, so the join happens in the
/// view and resolved value types are passed in — never SwiftData/UIKit in here). No SwiftUI, no device.
struct WorkoutHistoryStats: Equatable, Sendable {
    /// Days since each discipline was last the dominant discipline of a session (absent → never trained).
    var daysSinceByDiscipline: [WorkoutDiscipline: Int]
    /// The date each discipline was last trained (dominant), for "last: 2 days ago" copy.
    var lastTrainedByDiscipline: [WorkoutDiscipline: Date]
    /// Median whole-day gap between consecutive sessions (training cadence); `nil` with <2 sessions.
    var medianGapDays: Int?

    // MARK: - Per-muscle signals (E7 — the smart planner's freshness/volume input)
    /// Days since each muscle was last trained (a completed set whose exercise targets it), absent → never.
    /// The planner biases TOWARD the muscles with the most days since (the freshest). Joined at the I/O edge.
    var daysSinceByMuscle: [Muscle: Int]
    /// The date each muscle was last trained — for "legs: 3 days ago" copy.
    var lastTrainedByMuscle: [Muscle: Date]
    /// Rolling-7-day completed-set count per muscle (the volume signal; reps×weight is the strength axis but
    /// a per-set count is discipline-agnostic and never zero-divides). Tie-breaks freshness toward low volume.
    var weeklyVolumeByMuscle: [Muscle: Int]

    static let empty = WorkoutHistoryStats(daysSinceByDiscipline: [:], lastTrainedByDiscipline: [:],
                                           medianGapDays: nil, daysSinceByMuscle: [:],
                                           lastTrainedByMuscle: [:], weeklyVolumeByMuscle: [:])

    /// A device-free value snapshot of one session, resolved at the I/O edge: each completed set's muscles
    /// already joined in (the `@MainActor ExerciseResolver` join happens in the view, never here). The
    /// planner / per-muscle stats consume these so the math stays pure + unit-testable.
    struct ResolvedSession: Equatable, Sendable {
        var startedAt: Date
        /// One entry per **completed** set, carrying the primary muscles its exercise targets.
        var completedSets: [ResolvedSet]
    }

    struct ResolvedSet: Equatable, Sendable {
        var muscles: [Muscle]
        init(muscles: [Muscle]) { self.muscles = muscles }
    }

    /// Per-discipline recency + cadence only (the E0 seam — no muscle join needed). Kept so existing
    /// callers/tests are unchanged; muscle maps come back empty.
    static func make(history: [WorkoutSession], now: Date = .now, calendar: Calendar = .current) -> WorkoutHistoryStats {
        let disciplines = disciplineStats(history: history, now: now, calendar: calendar)
        return disciplines
    }

    /// The full E7 signal: per-discipline recency/cadence (from the raw sessions) **plus** per-muscle
    /// volume/recency (from the I/O-edge-resolved `ResolvedSession`s). `resolved` must mirror `history` (one
    /// per session) — the view builds both from the same `@Query` rows, joining `Exercise.primaryMuscles`.
    static func make(history: [WorkoutSession], resolved: [ResolvedSession],
                     now: Date = .now, calendar: Calendar = .current) -> WorkoutHistoryStats {
        var stats = disciplineStats(history: history, now: now, calendar: calendar)
        let muscle = muscleStats(resolved: resolved, now: now, calendar: calendar)
        stats.daysSinceByMuscle = muscle.daysSince
        stats.lastTrainedByMuscle = muscle.lastTrained
        stats.weeklyVolumeByMuscle = muscle.weeklyVolume
        return stats
    }

    // MARK: - Pieces

    private static func disciplineStats(history: [WorkoutSession], now: Date,
                                        calendar: Calendar) -> WorkoutHistoryStats {
        guard !history.isEmpty else { return .empty }
        let sorted = history.sorted { $0.startedAt > $1.startedAt }   // newest first

        // Last-trained per dominant discipline.
        var lastTrained: [WorkoutDiscipline: Date] = [:]
        for s in sorted {
            guard let d = WorkoutDashboardStats.dominantDiscipline(of: s) else { continue }
            if lastTrained[d] == nil { lastTrained[d] = s.startedAt }
        }
        let today = calendar.startOfDay(for: now)
        let daysSince = lastTrained.mapValues { date in
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        }

        // Median gap (days) between consecutive sessions, by calendar day.
        let days = sorted.map { calendar.startOfDay(for: $0.startedAt) }
        var gaps: [Int] = []
        for i in 1..<max(1, days.count) {
            let g = calendar.dateComponents([.day], from: days[i], to: days[i - 1]).day ?? 0
            if g > 0 { gaps.append(g) }
        }
        let median: Int? = gaps.isEmpty ? nil : gaps.sorted()[gaps.count / 2]

        return WorkoutHistoryStats(daysSinceByDiscipline: daysSince,
                                   lastTrainedByDiscipline: lastTrained, medianGapDays: median,
                                   daysSinceByMuscle: [:], lastTrainedByMuscle: [:], weeklyVolumeByMuscle: [:])
    }

    private static func muscleStats(resolved: [ResolvedSession], now: Date, calendar: Calendar)
        -> (daysSince: [Muscle: Int], lastTrained: [Muscle: Date], weeklyVolume: [Muscle: Int]) {
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var lastTrained: [Muscle: Date] = [:]
        var weeklyVolume: [Muscle: Int] = [:]
        for session in resolved {
            for set in session.completedSets {
                for m in set.muscles {
                    // Most-recent training date per muscle.
                    if let prev = lastTrained[m] { if session.startedAt > prev { lastTrained[m] = session.startedAt } }
                    else { lastTrained[m] = session.startedAt }
                    // Rolling-7-day completed-set count.
                    if session.startedAt >= weekAgo { weeklyVolume[m, default: 0] += 1 }
                }
            }
        }
        let daysSince = lastTrained.mapValues { date in
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        }
        return (daysSince, lastTrained, weeklyVolume)
    }
}
