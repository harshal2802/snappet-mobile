import Foundation

/// Helpers for scoping budget math to the *current calendar month*. Centralised so the
/// summary, per-category rows, and chart all agree on what "this month" means.
enum MonthScope {
    /// Start of the current calendar month (e.g. May 1, 00:00).
    static func start(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    /// Exclusive upper bound — start of next month.
    static func end(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: now)?.end ?? now
    }

    /// True if `date` falls within the current calendar month.
    static func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        date >= start(now: now, calendar: calendar) && date < end(now: now, calendar: calendar)
    }
}

extension Double {
    /// Formats a money amount in the user's local currency.
    var asCurrency: String {
        formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }
}
