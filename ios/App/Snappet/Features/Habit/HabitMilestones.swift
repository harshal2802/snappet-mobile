import Foundation

/// Pure streak + milestone math for the Habit mini-app (issue #80), extracted from the
/// view so both the list UI and the toggle-time celebration decision share one
/// definition — and so the truth table runs in `SnappetTests` without a simulator.
enum HabitMilestones {

    /// The streaks worth celebrating, ascending.
    static let milestones = [7, 30, 100]

    /// Current streak = consecutive completed days ending today — or ending *yesterday*
    /// (a streak stays alive until a full day is missed). `days` are start-of-day dates.
    static func streak(days: Set<Date>, today: Date, calendar: Calendar = .current) -> Int {
        guard !days.isEmpty else { return 0 }
        let todayStart = calendar.startOfDay(for: today)
        var cursor = days.contains(todayStart)
            ? todayStart
            : calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        guard days.contains(cursor) else { return 0 }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// The highest milestone newly reached by going from `previousStreak` to
    /// `newStreak`, or `nil` when none was crossed. A backfill can jump several days at
    /// once, so the whole range is checked — and only the highest fires (one burst).
    static func crossed(previousStreak: Int, newStreak: Int) -> Int? {
        milestones.last { $0 > previousStreak && $0 <= newStreak }
    }
}
