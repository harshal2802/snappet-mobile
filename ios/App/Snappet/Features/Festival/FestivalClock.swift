import Foundation

// MARK: - Festival clock + set rows (prompt 232, pure)
//
// People type a festival night as clock times — "Fred again.. 23:30–01:00", "Jayda G 01:00" — never
// as dates. A festival day runs from `FestivalDay.rolloverHour` (06:00) to 06:00 the next morning,
// so a time before the rollover belongs to the NEXT calendar morning of that poster day. Every time
// editor (create a lineup, add a stage's sets, edit a set) goes through these helpers, so "01:00"
// means the same thing everywhere — and the same thing the schedule and validator already assume.

enum FestivalClock {

    static func calendar(offsetSeconds: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? TimeZone(secondsFromGMT: 0)!
        return cal
    }

    /// The instant `hour:minute` on poster day `day` (`yyyy-MM-dd`), festival-local: before the
    /// rollover it's the next morning.
    static func date(day: String, hour: Int, minute: Int, offsetSeconds: Int) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        let cal = calendar(offsetSeconds: offsetSeconds)
        guard let base = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2],
                                                        hour: hour, minute: minute)) else { return nil }
        return hour < FestivalDay.rolloverHour ? base.addingTimeInterval(24 * 3600) : base
    }

    static func hourMinute(_ date: Date, offsetSeconds: Int) -> (hour: Int, minute: Int) {
        let c = calendar(offsetSeconds: offsetSeconds).dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0, c.minute ?? 0)
    }

    /// Re-anchor a time picker's value (only its hour:minute matter) onto the festival day.
    static func onDay(_ picked: Date, day: String, offsetSeconds: Int) -> Date? {
        let hm = hourMinute(picked, offsetSeconds: offsetSeconds)
        return date(day: day, hour: hm.hour, minute: hm.minute, offsetSeconds: offsetSeconds)
    }

    /// A set's end from its picked end time: on the day, and always after the start (a 05:00 → 07:00
    /// set crosses the rollover).
    static func end(_ picked: Date, after start: Date, day: String, offsetSeconds: Int) -> Date? {
        guard var end = onDay(picked, day: day, offsetSeconds: offsetSeconds) else { return nil }
        while end <= start { end.addTimeInterval(24 * 3600) }
        while end.timeIntervalSince(start) > 24 * 3600 { end.addTimeInterval(-24 * 3600) }
        return end
    }

    /// "HH:mm" festival-local (the poster draft's storage form).
    static func hhmm(_ date: Date, offsetSeconds: Int) -> String {
        let hm = hourMinute(date, offsetSeconds: offsetSeconds)
        return String(format: "%02d:%02d", hm.hour, hm.minute)
    }

    /// "1 h 30" / "45 min".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let mins = max(0, Int((seconds / 60).rounded()))
        if mins < 60 { return "\(mins) min" }
        return mins % 60 == 0 ? "\(mins / 60) h" : String(format: "%d h %02d", mins / 60, mins % 60)
    }
}

/// One editable set row (artist + times) in the stage editor.
struct FestivalSetRow: Identifiable, Equatable, Sendable {
    var id = UUID()
    var artist: String
    var start: Date
    var end: Date

    var isFilled: Bool { !artist.trimmingCharacters(in: .whitespaces).isEmpty }

    static let defaultMinutes = 60

    /// The row "Add another artist" appends: starts when the last row ends, same length as it
    /// (back-to-back is how a stage runs); the first row of an empty stage starts at `fallback`.
    static func next(after rows: [FestivalSetRow], fallback: Date) -> FestivalSetRow {
        guard let last = rows.max(by: { $0.end < $1.end }) else {
            return FestivalSetRow(artist: "", start: fallback,
                                  end: fallback.addingTimeInterval(TimeInterval(defaultMinutes * 60)))
        }
        let length = max(15 * 60, last.end.timeIntervalSince(last.start))
        return FestivalSetRow(artist: "", start: last.end, end: last.end.addingTimeInterval(length))
    }

    /// Rows that overlap another row — or an existing set on the same stage — by more than a
    /// minute (back-to-back is fine).
    static func clashing(_ rows: [FestivalSetRow], existing: [FestivalSet] = []) -> Set<UUID> {
        var out: Set<UUID> = []
        let windows = rows.filter(\.isFilled)
        for (i, a) in windows.enumerated() {
            for b in windows.dropFirst(i + 1) where overlaps(a.start, a.end, b.start, b.end) {
                out.insert(a.id); out.insert(b.id)
            }
            if existing.contains(where: { overlaps(a.start, a.end, $0.start, $0.end) }) { out.insert(a.id) }
        }
        return out
    }

    private static func overlaps(_ s1: Date, _ e1: Date, _ s2: Date, _ e2: Date) -> Bool {
        min(e1, e2).timeIntervalSince(max(s1, s2)) > 60
    }
}
