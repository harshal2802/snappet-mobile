import Foundation

/// When a routine is planned to happen, and how Snappet reminds you about it (prompt 136, wireframe
/// `docs/ux-research/routine-schedule/`). Stored on `Routine.scheduleData` as JSON and shared inside the
/// routine QR code, so the Codable form is **terse** and every field has a default: an older build that
/// doesn't know a key ignores it, and a newer key missing from an old payload decodes to its default.
///
/// Pure (Foundation only). All day arithmetic goes through the caller's `Calendar`, so DST and the user's
/// first weekday are handled by the system, not by adding 86 400 s.
struct RoutineSchedule: Hashable, Sendable {
    /// Paused schedules keep their settings but plan nothing (the editor's "Scheduled" switch).
    var isEnabled = true
    var repeatRule: ScheduleRepeat = .weekly(weekdays: [2, 4, 6], everyWeeks: 1)
    /// The start time on every day, unless `perDayTimes` overrides that weekday.
    var time = ScheduleTime(hour: 7, minute: 0)
    /// Weekly only: `Calendar` weekday (1 = Sunday … 7 = Saturday) → its own start time. Empty = the
    /// editor's "Same time every day".
    var perDayTimes: [Int: ScheduleTime] = [:]
    /// First day the schedule can occur (a `DayKey`). Anchors the every-N-weeks / every-N-days phase.
    var startDay: DayKey
    var end: ScheduleEnd = .never
    var reminder = ScheduleReminder()
    /// Days the user tapped "Skip today". Device-local bookkeeping — stripped from a shared code.
    var skippedDays: Set<DayKey> = []
    /// Several sessions on a scheduled day (prompt 144, wireframe frames 7–8): set times, or every N
    /// minutes/hours in a window. `nil` = once a day at `time` / `perDayTimes` (the original behaviour).
    var daily: DailyRepeat? = nil
    /// Single slots skipped with "Skip this one" (`SlotKey`s). Device-local, stripped when shared.
    var skippedSlots: Set<SlotKey> = []
    /// With several sessions a day: how many make the day count as done in Habits (default 1).
    var doneAfterSessions: Int? = nil

    init(startDay: DayKey) { self.startDay = startDay }

    /// A sensible first schedule for the editor: Mon/Wed/Fri at 7:00 starting today.
    static func suggested(today: Date, calendar: Calendar = .current) -> RoutineSchedule {
        RoutineSchedule(startDay: DayKey(today, calendar: calendar))
    }

    /// The copy that travels in a QR code: no skip history.
    var forSharing: RoutineSchedule {
        var s = self
        s.skippedDays = []
        s.skippedSlots = []
        return s
    }
}

// MARK: - Value types

/// A calendar day with no time zone attached (`20261001`). Days — not instants — are what a schedule is
/// about, so a code shared from another time zone still means "Wednesday", and a stored day never drifts
/// when the clocks change.
struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let value: Int

    init(value: Int) { self.value = value }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        value = (c.year ?? 1970) * 10_000 + (c.month ?? 1) * 100 + (c.day ?? 1)
    }

    /// Start of this day in `calendar`'s time zone.
    func date(calendar: Calendar = .current) -> Date {
        let comps = DateComponents(year: value / 10_000, month: (value / 100) % 100, day: value % 100)
        return calendar.date(from: comps).map { calendar.startOfDay(for: $0) } ?? .distantPast
    }

    func adding(days: Int, calendar: Calendar = .current) -> DayKey {
        DayKey(calendar.date(byAdding: .day, value: days, to: date(calendar: calendar)) ?? .distantPast,
               calendar: calendar)
    }

    static func < (a: DayKey, b: DayKey) -> Bool { a.value < b.value }
    var description: String { String(value) }

    init(from decoder: Decoder) throws { value = try decoder.singleValueContainer().decode(Int.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

/// One slot of a day with several sessions: the day and the slot's index in that day's order.
struct SlotKey: Hashable, Comparable, Codable, Sendable {
    let day: DayKey
    let index: Int
    static func < (a: SlotKey, b: SlotKey) -> Bool { (a.day, a.index) < (b.day, b.index) }
    /// Compact wire form: `day.value * 10_000 + index`.
    var packed: Int { day.value * 10_000 + index }
    init(day: DayKey, index: Int) { self.day = day; self.index = index }
    init(packed: Int) { day = DayKey(value: packed / 10_000); index = packed % 10_000 }
    init(from decoder: Decoder) throws { self.init(packed: try decoder.singleValueContainer().decode(Int.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(packed) }
}

/// Several sessions on a scheduled day (prompt 144).
enum DailyRepeat: Hashable, Sendable {
    /// At these times (sorted, de-duplicated).
    case times([ScheduleTime])
    /// Every `minutes` from `from` until `until` (inclusive when it lands exactly), within the day.
    case every(minutes: Int, from: ScheduleTime, until: ScheduleTime)

    static let intervalChoices = [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720]
    /// Hard cap on slots per day (every minute, all day, is 1440 — no human wants a reminder per minute,
    /// but the schedule itself may be that dense).
    static let maxSlotsPerDay = 1440

    /// The day's slot times in order.
    var slotTimes: [ScheduleTime] {
        switch self {
        case .times(let ts):
            return Array(Set(ts)).sorted()
        case .every(let m, let from, let until):
            let step = max(1, m)
            guard until.minutesOfDay >= from.minutesOfDay else { return [from] }
            return stride(from: from.minutesOfDay, through: until.minutesOfDay, by: step)
                .prefix(Self.maxSlotsPerDay).map(ScheduleTime.init(minutesOfDay:))
        }
    }

    /// Shortest gap between consecutive slots, in minutes (nil for one slot).
    var minimumGapMinutes: Int? {
        let t = slotTimes.map(\.minutesOfDay)
        guard t.count > 1 else { return nil }
        return zip(t.dropFirst(), t).map { $0 - $1 }.min()
    }
}

/// A wall-clock time of day.
struct ScheduleTime: Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    init(minutesOfDay: Int) {
        let m = min(24 * 60 - 1, max(0, minutesOfDay))
        self.init(hour: m / 60, minute: m % 60)
    }

    var minutesOfDay: Int { hour * 60 + minute }
    static func < (a: ScheduleTime, b: ScheduleTime) -> Bool { a.minutesOfDay < b.minutesOfDay }

    /// This time on `day`. `Calendar` resolves a DST gap (e.g. 2:30 on spring-forward night) to the
    /// next valid instant rather than failing.
    func on(_ day: DayKey, calendar: Calendar = .current) -> Date {
        let start = day.date(calendar: calendar)
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)
            ?? start.addingTimeInterval(TimeInterval(minutesOfDay * 60))
    }

    /// "7:00 AM" in the user's locale.
    func formatted(calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                     calendar: calendar, timeZone: calendar.timeZone)
        return on(DayKey(value: 20_000_101), calendar: calendar).formatted(style)
    }
}

enum ScheduleRepeat: Hashable, Sendable {
    /// On these `Calendar` weekdays (1 = Sunday … 7 = Saturday), every `everyWeeks` weeks (1–4).
    case weekly(weekdays: Set<Int>, everyWeeks: Int)
    /// Every `n` days from the start day (1 = daily).
    case everyDays(Int)
    /// Only on the start day.
    case once

    static let maxEveryWeeks = 4
    static let maxEveryDays = 14
}

enum ScheduleEnd: Hashable, Sendable {
    case never
    /// Last day it can occur (inclusive).
    case onDay(DayKey)
    /// Stop once this many sessions of the routine have been completed since the start day.
    case afterSessions(Int)
}

/// How the routine's notifications behave.
struct ScheduleReminder: Hashable, Sendable {
    var isOn = true
    /// Minutes before the start time the reminder fires (0 = at the start time).
    var leadMinutes = 15
    /// A follow-up "still on for it?" this long after the start time, if the routine hasn't been started.
    /// `nil` = off.
    var nudgeAfterMinutes: Int? = 30
    /// A heads-up the evening before, at this time. `nil` = off.
    var headsUp: ScheduleTime? = nil
    var sound = true
    /// Break through Focus modes (the app holds the Time Sensitive entitlement).
    var timeSensitive = false
    /// With several sessions a day: remind for every session (default) or only the first of the day.
    var everySession = true

    static let leadChoices = [0, 5, 10, 15, 30, 60]
    static let nudgeChoices = [15, 30, 60, 120]
}

// MARK: - Occurrence math

extension RoutineSchedule {
    /// Whether the routine is planned on `day`, ignoring skips and completed-session ends.
    func occurs(on day: DayKey, calendar: Calendar = .current) -> Bool {
        guard day >= startDay else { return false }
        if case .onDay(let last) = end, day > last { return false }
        switch repeatRule {
        case .once:
            return day == startDay
        case .everyDays(let n):
            return daysBetween(startDay, day, calendar: calendar) % max(1, n) == 0
        case .weekly(let weekdays, let everyWeeks):
            let weekday = calendar.component(.weekday, from: day.date(calendar: calendar))
            guard weekdays.contains(weekday) else { return false }
            guard everyWeeks > 1 else { return true }
            let weeks = daysBetween(weekStart(startDay, calendar), weekStart(day, calendar), calendar: calendar) / 7
            return weeks % everyWeeks == 0
        }
    }

    /// The planned start time on `day` (the weekday's own time when "Same time every day" is off).
    func startTime(on day: DayKey, calendar: Calendar = .current) -> Date {
        let weekday = calendar.component(.weekday, from: day.date(calendar: calendar))
        return (perDayTimes[weekday] ?? time).on(day, calendar: calendar)
    }

    /// Whether the schedule has run its course: past its end day, a `.once` in the past, or the
    /// completed-session quota reached.
    func isFinished(today: DayKey, completedSessions: Int) -> Bool {
        switch end {
        case .never: break
        case .onDay(let last): if today > last { return true }
        case .afterSessions(let n): if completedSessions >= n { return true }
        }
        if case .once = repeatRule { return today > startDay }
        return false
    }

    // MARK: Slots (prompt 144)

    /// Whether the day has several sessions.
    var isMultiSlot: Bool { (daily?.slotTimes.count ?? 1) > 1 }

    /// The start of every session on `day`, in order (one for a once-a-day schedule).
    func slotStarts(on day: DayKey, calendar: Calendar = .current) -> [Date] {
        guard let daily else { return [startTime(on: day, calendar: calendar)] }
        return daily.slotTimes.map { $0.on(day, calendar: calendar) }
    }

    /// Slots on planned days in `[from, through]`, day- and slot-skips excluded.
    func slots(from: DayKey, through: DayKey, calendar: Calendar = .current) -> [(key: SlotKey, start: Date)] {
        days(from: from, through: through, calendar: calendar).flatMap { day in
            slotStarts(on: day, calendar: calendar).enumerated().compactMap { i, start in
                let key = SlotKey(day: day, index: i)
                return skippedSlots.contains(key) ? nil : (key, start)
            }
        }
    }

    /// Sessions that count a day as done (Habits): 1 unless set, never more than the day's slots.
    var sessionsForDayDone: Int {
        min(max(1, doneAfterSessions ?? 1), daily?.slotTimes.count ?? 1)
    }

    /// Planned days in `[from, through]`, skips excluded.
    func days(from: DayKey, through: DayKey, calendar: Calendar = .current) -> [DayKey] {
        guard from <= through else { return [] }
        var out: [DayKey] = []
        var d = max(from, startDay)
        while d <= through {
            if occurs(on: d, calendar: calendar), !skippedDays.contains(d) { out.append(d) }
            d = d.adding(days: 1, calendar: calendar)
        }
        return out
    }

    /// Human summary: "Mon · Wed · Fri at 7:00 AM", "Every 3 days at 6:30 PM", "Once on 3 Oct at …".
    func summary(calendar: Calendar = .current) -> String {
        var timeText = perDayTimes.isEmpty ? " at \(time.formatted(calendar: calendar))" : " · times vary"
        if let daily, isMultiSlot {
            switch daily {
            case .times(let ts): timeText = " · \(Set(ts).count) times a day"
            case .every(let m, let from, let until):
                let every = m % 60 == 0 ? (m == 60 ? "hour" : "\(m / 60) h") : "\(m) min"
                timeText = " · every \(every), \(from.formatted(calendar: calendar))–\(until.formatted(calendar: calendar))"
            }
        }
        switch repeatRule {
        case .weekly(let weekdays, let everyWeeks):
            let names = Self.orderedWeekdays(calendar).filter(weekdays.contains)
                .map { calendar.shortWeekdaySymbols[$0 - 1] }
            let days = weekdays.count == 7 ? "Every day" : names.joined(separator: " · ")
            let cadence = everyWeeks > 1 ? " every \(everyWeeks) weeks" : ""
            return days + cadence + timeText
        case .everyDays(let n):
            return (n == 1 ? "Every day" : "Every \(n) days") + timeText
        case .once:
            let d = startDay.date(calendar: calendar).formatted(.dateTime.day().month(.abbreviated))
            return "Once on \(d)" + timeText
        }
    }

    /// Weekdays (1…7) in the calendar's display order, e.g. Mon…Sun where the week starts on Monday.
    static func orderedWeekdays(_ calendar: Calendar) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    private func daysBetween(_ a: DayKey, _ b: DayKey, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: a.date(calendar: calendar), to: b.date(calendar: calendar)).day ?? 0
    }

    private func weekStart(_ day: DayKey, _ calendar: Calendar) -> DayKey {
        let date = day.date(calendar: calendar)
        return DayKey(calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date, calendar: calendar)
    }
}

// MARK: - Terse Codable (storage + the QR payload share one codec)

extension RoutineSchedule: Codable {
    private enum K: String, CodingKey {
        case on, rk, wd, ew, ed, t, pt, sd, ek, ev, rm, sk
        // prompt 144: set times · every-N window · skipped slots · Habits "done after N"
        case dt, de, df, du, ss, dn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        startDay = try c.decode(DayKey.self, forKey: .sd)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        switch try c.decodeIfPresent(String.self, forKey: .rk) ?? "w" {
        case "d": repeatRule = .everyDays(max(1, try c.decodeIfPresent(Int.self, forKey: .ed) ?? 1))
        case "o": repeatRule = .once
        default:
            let days = Set(try c.decodeIfPresent([Int].self, forKey: .wd) ?? []).filter { (1...7).contains($0) }
            let every = min(ScheduleRepeat.maxEveryWeeks, max(1, try c.decodeIfPresent(Int.self, forKey: .ew) ?? 1))
            repeatRule = .weekly(weekdays: days, everyWeeks: every)
        }
        time = ScheduleTime(minutesOfDay: try c.decodeIfPresent(Int.self, forKey: .t) ?? 7 * 60)
        let pairs = try c.decodeIfPresent([[Int]].self, forKey: .pt) ?? []
        perDayTimes = Dictionary(pairs.compactMap { p in
            p.count == 2 && (1...7).contains(p[0]) ? (p[0], ScheduleTime(minutesOfDay: p[1])) : nil
        }, uniquingKeysWith: { a, _ in a })
        switch try c.decodeIfPresent(String.self, forKey: .ek) ?? "n" {
        case "d": end = .onDay(DayKey(value: try c.decode(Int.self, forKey: .ev)))
        case "s": end = .afterSessions(max(1, try c.decode(Int.self, forKey: .ev)))
        default: end = .never
        }
        reminder = try c.decodeIfPresent(ScheduleReminder.self, forKey: .rm) ?? ScheduleReminder()
        skippedDays = Set(try c.decodeIfPresent([DayKey].self, forKey: .sk) ?? [])
        if let times = try c.decodeIfPresent([Int].self, forKey: .dt), !times.isEmpty {
            daily = .times(times.map(ScheduleTime.init(minutesOfDay:)))
        } else if let every = try c.decodeIfPresent(Int.self, forKey: .de) {
            daily = .every(minutes: max(1, every),
                           from: ScheduleTime(minutesOfDay: try c.decodeIfPresent(Int.self, forKey: .df) ?? time.minutesOfDay),
                           until: ScheduleTime(minutesOfDay: try c.decodeIfPresent(Int.self, forKey: .du) ?? 20 * 60))
        }
        skippedSlots = Set(try c.decodeIfPresent([SlotKey].self, forKey: .ss) ?? [])
        doneAfterSessions = try c.decodeIfPresent(Int.self, forKey: .dn)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(startDay, forKey: .sd)
        if !isEnabled { try c.encode(false, forKey: .on) }
        switch repeatRule {
        case .weekly(let days, let every):
            try c.encode(days.sorted(), forKey: .wd)
            if every != 1 { try c.encode(every, forKey: .ew) }
        case .everyDays(let n):
            try c.encode("d", forKey: .rk)
            try c.encode(n, forKey: .ed)
        case .once:
            try c.encode("o", forKey: .rk)
        }
        try c.encode(time.minutesOfDay, forKey: .t)
        if !perDayTimes.isEmpty {
            try c.encode(perDayTimes.keys.sorted().map { [$0, perDayTimes[$0]!.minutesOfDay] }, forKey: .pt)
        }
        switch end {
        case .never: break
        case .onDay(let d):
            try c.encode("d", forKey: .ek)
            try c.encode(d.value, forKey: .ev)
        case .afterSessions(let n):
            try c.encode("s", forKey: .ek)
            try c.encode(n, forKey: .ev)
        }
        if reminder != ScheduleReminder() { try c.encode(reminder, forKey: .rm) }
        if !skippedDays.isEmpty { try c.encode(skippedDays.sorted(), forKey: .sk) }
        // An older build ignores these keys and keeps `t` — the first slot (the editor keeps them in sync).
        switch daily {
        case .times(let ts)?: try c.encode(Array(Set(ts)).sorted().map(\.minutesOfDay), forKey: .dt)
        case .every(let m, let from, let until)?:
            try c.encode(m, forKey: .de)
            try c.encode(from.minutesOfDay, forKey: .df)
            try c.encode(until.minutesOfDay, forKey: .du)
        case nil: break
        }
        if !skippedSlots.isEmpty { try c.encode(skippedSlots.sorted(), forKey: .ss) }
        try c.encodeIfPresent(doneAfterSessions, forKey: .dn)
    }
}

extension ScheduleReminder: Codable {
    private enum K: String, CodingKey { case on, l, ng, hu, snd, ts, fo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = ScheduleReminder()
        isOn = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.isOn
        leadMinutes = max(0, try c.decodeIfPresent(Int.self, forKey: .l) ?? d.leadMinutes)
        // -1 encodes an explicit "off" so it's distinguishable from "missing → default".
        let nudge = try c.decodeIfPresent(Int.self, forKey: .ng)
        nudgeAfterMinutes = nudge.map { $0 < 0 ? nil : $0 } ?? d.nudgeAfterMinutes
        headsUp = try c.decodeIfPresent(Int.self, forKey: .hu).map(ScheduleTime.init(minutesOfDay:))
        sound = try c.decodeIfPresent(Bool.self, forKey: .snd) ?? d.sound
        timeSensitive = try c.decodeIfPresent(Bool.self, forKey: .ts) ?? d.timeSensitive
        everySession = !(try c.decodeIfPresent(Bool.self, forKey: .fo) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        let d = ScheduleReminder()
        if isOn != d.isOn { try c.encode(isOn, forKey: .on) }
        if leadMinutes != d.leadMinutes { try c.encode(leadMinutes, forKey: .l) }
        if nudgeAfterMinutes != d.nudgeAfterMinutes { try c.encode(nudgeAfterMinutes ?? -1, forKey: .ng) }
        try c.encodeIfPresent(headsUp?.minutesOfDay, forKey: .hu)
        if sound != d.sound { try c.encode(sound, forKey: .snd) }
        if timeSensitive != d.timeSensitive { try c.encode(timeSensitive, forKey: .ts) }
        if !everySession { try c.encode(true, forKey: .fo) }
    }
}

extension RoutineSchedule {
    /// Storage round-trip for `Routine.scheduleData`.
    static func decode(_ data: Data?) -> RoutineSchedule? {
        data.flatMap { try? JSONDecoder().decode(RoutineSchedule.self, from: $0) }
    }

    var encodedData: Data? { try? JSONEncoder().encode(self) }
}
