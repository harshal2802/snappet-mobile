import Foundation

/// Which days a habit is due (prompt 137) — the one definition behind the streak, the 30-day rate, the
/// Habits week strip, Home's "habits left today" and the Today widget. Pure values so it's unit-tested.
///
/// - Linked to scheduled routine(s) → due whenever any of them is planned (their skips are the habit's
///   own `skippedDayKeys`, recorded when "Skip today" is tapped).
/// - Otherwise its own weekdays, or every day.
struct HabitSchedule: Sendable {
    /// `Calendar` weekdays; nil = every day. Ignored when linked.
    var weekdays: Set<Int>?
    /// Schedules of the routines linked to this habit. Non-empty ⇒ the habit is "linked".
    var routineSchedules: [RoutineSchedule] = []
    /// Skipped days that don't count against the streak (empty when skips break it).
    var excused: Set<DayKey> = []

    static let everyDay = HabitSchedule(weekdays: nil)

    var isLinked: Bool { !routineSchedules.isEmpty }
    var isEveryDay: Bool { !isLinked && (weekdays?.isEmpty ?? true) }

    func isScheduled(_ day: DayKey, calendar: Calendar = .current) -> Bool {
        if isLinked {
            return routineSchedules.contains { $0.isEnabled && $0.occurs(on: day, calendar: calendar) }
        }
        guard let weekdays, !weekdays.isEmpty else { return true }
        return weekdays.contains(calendar.component(.weekday, from: day.date(calendar: calendar)))
    }

    func isDue(_ day: DayKey, calendar: Calendar = .current) -> Bool {
        isScheduled(day, calendar: calendar) && !excused.contains(day)
    }

    /// From stored values. `linked` = the schedules of routines whose `linkedHabitID` is this habit.
    static func resolve(weekdays: [Int]?, skippedDayKeys: [Int]?, skipsBreakStreak: Bool?,
                        linked: [RoutineSchedule]) -> HabitSchedule {
        let days = Set((weekdays ?? []).filter { (1...7).contains($0) })
        return HabitSchedule(
            weekdays: days.isEmpty || days.count == 7 ? nil : days,
            routineSchedules: linked,
            excused: skipsBreakStreak == true ? [] : Set((skippedDayKeys ?? []).map(DayKey.init(value:))))
    }
}

extension HabitSchedule {
    /// From the models: this habit + every routine in the store (the linked ones are picked out here).
    @MainActor
    static func resolve(_ habit: Habit, routines: [Routine]) -> HabitSchedule {
        resolve(weekdays: habit.weekdays, skippedDayKeys: habit.skippedDayKeys,
                skipsBreakStreak: habit.skipsBreakStreak,
                linked: routines.filter { $0.linkedHabitID == habit.id }.compactMap(\.schedule))
    }

    /// Habit ids due today — what Home and the Today widget count as "left to do".
    @MainActor
    static func dueToday(habits: [Habit], routines: [Routine], now: Date, calendar: Calendar = .current) -> Set<UUID> {
        let today = DayKey(now, calendar: calendar)
        return Set(habits.filter { resolve($0, routines: routines).isDue(today, calendar: calendar) }.map(\.id))
    }
}
