import Foundation

/// Pure, device-free dashboard aggregates for the Gym Tracker (workout-redesign E0). Replaces the inline
/// streak / this-week / volume math that lived in `WorkoutDashboardSection` (a 4th coexisting streak
/// definition) so the figures are unit-tested in `SnappetTests` with no simulator, and — unlike the old
/// reps×weight-only math — are **discipline-aware** (a climbing/running/timed session counts, instead of
/// contributing 0). No SwiftUI, no SwiftData; consumes `[WorkoutSession]` value reads only.
struct WorkoutDashboardStats: Equatable, Sendable {
    var totalSessions: Int
    /// Sessions started since the start of the current week-of-year.
    var thisWeekCount: Int
    /// Distinct calendar days with ≥1 session this week (the hero "active days" numerator).
    var weeklyActiveDays: Int
    /// Which week the volume card features: this week once it has volume, else last week (so a fresh
    /// Sunday doesn't read "0 lb" over an all-grey chart, prompt 217). `weeks` are (week start, kg).
    static func volumeFocus(_ weeks: [(Date, Double)], now: Date = .now,
                            calendar: Calendar = .current) -> (weekStart: Date, volumeKg: Double, label: String)? {
        guard let thisStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return nil }
        let byStart = Dictionary(weeks.map { ($0.0, $0.1) }, uniquingKeysWith: +)
        if let v = byStart[thisStart], v > 0 { return (thisStart, v, "this week") }
        guard let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisStart) else { return nil }
        return (lastStart, byStart[lastStart] ?? 0, "last week")
    }

    /// Consecutive calendar days ending today (or yesterday) with ≥1 session.
    var currentStreak: Int
    /// This week's sessions grouped by dominant discipline (nonzero only; sorted count-desc, then the
    /// fixed discipline order). Drives the per-discipline ribbon ("2 lifts · 5 climbs · 1 run").
    var disciplineCounts: [DisciplineCount]
    /// The most frequent dominant discipline across the most recent sessions — drives the type-aware
    /// Start CTA ("Start climbing"); `nil` on a fresh install.
    var dominantRecentDiscipline: WorkoutDiscipline?

    struct DisciplineCount: Equatable, Sendable, Identifiable {
        var discipline: WorkoutDiscipline
        var count: Int
        var id: String { discipline.rawValue }
    }

    static let empty = WorkoutDashboardStats(totalSessions: 0, thisWeekCount: 0, weeklyActiveDays: 0,
                                             currentStreak: 0, disciplineCounts: [], dominantRecentDiscipline: nil)

    /// The dominant discipline of a session = the `WorkoutDiscipline` with the most **completed** efforts;
    /// `nil` when nothing is logged. Counting by `discipline` keeps legacy/guided (reps×weight) sessions as
    /// `.strength`. Ties resolve in a fixed order (strength → climb → run → timed → dance → other).
    /// Every discipline, in tie-break / display order. Racket was missing (prompt 217 fix): racket
    /// matches and drills had no dominant discipline, so the Dashboard dropped them from Recent sessions
    /// and the week's counts.
    static let displayOrder: [WorkoutDiscipline] = [.strength, .climb, .run, .timed, .racket, .dance, .other]

    static func dominantDiscipline(of session: WorkoutSession) -> WorkoutDiscipline? {
        var counts: [WorkoutDiscipline: Int] = [:]
        for ex in session.exercises {
            for set in ex.sets where set.completedAt != nil {
                counts[ex.discipline, default: 0] += 1
            }
        }
        var best: (WorkoutDiscipline, Int)? = nil
        for d in displayOrder {
            let c = counts[d] ?? 0
            if c > 0, c > (best?.1 ?? 0) { best = (d, c) }
        }
        return best?.0
    }

    static func make(history: [WorkoutSession], now: Date = .now,
                     calendar: Calendar = .current, recentWindow: Int = 10) -> WorkoutDashboardStats {
        guard !history.isEmpty else { return .empty }

        // This week (week-of-year start), mirroring the old WorkoutDashboardSection.thisWeekCount.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        let thisWeek = weekStart.map { ws in history.filter { $0.startedAt >= ws } } ?? []
        let weeklyActiveDays = Set(thisWeek.map { calendar.startOfDay(for: $0.startedAt) }).count

        // This week's sessions grouped by dominant discipline.
        var byDiscipline: [WorkoutDiscipline: Int] = [:]
        for s in thisWeek { if let d = dominantDiscipline(of: s) { byDiscipline[d, default: 0] += 1 } }
        let order = displayOrder
        let disciplineCounts = order.compactMap { d -> DisciplineCount? in
            guard let c = byDiscipline[d], c > 0 else { return nil }
            return DisciplineCount(discipline: d, count: c)
        }.sorted { ($0.count, order.firstIndex(of: $1.discipline)!) > ($1.count, order.firstIndex(of: $0.discipline)!) }

        // Most frequent dominant discipline across the most recent N sessions (recency-ordered input
        // assumed; we sort defensively) → the type-aware Start default.
        let recent = history.sorted { $0.startedAt > $1.startedAt }.prefix(recentWindow)
        var recentCounts: [WorkoutDiscipline: Int] = [:]
        for s in recent { if let d = dominantDiscipline(of: s) { recentCounts[d, default: 0] += 1 } }
        let dominantRecent = order.filter { (recentCounts[$0] ?? 0) > 0 }
            .max { (recentCounts[$0] ?? 0) < (recentCounts[$1] ?? 0) }

        return WorkoutDashboardStats(
            totalSessions: history.count,
            thisWeekCount: thisWeek.count,
            weeklyActiveDays: weeklyActiveDays,
            currentStreak: currentStreak(history: history, now: now, calendar: calendar),
            disciplineCounts: disciplineCounts,
            dominantRecentDiscipline: dominantRecent)
    }

    /// Consecutive calendar days ending today (or yesterday) with at least one session — the exact
    /// definition the old `WorkoutDashboardSection.currentStreak` used (parity-tested).
    static func currentStreak(history: [WorkoutSession], now: Date = .now,
                              calendar: Calendar = .current) -> Int {
        let days = Set(history.map { calendar.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
        var cursor = days.contains(today) ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        guard days.contains(cursor) else { return 0 }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }
}
