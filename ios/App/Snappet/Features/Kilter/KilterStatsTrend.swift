import Foundation

/// Pure, device-free helpers behind the P3 analytics dashboard's **trend** surfaces — range bucketing
/// (30d / 3m / 1y / all), the vs-previous-period delta + "ghost" series, and a small share-recap
/// composition. The dashboard view itself does **no** math: it reads tested `KilterAllTimeStats`
/// aggregates and these helpers. Foundation-only (no SwiftUI / SwiftData / UIKit) so every branch is
/// exercised in `SnappetTests` with no simulator — the same contract `KilterAllTimeStats` keeps.
enum KilterStatsTrend {

    /// The trailing-window range chips the volume / sends-per-week trend offers.
    enum Range: String, CaseIterable, Identifiable, Sendable {
        case days30, months3, year, all
        var id: String { rawValue }

        /// The chip label.
        var label: String {
            switch self {
            case .days30:  return "30d"
            case .months3: return "3m"
            case .year:    return "1y"
            case .all:     return "All"
            }
        }

        /// How many days the window spans, or `nil` for "all" (no lower bound). Retained for back-compat
        /// (label/test convenience); the in-range cutoff itself is computed in **calendar units** via
        /// `cutoff(endingAt:calendar:)` so it doesn't drift a bucket as months vary in length.
        var days: Int? {
            switch self {
            case .days30:  return 30
            case .months3: return 90
            case .year:    return 365
            case .all:     return nil
            }
        }

        /// The window expressed as a calendar component + count, so the cutoff lands on a real month/year
        /// boundary (then snapped to a week) instead of a fixed day count that jitters the bucket tally.
        /// `nil` for `.all` (no lower bound).
        var calendarSpan: (component: Calendar.Component, value: Int)? {
            switch self {
            case .days30:  return (.day, 30)
            case .months3: return (.month, 3)
            case .year:    return (.year, 1)
            case .all:     return nil
            }
        }

        /// The trailing-window cutoff for this range. To keep the in-range weekly-bucket count stable as
        /// `now` advances within a week, `now` is first **snapped to the start of its week**, then the
        /// calendar span is subtracted, then the result is snapped to its week start again. So every `now`
        /// inside the same week yields the *same* cutoff (no ±1 bucket jitter from a mid-week / drifting
        /// day-count cutoff). A bucket whose `start` is on/after the cutoff is in range. `nil` for `.all`.
        func cutoff(endingAt now: Date, calendar: Calendar) -> Date? {
            guard let span = calendarSpan else { return nil }
            let anchor = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            guard let raw = calendar.date(byAdding: span.component, value: -span.value, to: anchor)
            else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: raw)?.start ?? raw
        }

        /// The phrase used in the "▲ +18% vs prev 3m" delta caption.
        var previousPhrase: String {
            switch self {
            case .days30:  return "prev 30d"
            case .months3: return "prev 3m"
            case .year:    return "prev 1y"
            case .all:     return "first half"
            }
        }
    }

    /// One trend bar: a labeled period with the **current**-window count and the aligned
    /// **previous**-window count (the faint ghost the chart draws behind the solid bar). `nil` ghost
    /// when there's no comparable previous bucket (the oldest visible weeks).
    struct Bar: Sendable, Equatable, Identifiable {
        var periodLabel: String
        var start: Date
        var current: Int
        var previous: Int?
        var id: String { periodLabel }
    }

    /// A vs-previous-period comparison: the two period totals, the signed delta, and a percentage
    /// (`nil` when the previous total is 0 — no baseline to divide by, so the UI shows the absolute
    /// delta instead of a misleading "+∞%").
    struct Delta: Sendable, Equatable {
        var current: Int
        var previous: Int
        var change: Int
        var percent: Double?

        /// `true` for an up **or flat** ("even") change — i.e. "not down". The flat case reads as the
        /// neutral "even" caption, so it must never colour as a regression (F4d: `isUp` consistent with
        /// the caption for `change == 0`); only a genuine decline (`change < 0`) is "down".
        var isUp: Bool { change >= 0 }

        /// "▲ +18% vs prev 3m" / "▲ +4 vs prev 30d" (absolute when there's no baseline) / "even".
        ///
        /// F4c: when a non-zero change rounds to **0%** (e.g. +1 over a large baseline) the percent is
        /// misleading ("▲ +0%"), so fall back to the absolute delta. A true zero change reads "even".
        func caption(for range: Range) -> String {
            if change == 0 { return "even vs \(range.previousPhrase)" }
            let arrow = change > 0 ? "▲" : "▼"
            if let percent {
                let pct = Int((percent * 100).rounded())
                if pct != 0 {
                    return "\(arrow) \(pct > 0 ? "+" : "")\(pct)% vs \(range.previousPhrase)"
                }
                // Rounds to 0% but the change isn't zero → fall through to the honest absolute delta.
            }
            return "\(arrow) \(change > 0 ? "+" : "")\(change) vs \(range.previousPhrase)"
        }
    }

    // MARK: - Range bucketing

    /// Keep only the weekly volume buckets whose `start` falls inside the trailing `range` ending at
    /// `now`, oldest→newest. `.all` returns every bucket. The cutoff is a calendar-unit boundary snapped
    /// to the start of its week (see `Range.cutoff`), so the in-range count is stable. A bucket whose
    /// start is on/after the cutoff is kept (inclusive lower bound); buckets after `now`'s week are
    /// already excluded upstream.
    static func bucketsInRange(_ buckets: [KilterAllTimeStats.VolumeBucket],
                               range: Range,
                               now: Date,
                               calendar: Calendar = .current) -> [KilterAllTimeStats.VolumeBucket] {
        guard let cutoff = range.cutoff(endingAt: now, calendar: calendar) else {
            return buckets.sorted { $0.start < $1.start }
        }
        return buckets.filter { $0.start >= cutoff }.sorted { $0.start < $1.start }
    }

    /// Pair each in-range weekly bucket with the bucket exactly **one window earlier** (the ghost), so
    /// the chart can draw "this period" solid and "previous period" faint behind it. The ghost for
    /// bucket *i* is the bucket `windowWeeks` positions before it in the full (sorted) series; `nil`
    /// when there is none — the oldest visible weeks have no prior period to compare against.
    ///
    /// `windowWeeks` is the in-range count (so 3m ≈ 13 weeks shifts back ~13 weeks), computed from the
    /// caller's bucketing so the alignment matches exactly what's on screen.
    static func ghostedBars(_ all: [KilterAllTimeStats.VolumeBucket],
                            range: Range,
                            now: Date,
                            calendar: Calendar = .current) -> [Bar] {
        let sorted = all.sorted { $0.start < $1.start }
        let inRange = bucketsInRange(sorted, range: range, now: now, calendar: calendar)
        guard !inRange.isEmpty else { return [] }
        // Index every bucket by its normalized start so the ghost lookup is O(1) and self-consistent.
        let byStart = Dictionary(sorted.map { ($0.start, $0.sends) }, uniquingKeysWith: { a, _ in a })
        let window = inRange.count
        return inRange.map { bucket in
            // The aligned previous bucket sits `window` weeks before this one.
            let ghostStart = calendar.date(byAdding: .weekOfYear, value: -window, to: bucket.start)
            let ghost = ghostStart.flatMap { byStart[$0] }
            return Bar(periodLabel: bucket.periodLabel, start: bucket.start,
                       current: bucket.sends, previous: ghost)
        }
    }

    /// The vs-previous-period delta for a trailing `range`: sum the in-range buckets ("this period")
    /// against the **equal-span** window immediately before it ("previous"). `.all` splits the whole
    /// series in half (recent half vs older half) so the chip still reads.
    ///
    /// **Equal spans (F4).** The previous window is forced to the *same bucket count* as the current
    /// window. When the series doesn't reach a full window back, the previous window is padded with
    /// zero-volume buckets so both sides span the same number of weeks (never "5 weeks of sends vs 2
    /// weeks of sends", which inflates the ratio). When the previous window is *not fully covered* by
    /// real buckets the percentage is suppressed (`percent == nil` → the UI shows the absolute delta /
    /// "insufficient history") rather than dividing by an under-counted baseline.
    static func delta(_ all: [KilterAllTimeStats.VolumeBucket],
                      range: Range,
                      now: Date,
                      calendar: Calendar = .current) -> Delta? {
        let sorted = all.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return nil }

        let cur: Int
        let prev: Int
        let previousFullyCovered: Bool
        if range.calendarSpan == nil {
            // "All" → recent half vs older half (older half rounds down, so a single bucket compares
            // against an empty previous — percent then nil, absolute delta shown). The halves are equal
            // spans by construction (the recent half is never shorter than the older half).
            let mid = sorted.count / 2
            let previous = Array(sorted.prefix(mid))
            let current = Array(sorted.suffix(sorted.count - mid))
            cur = current.reduce(0) { $0 + $1.sends }
            prev = previous.reduce(0) { $0 + $1.sends }
            previousFullyCovered = mid > 0
        } else {
            let inRange = bucketsInRange(sorted, range: range, now: now, calendar: calendar)
            guard !inRange.isEmpty else { return nil }
            let window = inRange.count
            let inRangeStarts = Set(inRange.map(\.start))
            // Buckets strictly before the in-range set, newest-last.
            let before = sorted
                .filter { !inRangeStarts.contains($0.start) && $0.start < (inRange.first?.start ?? now) }
            let realPrevious = Array(before.suffix(window))
            cur = inRange.reduce(0) { $0 + $1.sends }
            // Equal-span: the previous window always counts `window` weeks; missing earlier weeks are
            // treated as zero-volume (pad). The pad never changes the sum but makes the spans match.
            prev = realPrevious.reduce(0) { $0 + $1.sends }
            // Fully covered only when there were `window` real buckets before the current window AND at
            // least one carried a send (a baseline to divide by). Otherwise the percentage is suppressed.
            previousFullyCovered = realPrevious.count == window && prev > 0
        }

        let change = cur - prev
        // Percent only when the previous window is a fully-covered, non-zero baseline — never off a
        // padded / under-counted span (that would inflate the ratio).
        let percent: Double? = previousFullyCovered ? Double(change) / Double(prev) : nil
        return Delta(current: cur, previous: prev, change: change, percent: percent)
    }

    /// The "Climbing Level" hero delta vs a prior window: compares the all-time `maxGradeProgression`
    /// step-line's **latest** grade against the best-send grade as-of `now − monthsBack` **by calendar
    /// date** — the latest progression point whose month falls on/before that cutoff. Because the
    /// progression only carries months that actually had sends (it is gappy), the reference is resolved
    /// by **date**, never by stepping back `monthsBack` array entries (which would over- or under-shoot
    /// across a gap). Expressed as a "+1 vs 90d" style chip; compares the **bucketed** difficulty so the
    /// step matches the displayed grade labels, not a sub-grade float wobble.
    ///
    /// `nil` when there's no comparable earlier point — cold start, a single month, or the entire history
    /// is more recent than the cutoff (so there is no honest "N months ago" baseline to chip against).
    static func levelDelta(_ progression: [KilterAllTimeStats.GradePoint],
                           monthsBack: Int,
                           now: Date = .now,
                           calendar: Calendar = .current) -> (steps: Int, fromLabel: String, toLabel: String)? {
        guard let latest = progression.last, progression.count >= 2 else { return nil }
        guard let cutoff = calendar.date(byAdding: .month, value: -monthsBack, to: now) else { return nil }
        let cutoffMonth = monthStart(cutoff, calendar: calendar)
        // The reference = the latest progression point whose month-start is on/before the cutoff month.
        // Resolved by date so a gappy series (months without sends are simply absent) can't miscount.
        let reference = progression
            .compactMap { p -> (date: Date, point: KilterAllTimeStats.GradePoint)? in
                guard let d = monthStartFromLabel(p.periodLabel, calendar: calendar) else { return nil }
                return (d, p)
            }
            .filter { $0.date <= cutoffMonth }
            .max { $0.date < $1.date }?
            .point
        guard let reference, reference.periodLabel != latest.periodLabel else { return nil }
        let steps = Int(latest.difficulty.rounded()) - Int(reference.difficulty.rounded())
        return (steps: steps, fromLabel: reference.gradeLabel, toLabel: latest.gradeLabel)
    }

    // MARK: - Share recap ("Month in Send")

    /// A low-cost shareable recap line composed from the same `KilterAllTimeStats` aggregate — no new
    /// math, just a readable sentence from the month roll-up + the all-time ceiling. `nil` when there's
    /// no climbing in the requested month (nothing to brag about).
    struct Recap: Sendable, Equatable {
        var title: String
        var line: String
    }

    /// Compose a "Month in Send" recap for the calendar month containing `now` from the month roll-ups
    /// + the climbing level. The roll-up already carries the period's sessions / sends / hardest grade
    /// (all tested in P0); this only formats them.
    static func monthRecap(_ stats: KilterAllTimeStats,
                           now: Date,
                           calendar: Calendar = .current) -> Recap? {
        let key = monthKey(now, calendar: calendar)
        guard let month = stats.monthRollups.first(where: { $0.periodLabel == key }), month.sends > 0
        else { return nil }
        let monthName = monthDisplayName(now, calendar: calendar)
        let sessionPart = month.sessions > 0
            ? " across \(month.sessions) session\(month.sessions == 1 ? "" : "s")" : ""
        let hardestPart = month.hardestGradeLabel.map { " — topped out at \($0)" } ?? ""
        return Recap(
            title: "\(monthName) in Send",
            line: "\(month.sends) send\(month.sends == 1 ? "" : "s")\(sessionPart)\(hardestPart).")
    }

    // MARK: - Private formatting

    /// `"YYYY-MM"` for the calendar month containing `date` — matches `KilterAllTimeStats.monthKey`
    /// so a recap can look up the right roll-up.
    private static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// The start instant of the calendar month containing `date` (year+month, day 1) — a stable key for
    /// comparing progression points by date.
    private static func monthStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Parse a `"YYYY-MM"` progression `periodLabel` back to that month's start instant. `nil` for a
    /// malformed label (so the point is simply skipped, never miscounted).
    private static func monthStartFromLabel(_ label: String, calendar: Calendar) -> Date? {
        let parts = label.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// A friendly month name ("June") for the recap title.
    private static func monthDisplayName(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        f.dateFormat = "LLLL"
        return f.string(from: date)
    }
}
