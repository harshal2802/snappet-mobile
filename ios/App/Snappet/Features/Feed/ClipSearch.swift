import Foundation

// MARK: - Clips search — what a post can be found by (prompt 165, pure)
//
// Prompt 107's search matched only the post title and the session title. People remember more than names:
// the grade ("v5", "6c"), the angle ("40°"), whether they sent it ("sent", "flash"), and when ("sep",
// "tuesday", "2026", "last week"). Every whitespace-separated word must match somewhere (AND), so
// "v5 sent sep" narrows instead of widening. Relative phrases ("today", "yesterday", "this/last week",
// "this/last month") become date ranges on the post's capture time.
//
// Pure: the clock, calendar and locale are injected so it unit-tests deterministically.

struct ClipSearch {

    struct Context {
        var now: Date
        var calendar: Calendar
        var locale: Locale
        static var current: Context { Context(now: .now, calendar: .current, locale: .current) }
    }

    /// Words that must each match a post's text (lowercased, phrases removed).
    let terms: [String]
    /// Date ranges the post's capture time must fall in (from relative phrases).
    let ranges: [DateInterval]
    private let context: Context
    private let formatters: [DateFormatter]

    init(query: String, context: Context = .current) {
        self.context = context
        var q = " " + query.lowercased() + " "
        var ranges: [DateInterval] = []
        for (phrase, range) in Self.relativePhrases(context) where q.contains(" \(phrase) ") {
            q = q.replacingOccurrences(of: " \(phrase) ", with: " ")
            if let range { ranges.append(range) }
        }
        self.ranges = ranges
        terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        formatters = ["MMMM", "MMM", "EEEE", "EEE", "yyyy", "d MMM", "MMM d"].map { f in
            let df = DateFormatter()
            df.locale = context.locale
            df.calendar = context.calendar
            df.timeZone = context.calendar.timeZone
            df.dateFormat = f
            return df
        }
    }

    var isEmpty: Bool { terms.isEmpty && ranges.isEmpty }

    func matches(_ post: ClipFeedPost) -> Bool {
        guard ranges.allSatisfy({ $0.contains(post.captureAt) }) else { return false }
        guard !terms.isEmpty else { return true }
        let text = haystack(post)
        return terms.allSatisfy { text.localizedStandardContains($0) }
    }

    /// Everything a post can be found by, in one string (case/diacritic-insensitive matching).
    func haystack(_ post: ClipFeedPost) -> String {
        var parts = [post.title, post.subtitle, post.overlayDetail, post.sessionTitle]
        if let r = post.climbResult {
            parts.append(r.status.label)                                    // Flash / Sent / Project / Attempt
            if r.status.isSend { parts.append("sent send sends") }          // "sent" finds flashes too
            if r.status == .flash { parts.append("flashed") }
        }
        if post.isReel { parts.append("reel highlights") }
        parts += formatters.map { $0.string(from: post.captureAt) }
        return parts.joined(separator: " | ")
    }

    /// The relative phrases, longest first so "last week" wins over a bare "week". A nil range means the
    /// calendar couldn't resolve it (the phrase is still consumed, never searched as text).
    private static func relativePhrases(_ c: Context) -> [(String, DateInterval?)] {
        let cal = c.calendar
        let today = cal.startOfDay(for: c.now)
        func day(_ offset: Int) -> DateInterval? {
            guard let start = cal.date(byAdding: .day, value: offset, to: today),
                  let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        func period(_ unit: Calendar.Component, offset: Int) -> DateInterval? {
            guard let anchor = cal.date(byAdding: unit, value: offset, to: c.now) else { return nil }
            return cal.dateInterval(of: unit == .weekOfYear ? .weekOfYear : .month, for: anchor)
        }
        return [
            ("last week", period(.weekOfYear, offset: -1)),
            ("this week", period(.weekOfYear, offset: 0)),
            ("last month", period(.month, offset: -1)),
            ("this month", period(.month, offset: 0)),
            ("yesterday", day(-1)),
            ("today", day(0)),
        ]
    }
}
