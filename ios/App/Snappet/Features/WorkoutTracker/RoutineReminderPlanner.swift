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

    static func makeID(routineID: UUID, day: DayKey, kind: Kind) -> String {
        "\(idPrefix)\(routineID.uuidString).\(day.value).\(kind.rawValue)"
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

            for day in s.days(from: today, through: through, calendar: calendar) {
                if let left = remainingSessions {
                    guard left > 0 else { break }
                    remainingSessions = left - 1
                }
                guard !input.doneDays.contains(day) else { continue }
                let start = s.startTime(on: day, calendar: calendar)
                func add(_ kind: PlannedRoutineNotification.Kind, at date: Date) {
                    guard date > now else { return }
                    let (title, body) = content(kind, input: input, start: start, calendar: calendar)
                    out.append(PlannedRoutineNotification(
                        id: PlannedRoutineNotification.makeID(routineID: input.routineID, day: day, kind: kind),
                        kind: kind, routineID: input.routineID, day: day, fireDate: date,
                        title: title, body: body, sound: s.reminder.sound,
                        timeSensitive: s.reminder.timeSensitive && kind != .headsUp))
                }
                if s.reminder.isOn {
                    add(.reminder, at: start.addingTimeInterval(-TimeInterval(s.reminder.leadMinutes * 60)))
                    if let nudge = s.reminder.nudgeAfterMinutes {
                        add(.nudge, at: start.addingTimeInterval(TimeInterval(nudge * 60)))
                    }
                }
                if let heads = s.reminder.headsUp {
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
    }

    /// The soonest planned, not-yet-done, not-skipped occurrence within the horizon — today's counts
    /// until the day ends, so a 7:00 plan is still "up next" at 9:00 if you haven't trained yet.
    static func upNext(_ inputs: [ScheduledRoutineInput], now: Date, calendar: Calendar = .current,
                       horizonDays: Int = horizonDays) -> UpNext? {
        let today = DayKey(now, calendar: calendar)
        let through = today.adding(days: horizonDays, calendar: calendar)
        var best: UpNext?
        for input in inputs where input.schedule.isEnabled
            && !input.schedule.isFinished(today: today, completedSessions: input.completedSessions) {
            guard let day = input.schedule.days(from: today, through: through, calendar: calendar)
                .first(where: { !input.doneDays.contains($0) }) else { continue }
            let candidate = UpNext(routineID: input.routineID, day: day,
                                   start: input.schedule.startTime(on: day, calendar: calendar),
                                   isToday: day == today)
            if best.map({ candidate.start < $0.start }) ?? true { best = candidate }
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
            for input in inputs where input.schedule.isEnabled {
                let s = input.schedule
                guard s.occurs(on: day, calendar: calendar) else { continue }
                if s.skippedDays.contains(day) { anySkipped = true; continue }
                names.append(input.name)
                if input.doneDays.contains(day) { anyDone = true } else { anyPending = true }
            }
            let state: WeekDay.State =
                anyDone ? .done
                : anyPending ? (day < today ? .missed : .planned)
                : anySkipped ? .skipped : .none
            return WeekDay(day: day, isToday: day == today, state: state, names: names)
        }
    }
}
