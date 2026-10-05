import Foundation

/// When chores are due (household prompt 01). Pure: the board hands it rounds and a clock.
///
/// - **daily**: a round per day.
/// - **weekdays**: a round on each listed weekday. Which days count is `HabitSchedule`'s rule, so
///   "due" means the same thing in Habits and here.
/// - **weekly**: a round per calendar week, due all week until it's done.
/// - **afterDone(n)**: due `n` days after the latest completion by anyone (each tick re-anchors it).
///   A round runs from its first tick until that first tick's due date, so two people doing the
///   fridge while apart is one round, both credited.
/// - **once**: one round ever.
enum ChoreSchedule {
    static func sameRound(_ first: Date, _ other: Date, repeats: ChoreRepeat, calendar: Calendar) -> Bool {
        switch repeats {
        case .daily, .weekdays:
            return calendar.isDate(first, inSameDayAs: other)
        case .weekly:
            return weekKey(first, calendar: calendar) == weekKey(other, calendar: calendar)
        case .afterDone(let days):
            return DayKey(other, calendar: calendar) < DayKey(first, calendar: calendar).adding(days: days, calendar: calendar)
        case .once:
            return true
        }
    }

    /// `rounds` = this chore's rounds, oldest first; `latest` = its most recent completion.
    /// `isPaused`: days the house was on holiday (household prompt 03), which never count as overdue.
    static func status(repeats: ChoreRepeat, rounds: [ChoreRound], latest: Date?, now: Date,
                       calendar: Calendar, isPaused: ((DayKey) -> Bool)? = nil) -> ChoreStatus {
        let today = DayKey(now, calendar: calendar)
        let last = rounds.last
        let lastIsToday = last.map { r in r.completions.contains { DayKey($0.at, calendar: calendar) == today } } ?? false

        switch repeats {
        case .daily:
            if let last, DayKey(last.first.at, calendar: calendar) == today { return .done(last) }
            return .due(overdueDays: 0)

        case .weekdays(let days):
            if let last, DayKey(last.first.at, calendar: calendar) == today { return .done(last) }
            let schedule = HabitSchedule(weekdays: days)
            if schedule.isScheduled(today, calendar: calendar) { return .due(overdueDays: 0) }
            let next = (1...7).lazy.map { today.adding(days: $0, calendar: calendar) }
                .first { schedule.isScheduled($0, calendar: calendar) }
            return .notDue(next: next)

        case .weekly:
            if let last, weekKey(last.first.at, calendar: calendar) == weekKey(now, calendar: calendar) {
                return .done(last)
            }
            return .due(overdueDays: 0)

        case .afterDone(let days):
            guard let latest else { return .due(overdueDays: 0) }
            if let last, lastIsToday { return .done(last) }
            let dueDay = DayKey(latest, calendar: calendar).adding(days: days, calendar: calendar)
            if today < dueDay { return .notDue(next: dueDay) }
            var over = calendar.dateComponents([.day], from: dueDay.date(calendar: calendar),
                                               to: today.date(calendar: calendar)).day ?? 0
            if let isPaused, over > 0 {
                if isPaused(today) { return .due(overdueDays: 0) }
                over -= (0..<over).filter { isPaused(dueDay.adding(days: $0, calendar: calendar)) }.count
            }
            return .due(overdueDays: max(0, over))

        case .once:
            guard let last else { return .due(overdueDays: 0) }
            return lastIsToday ? .done(last) : .notDue(next: nil)
        }
    }

    /// The week's first day as `yyyy-MM-dd` (the house goal's key), in `calendar`'s week convention.
    static func weekKey(_ date: Date, calendar: Calendar = .current) -> String {
        let start = weekStart(date, calendar: calendar)
        let c = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// `yyyy-MM-dd` → a day; nil if malformed.
    static func day(fromKey key: String) -> DayKey? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DayKey(value: parts[0] * 10_000 + parts[1] * 100 + parts[2])
    }

    static func weekStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// "Daily", "Mon, Thu", "Weekly", "Every 14 days after it's done", "Once". `short` drops "after
    /// it's done" for list rows.
    static func summary(_ r: ChoreRepeat, short: Bool = false, calendar: Calendar = .current) -> String {
        switch r {
        case .daily: return "Daily"
        case .weekdays(let days):
            if days.isEmpty || days.count == 7 { return "Daily" }
            let symbols = calendar.shortWeekdaySymbols
            return days.sorted { weekdayOrder($0, calendar) < weekdayOrder($1, calendar) }
                .map { symbols[$0 - 1] }.joined(separator: ", ")
        case .weekly: return "Weekly"
        case .afterDone(let n):
            let every = n == 1 ? "Every day" : "Every \(n) days"
            return short ? every : every + " after it's done"
        case .once: return "Once"
        }
    }

    /// Position of a weekday in `calendar`'s week (so Monday-first locales list Monday first).
    static func weekdayOrder(_ weekday: Int, _ calendar: Calendar) -> Int {
        (weekday - calendar.firstWeekday + 7) % 7
    }
}
