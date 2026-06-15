import Foundation

/// Builds the home-screen widgets' Today snapshot from the same SwiftData rows Home/Habit query
/// (#81 Phase 1). **Pure** — no SwiftData fetches, no clock/calendar reads (the caller injects
/// `now` + `calendar`) — so it's deterministic and unit-tested in `SnappetTests` with no device.
/// Reuses `TodayDigest` + `HabitMilestones.streak` so the widget can't drift from what the app shows.
enum WidgetSnapshotBuilder {
    static func build(habits: [Habit], completions: [HabitCompletion],
                      focusSessions: [PomodoroSession],
                      now: Date = Date(), calendar: Calendar = .current) -> SnappetWidgetSnapshot {
        let dayStart = calendar.startOfDay(for: now)

        // Completion day-sets per habit, normalised to start-of-day, built once and reused for both
        // the per-item "done today" flag and the streak math (mirrors TodayDigest/HabitMilestones).
        var daysByHabit: [UUID: Set<Date>] = [:]
        for c in completions {
            daysByHabit[c.habitID, default: []].insert(calendar.startOfDay(for: c.day))
        }

        let items = habits.map { h in
            SnappetWidgetSnapshot.HabitItem(
                id: h.id, name: h.name, symbol: h.symbol,
                doneToday: daysByHabit[h.id]?.contains(dayStart) ?? false)
        }

        // Best CURRENT streak across habits — the flame value the Habit screen already shows.
        let dayStreak = habits.reduce(0) { best, h in
            max(best, HabitMilestones.streak(days: daysByHabit[h.id] ?? [],
                                             today: now, calendar: calendar))
        }

        let focus = TodayDigest.focusToday(sessions: focusSessions, now: now, calendar: calendar)?
            .minutesToday ?? 0

        return SnappetWidgetSnapshot(
            generatedAt: now, dayStart: dayStart,
            habits: items, dayStreak: dayStreak, focusMinutesToday: focus)
    }
}
