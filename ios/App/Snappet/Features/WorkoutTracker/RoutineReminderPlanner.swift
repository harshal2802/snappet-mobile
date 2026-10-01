import Foundation

/// What the planner needs to know about one scheduled routine (prompt 136). Built from SwiftData by
/// `RoutineScheduleSync`; plain values so the planner is pure and unit-tested.
struct ScheduledRoutineInput: Sendable {
    var routineID: UUID
    var name: String
    var blockCount: Int
    var setCount: Int
    var schedule: RoutineSchedule
    /// Days a session of this routine was started (an active one included) — a started day is "done"
    /// for the purpose of reminders: no nudge, no reminder, ✓ on the week strip.
    var doneDays: Set<DayKey>
    /// Completed sessions since the schedule's start day — drives `ScheduleEnd.afterSessions`.
    var completedSessions: Int
    /// When each recent session of this routine started — matched to the nearest slot on a day with
    /// several sessions (prompt 144). Unused for once-a-day schedules (`doneDays` decides those).
    var sessionStarts: [Date] = []

    /// The slot indices of `day` that have a session (each session counts for its nearest slot).
    func doneSlots(on day: DayKey, starts slotStarts: [Date], calendar: Calendar = .current) -> Set<Int> {
        guard schedule.isMultiSlot else { return doneDays.contains(day) ? Set(slotStarts.indices) : [] }
        var done = Set<Int>()
        for s in sessionStarts where DayKey(s, calendar: calendar) == day {
            if let i = slotStarts.indices.min(by: { abs(slotStarts[$0].timeIntervalSince(s)) < abs(slotStarts[$1].timeIntervalSince(s)) }) {
                done.insert(i)
            }
        }
        return done
    }
}

/// One local notification the planner wants pending.
struct PlannedRoutineNotification: Hashable, Sendable {
    enum Kind: String, Sendable { case reminder, nudge, headsUp }

    var id: String
    var kind: Kind
    var routineID: UUID
    var day: DayKey
    var fireDate: Date
    var title: String
    var body: String
    var sound: Bool
    var timeSensitive: Bool

    /// Every routine-schedule notification id starts with this, so a re-plan can clear exactly its own.
    static let idPrefix = "snappet.routine."

    /// Slot 0 keeps the original id shape; later slots append their index (the parser only reads the
    /// routine and day, so both shapes route the same).
    static func makeID(routineID: UUID, day: DayKey, kind: Kind, slot: Int = 0) -> String {
        let base = "\(idPrefix)\(routineID.uuidString).\(day.value).\(kind.rawValue)"
        return slot == 0 ? base : "\(base).\(slot)"
    }

    /// The slot index in an id (0 when absent).
    static func slot(of id: String) -> Int {
        guard id.hasPrefix(idPrefix) else { return 0 }
        let parts = id.dropFirst(idPrefix.count).split(separator: ".")
        return parts.count >= 4 ? Int(parts[3]) ?? 0 : 0
    }

    /// `(routineID, day)` back out of an id — how a tapped notification finds its routine and day.
    static func parse(_ id: String) -> (routineID: UUID, day: DayKey)? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let parts = id.dropFirst(idPrefix.count).split(separator: ".")
        guard parts.count >= 2, let uuid = UUID(uuidString: String(parts[0])), let day = Int(parts[1]) else { return nil }
        return (uuid, DayKey(value: day))
    }
}

/// Pure planning for scheduled routines: which notifications should be pending right now, what's up
/// next, and the week strip. Re-run on every relevant change (edit, start, finish, skip, foreground), so
/// "cancelling the nudge once you start" is simply "a started day plans no nudge".
enum RoutineReminderPlanner {
    /// iOS keeps at most 64 pending local notifications per app, shared with rest-complete, Pomodoro and
    /// festival alerts. Routines take the soonest `budget` of what they want.
    static let defaultBudget = 40
    static let horizonDays = 14

    static func plan(_ inputs: [ScheduledRoutineInput], now: Date, calendar: Calendar = .current,
                     horizonDays: Int = horizonDays, budget: Int = defaultBudget) -> [PlannedRoutineNotification] {
        let today = DayKey(now, calendar: calendar)
        // The heads-up for tomorrow+horizon's first day fires the evening before, so look one day further.
        let through = today.adding(days: horizonDays, calendar: calendar)
        var out: [PlannedRoutineNotification] = []

        for input in inputs {
            let s = input.schedule
            guard s.isEnabled, s.reminder.isOn || s.reminder.headsUp != nil,
                  !s.isFinished(today: today, completedSessions: input.completedSessions) else { continue }
            var remainingSessions: Int? = {
                if case .afterSessions(let n) = s.end { return max(0, n - input.completedSessions) }
                return nil
            }()

            let multi = s.isMultiSlot
            // Nudges would flood the Lock Screen when sessions are under an hour apart (wireframe frame 8).
            let nudgeAllowed = !multi || (s.daily?.minimumGapMinutes ?? 0) >= 60
            var doneByDay: [DayKey: Set<Int>] = [:]
            let countBefore = out.count
            for slot in s.slots(from: today, through: through, calendar: calendar) {
                // Slots are chronological: once this routine alone fills the budget, later ones can't make
                // the soonest-first cut (keeps an every-minute schedule cheap to plan).
                if out.count - countBefore >= budget { break }
                if let left = remainingSessions {
                    guard left > 0 else { break }
                    remainingSessions = left - 1
                }
                let day = slot.key.day
                if doneByDay[day] == nil {
                    doneByDay[day] = input.doneSlots(on: day, starts: s.slotStarts(on: day, calendar: calendar),
                                                     calendar: calendar)
                }
                guard !(doneByDay[day]?.contains(slot.key.index) ?? false) else { continue }
                let start = slot.start
                let index = slot.key.index
                func add(_ kind: PlannedRoutineNotification.Kind, at date: Date) {
                    guard date > now else { return }
                    let (title, body) = content(kind, input: input, start: start, calendar: calendar)
                    out.append(PlannedRoutineNotification(
                        id: PlannedRoutineNotification.makeID(routineID: input.routineID, day: day, kind: kind, slot: index),
                        kind: kind, routineID: input.routineID, day: day, fireDate: date,
                        title: title, body: body, sound: s.reminder.sound,
                        timeSensitive: s.reminder.timeSensitive && kind != .headsUp))
                }
                if s.reminder.isOn, s.reminder.everySession || index == 0 {
                    add(.reminder, at: start.addingTimeInterval(-TimeInterval(s.reminder.leadMinutes * 60)))
                    if nudgeAllowed, let nudge = s.reminder.nudgeAfterMinutes {
                        add(.nudge, at: start.addingTimeInterval(TimeInterval(nudge * 60)))
                    }
                }
                if index == 0, let heads = s.reminder.headsUp {
                    add(.headsUp, at: heads.on(day.adding(days: -1, calendar: calendar), calendar: calendar))
                }
            }
        }
        return Array(out.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }.prefix(max(0, budget)))
    }

    /// Notification copy. Plain strings so the wording is tested without `UserNotifications`.
    static func content(_ kind: PlannedRoutineNotification.Kind, input: ScheduledRoutineInput,
                        start: Date, calendar: Calendar = .current) -> (title: String, body: String) {
        let size = "\(input.blockCount) block\(input.blockCount == 1 ? "" : "s") · \(input.setCount) sets"
        let at = start.formatted(date: .omitted, time: .shortened)
        switch kind {
        case .reminder:
            let lead = input.schedule.reminder.leadMinutes
            return (lead == 0 ? "Time for \(input.name)" : "\(input.name) in \(lead) min", size)
        case .nudge:
            return ("Still on for \(input.name)?", "You planned it for \(at). Start now or skip today.")
        case .headsUp:
            return ("Tomorrow: \(input.name) at \(at)", size)
        }
    }

    // MARK: - Up next + week strip

    struct UpNext: Equatable, Sendable {
        var routineID: UUID
        var day: DayKey
        var start: Date
        /// Planned for today (still due all day, even once its start time has passed).
        var isToday: Bool
        /// Several sessions a day (prompt 144): this slot's index, how many that day, how many done.
        var slot: Int = 0
        var slotsOnDay: Int = 1
        var doneOnDay: Int = 0
        var slotKey: SlotKey { SlotKey(day: day, index: slot) }
    }

    /// The soonest planned, not-yet-done, not-skipped session within the horizon. A once-a-day plan stays
    /// due all day (7:00 is still "up next" at 9:00); with several a day, a slot more than 15 min past is
    /// treated as missed and Up next moves to the next one.
    static func upNext(_ inputs: [ScheduledRoutineInput], now: Date, calendar: Calendar = .current,
                       horizonDays: Int = horizonDays) -> UpNext? {
        let today = DayKey(now, calendar: calendar)
        let through = today.adding(days: horizonDays, calendar: calendar)
        var best: UpNext?
        for input in inputs where input.schedule.isEnabled
            && !input.schedule.isFinished(today: today, completedSessions: input.completedSessions) {
            let s = input.schedule
            var doneByDay: [DayKey: Set<Int>] = [:]
            for slot in s.slots(from: today, through: through, calendar: calendar) {
                let day = slot.key.day
                let starts = s.slotStarts(on: day, calendar: calendar)
                if doneByDay[day] == nil { doneByDay[day] = input.doneSlots(on: day, starts: starts, calendar: calendar) }
                let done = doneByDay[day] ?? []
                if done.contains(slot.key.index) { continue }
                if s.isMultiSlot, slot.start < now.addingTimeInterval(-15 * 60) { continue }
                let candidate = UpNext(routineID: input.routineID, day: day, start: slot.start, isToday: day == today,
                                       slot: slot.key.index, slotsOnDay: starts.count, doneOnDay: done.count)
                if best.map({ candidate.start < $0.start }) ?? true { best = candidate }
                break
            }
        }
        return best
    }

    struct WeekDay: Equatable, Sendable {
        enum State: Equatable, Sendable { case none, planned, done, missed, skipped }
        var day: DayKey
        var isToday: Bool
        var state: State
        /// Routine names planned (or done) that day, in schedule order.
        var names: [String]
        /// Sessions done / planned that day across schedules with several a day (0/0 when none).
        var done: Int = 0
        var planned: Int = 0
    }

    /// The current calendar week (user's first weekday) across every enabled schedule. A past planned day
    /// with no session is `.missed`; `.done` wins when anything that day was trained.
    static func week(_ inputs: [ScheduledRoutineInput], now: Date, calendar: Calendar = .current) -> [WeekDay] {
        let today = DayKey(now, calendar: calendar)
        let start = DayKey(calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now, calendar: calendar)
        return (0..<7).map { offset in
            let day = start.adding(days: offset, calendar: calendar)
            var names: [String] = []
            var anyDone = false, anyPending = false, anySkipped = false
            var doneCount = 0, plannedCount = 0
            for input in inputs where input.schedule.isEnabled {
                let s = input.schedule
                guard s.occurs(on: day, calendar: calendar) else { continue }
                if s.skippedDays.contains(day) { anySkipped = true; continue }
                names.append(input.name)
                if s.isMultiSlot {
                    let starts = s.slotStarts(on: day, calendar: calendar)
                    let done = input.doneSlots(on: day, starts: starts, calendar: calendar).count
                    doneCount += done
                    plannedCount += starts.count
                    // "Done" once the day's Habits threshold is met; partly done still reads as planned/missed.
                    if done >= s.sessionsForDayDone { anyDone = true } else { anyPending = true }
                } else if input.doneDays.contains(day) { anyDone = true } else { anyPending = true }
            }
            let state: WeekDay.State =
                anyDone ? .done
                : anyPending ? (day < today ? .missed : .planned)
                : anySkipped ? .skipped : .none
            return WeekDay(day: day, isToday: day == today, state: state, names: names,
                           done: doneCount, planned: plannedCount)
        }
    }
}
