import Foundation

/// Builds the home-screen widgets' Today snapshot from the same SwiftData rows the app's own
/// screens query (#81 Phase 1). **Pure** — no SwiftData fetches, no clock/calendar reads (the caller
/// injects `now` + `calendar`) — so it's deterministic and unit-tested in `SnappetTests` with no
/// device. Every fact routes through a shared pure derivation so the widget can't show a number that
/// disagrees with the app: `dayStreak` via `TodayDigest.activityStreak` (the exact suite-engagement
/// streak the Home dashboard's StatTile shows), focus minutes via `TodayDigest.focusToday`, and
/// "habits remaining" via the same start-of-day "done today" rule as `TodayDigest.habitsToday`.
enum WidgetSnapshotBuilder {
    static func build(records: [UsageRecord], habits: [Habit], completions: [HabitCompletion],
                      focusSessions: [PomodoroSession],
                      now: Date = Date(), calendar: Calendar = .current) -> SnappetWidgetSnapshot {
        let dayStart = calendar.startOfDay(for: now)

        // "Done today" by the same start-of-day rule as TodayDigest.habitsToday.
        let doneToday = Set(completions.lazy
            .filter { calendar.startOfDay(for: $0.day) == dayStart }
            .map(\.habitID))
        let items = habits.map { h in
            SnappetWidgetSnapshot.HabitItem(
                id: h.id, name: h.name, symbol: h.symbol, doneToday: doneToday.contains(h.id))
        }

        // The Home dashboard's "day streak": consecutive days ending today with any logged action —
        // shared with HomeDashboardView via TodayDigest.activityStreak so the two can't diverge.
        let dayStreak = TodayDigest.activityStreak(records: records, now: now, calendar: calendar)

        let focus = TodayDigest.focusToday(sessions: focusSessions, now: now, calendar: calendar)?
            .minutesToday ?? 0

        return SnappetWidgetSnapshot(
            generatedAt: now, dayStart: dayStart,
            habits: items, dayStreak: dayStreak, focusMinutesToday: focus)
    }
}
