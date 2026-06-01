import Foundation

/// A single calendar month, anchored by any `Date` inside it. Centralises what "a month"
/// means so the summary, per-category rows, donut, and trends chart all agree.
///
/// Originally `MonthScope` only described the *current* month (`.now`); it now describes an
/// **arbitrary selected month** so the UI can step backwards/forwards. The current month is
/// just `MonthScope()` (see `pdd/context/decisions.md`).
struct MonthScope: Equatable, Sendable {
    /// Start of the month (e.g. May 1, 00:00) — the canonical anchor we store.
    let start: Date
    private let calendar: Calendar

    /// Builds the month that contains `anchor` (defaults to the current month).
    init(anchor: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        self.start = calendar.dateInterval(of: .month, for: anchor)?.start
            ?? calendar.startOfDay(for: anchor)
    }

    /// Exclusive upper bound — the start of the next month.
    var end: Date {
        calendar.dateInterval(of: .month, for: start)?.end
            ?? calendar.date(byAdding: .month, value: 1, to: start)
            ?? start
    }

    /// True if `date` falls within this month.
    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// The month immediately before this one.
    func previous() -> MonthScope {
        let anchor = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        return MonthScope(anchor: anchor, calendar: calendar)
    }

    /// The month immediately after this one.
    func next() -> MonthScope {
        let anchor = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return MonthScope(anchor: anchor, calendar: calendar)
    }

    /// True if this is the current calendar month (used to cap forward navigation).
    var isCurrent: Bool { contains(.now) }

    /// A short label for the month header, e.g. "May 2026".
    var label: String {
        start.formatted(.dateTime.month(.wide).year())
    }

    static func == (lhs: MonthScope, rhs: MonthScope) -> Bool {
        lhs.start == rhs.start
    }
}

extension Double {
    /// Formats a money amount in the user's local currency.
    var asCurrency: String {
        formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }
}
