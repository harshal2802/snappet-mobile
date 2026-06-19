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

    static let empty = WorkoutHistoryStats(daysSinceByDiscipline: [:], lastTrainedByDiscipline: [:], medianGapDays: nil)

    static func make(history: [WorkoutSession], now: Date = .now, calendar: Calendar = .current) -> WorkoutHistoryStats {
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
                                   lastTrainedByDiscipline: lastTrained, medianGapDays: median)
    }
}
