import Foundation

/// A date window History can be opened on (prompt 212): Home's "This week" card and each day's bar open History
/// narrowed to that week / day, shown as a removable chip like the other filters. Pure + unit-tested.
struct HistoryDateRange: Equatable, Hashable, Sendable {
    var start: Date
    var end: Date
    var label: String

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// The calendar week containing `date` ("This week" when it's the current one).
    static func week(containing date: Date, now: Date = .now, calendar: Calendar = .current) -> HistoryDateRange {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86_400)
        let current = calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        let label = current ? "This week"
            : "Week of " + interval.start.formatted(.dateTime.day().month(.abbreviated))
        return HistoryDateRange(start: interval.start, end: interval.end, label: label)
    }

    /// One day ("Today", "Mon 26 Oct").
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> HistoryDateRange {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let label = calendar.isDate(date, inSameDayAs: now) ? "Today"
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return HistoryDateRange(start: start, end: end, label: label)
    }
}
