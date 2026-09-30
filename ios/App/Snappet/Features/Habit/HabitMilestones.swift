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
        streak(days: days, today: today, schedule: .everyDay, calendar: calendar)
    }

    /// Streak over the habit's **due** days only (prompt 137): walking back from today, a done day counts,
    /// a day that wasn't due (off the schedule, or an excused skip) is neutral, and the first due day that
    /// wasn't done ends it. Today is always neutral until it's over. For an every-day habit this is exactly
    /// the classic "consecutive days" streak. A done off-schedule day still counts (you trained anyway).
    static func streak(days: Set<Date>, today: Date, schedule: HabitSchedule,
                       calendar: Calendar = .current) -> Int {
        let done = Set(days.map { DayKey($0, calendar: calendar) })
        guard let earliest = done.min() else { return 0 }
        let todayKey = DayKey(today, calendar: calendar)
        var day = todayKey
        var count = 0
        var guardSteps = 3_700   // ~10 years of neutral days is plenty
        while day >= earliest, guardSteps > 0 {
            if done.contains(day) {
                count += 1
            } else if day != todayKey, schedule.isDue(day, calendar: calendar) {
                break
            }
            day = day.adding(days: -1, calendar: calendar)
            guardSteps -= 1
        }
        return count
    }

    /// Share of due days done over the trailing window (30 days, or since creation if newer). Off-schedule
    /// completions count toward "done" but the rate is capped at 100%. Today only counts once it's done —
    /// like the streak, an unfinished today isn't a miss (so a new habit doesn't open at 0%). A window
    /// with nothing due reads 100% if anything was done, else 0%.
    static func completionRate(days: Set<Date>, createdAt: Date, today: Date, schedule: HabitSchedule = .everyDay,
                               window: Int = 30, calendar: Calendar = .current) -> Double {
        let todayKey = DayKey(today, calendar: calendar)
        let created = DayKey(createdAt, calendar: calendar)
        let done = Set(days.map { DayKey($0, calendar: calendar) })
        var due = 0, hit = 0
        var day = todayKey
        for _ in 0..<max(1, window) {
            guard day >= created else { break }
            let isDone = done.contains(day)
            if schedule.isDue(day, calendar: calendar), day != todayKey || isDone { due += 1 }
            if isDone { hit += 1 }
            day = day.adding(days: -1, calendar: calendar)
        }
        guard due > 0 else { return hit > 0 ? 1 : 0 }
        return min(1, Double(hit) / Double(due))
    }

    /// The highest milestone newly reached by going from `previousStreak` to
    /// `newStreak`, or `nil` when none was crossed. A backfill can jump several days at
    /// once, so the whole range is checked — and only the highest fires (one burst).
    static func crossed(previousStreak: Int, newStreak: Int) -> Int? {
        milestones.last { $0 > previousStreak && $0 <= newStreak }
    }
}
