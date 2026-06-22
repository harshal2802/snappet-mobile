import Foundation

// MARK: - Recap Feed — scroll date orientation (F8, pure)
//
// Turns a card's `anchorDate` into the two strings the scroll date bar shows: a coarse "era" bucket
// (the persistent whisper while you read) and the precise day (revealed while you scroll). Pure +
// Foundation-only so it unit-tests without a simulator and the Kotlin port mirrors it 1:1; locale and
// time zone come from the injected `calendar` (tests pin en_US + a fixed zone for determinism).

/// The scroll-orientation label for one feed card.
struct FeedDateLabel: Equatable, Sendable {
    /// The coarse bucket — "Today" | "Yesterday" | "This week" | "Earlier in June" | "May 2026".
    var era: String
    /// The precise day — "Wed · Jun 17".
    var day: String
}

enum FeedTimeBucket {

    /// The full label (era + day) for `date` relative to `now`.
    static func label(for date: Date, now: Date, calendar: Calendar = .current) -> FeedDateLabel {
        FeedDateLabel(era: era(for: date, now: now, calendar: calendar),
                      day: day(for: date, calendar: calendar))
    }

    /// The coarse era bucket. Day-granularity so a card late yesterday still reads "Yesterday".
    /// Buckets, in order: Today · Yesterday · This week (2–6 days) · Earlier in <Month> (this calendar
    /// month) · <Month Year> (any older month). Future dates clamp to "Today".
    static func era(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startDate, to: startNow).day ?? 0

        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days <= 6 { return "This week" }

        let now = calendar.dateComponents([.year, .month], from: now)
        let d = calendar.dateComponents([.year, .month], from: date)
        let monthName = formatter(calendar, "LLLL").string(from: date)   // standalone month name
        if d.year == now.year, d.month == now.month { return "Earlier in \(monthName)" }
        return "\(monthName) \(d.year ?? 0)"
    }

    /// The precise day line — weekday + month + day, e.g. "Wed · Jun 17" (the era carries the year).
    static func day(for date: Date, calendar: Calendar = .current) -> String {
        formatter(calendar, "EEE '·' MMM d").string(from: date)
    }

    private static func formatter(_ calendar: Calendar, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = calendar.locale ?? .current
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("")    // reset, then pin the explicit pattern
        f.dateFormat = format
        return f
    }
}
