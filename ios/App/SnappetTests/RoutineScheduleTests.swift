import XCTest
@testable import Snappet

/// Prompt 136 — routine schedules: occurrence math, the terse codec, and the reminder planner.
final class RoutineScheduleTests: XCTestCase {

    /// Fixed calendar so the tests don't depend on the machine's locale / zone. Week starts Monday.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 2
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    private func day(_ v: Int) -> DayKey { DayKey(value: v) }
    private func at(_ v: Int, _ h: Int, _ m: Int = 0) -> Date { ScheduleTime(hour: h, minute: m).on(day(v), calendar: cal) }

    // 2026-09-28 is a Monday.
    private func weekly(_ days: Set<Int>, every: Int = 1, start: Int = 20260928) -> RoutineSchedule {
        var s = RoutineSchedule(startDay: day(start))
        s.repeatRule = .weekly(weekdays: days, everyWeeks: every)
        return s
    }

    // MARK: - DayKey

    func testDayKeyRoundTripsAndAddsAcrossMonths() {
        XCTAssertEqual(DayKey(day(20260930).date(calendar: cal), calendar: cal), day(20260930))
        XCTAssertEqual(day(20260930).adding(days: 1, calendar: cal), day(20261001))
        XCTAssertEqual(day(20261231).adding(days: 1, calendar: cal), day(20270101))
    }

    // MARK: - Occurrences

    func testWeeklyMonWedFri() {
        let s = weekly([2, 4, 6])
        let days = s.days(from: day(20260928), through: day(20261004), calendar: cal)
        XCTAssertEqual(days, [day(20260928), day(20260930), day(20261002)])
    }

    func testEveryTwoWeeksAlternatesFromTheStartWeek() {
        let s = weekly([2], every: 2, start: 20260930)   // starts Wed; Mon of that week is before start
        let days = s.days(from: day(20260928), through: day(20261102), calendar: cal)
        // Week of 28 Sep is week 0 (its Monday is before the start day → not planned), then every other week.
        XCTAssertEqual(days, [day(20261012), day(20261026)])
    }

    func testEveryNDaysAndOnce() {
        var s = RoutineSchedule(startDay: day(20260928))
        s.repeatRule = .everyDays(3)
        XCTAssertEqual(s.days(from: day(20260928), through: day(20261006), calendar: cal),
                       [day(20260928), day(20261001), day(20261004)])
        s.repeatRule = .once
        XCTAssertEqual(s.days(from: day(20260901), through: day(20261231), calendar: cal), [day(20260928)])
        XCTAssertTrue(s.isFinished(today: day(20260929), completedSessions: 0))
    }

    func testEndOnDayIsInclusiveAndSkipsAreExcluded() {
        var s = weekly([2, 4, 6])
        s.end = .onDay(day(20260930))
        s.skippedDays = [day(20260928)]
        XCTAssertEqual(s.days(from: day(20260901), through: day(20261031), calendar: cal), [day(20260930)])
        XCTAssertTrue(s.isFinished(today: day(20261001), completedSessions: 0))
    }

    func testPerDayTimeOverridesTheDefault() {
        var s = weekly([2, 6])
        s.time = ScheduleTime(hour: 7, minute: 0)
        s.perDayTimes = [6: ScheduleTime(hour: 18, minute: 30)]
        XCTAssertEqual(s.startTime(on: day(20260928), calendar: cal), at(20260928, 7))
        XCTAssertEqual(s.startTime(on: day(20261002), calendar: cal), at(20261002, 18, 30))
    }

    func testStartTimeSurvivesTheDSTChange() {
        // US clocks fall back on 1 Nov 2026: 7:00 must still be 7:00 local, not 6:00.
        let s = weekly([1])   // Sundays
        let d = s.startTime(on: day(20261101), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: d), 7)
    }

    func testWeekdayOrderFollowsTheCalendar() {
        XCTAssertEqual(RoutineSchedule.orderedWeekdays(cal), [2, 3, 4, 5, 6, 7, 1])
        var sunday = cal; sunday.firstWeekday = 1
        XCTAssertEqual(RoutineSchedule.orderedWeekdays(sunday), [1, 2, 3, 4, 5, 6, 7])
    }

    func testSummary() {
        // Foundation separates "7:00" and "AM" with a narrow no-break space.
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(plain(weekly([2, 4, 6]).summary(calendar: cal)), "Mon · Wed · Fri at 7:00 AM")
        var s = weekly([2])
        s.repeatRule = .everyDays(3)
        XCTAssertEqual(plain(s.summary(calendar: cal)), "Every 3 days at 7:00 AM")
    }

    // MARK: - Codec

    func testCodecRoundTripsEveryField() throws {
        var s = weekly([2, 4, 6], every: 2)
        s.isEnabled = false
        s.time = ScheduleTime(hour: 6, minute: 45)
        s.perDayTimes = [6: ScheduleTime(hour: 18, minute: 0)]
        s.end = .afterSessions(12)
        s.reminder = ScheduleReminder(isOn: true, leadMinutes: 5, nudgeAfterMinutes: nil,
                                      headsUp: ScheduleTime(hour: 21, minute: 0), sound: false, timeSensitive: true)
        s.skippedDays = [day(20260930)]
        let back = try JSONDecoder().decode(RoutineSchedule.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testDefaultsAreOmittedAndMissingKeysDecodeToDefaults() throws {
        let s = weekly([2, 4, 6])
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(json.contains("\"rm\""), "default reminder must not bloat the QR: \(json)")
        let minimal = #"{"sd":20260928,"wd":[2,4,6]}"#
        let decoded = try JSONDecoder().decode(RoutineSchedule.self, from: Data(minimal.utf8))
        XCTAssertEqual(decoded.reminder, ScheduleReminder())
        XCTAssertEqual(decoded.time, ScheduleTime(hour: 7, minute: 0))
        XCTAssertTrue(decoded.isEnabled)
    }

    func testForSharingDropsSkipHistory() {
        var s = weekly([2])
        s.skippedDays = [day(20260928)]
        XCTAssertTrue(s.forSharing.skippedDays.isEmpty)
    }

    // MARK: - Planner

    private func input(_ s: RoutineSchedule, done: Set<DayKey> = [], completed: Int = 0,
                       id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                       name: String = "Push Day") -> ScheduledRoutineInput {
        ScheduledRoutineInput(routineID: id, name: name, blockCount: 6, setCount: 18, schedule: s,
                              doneDays: done, completedSessions: completed)
    }

    func testPlanReminderAndNudgeForUpcomingDaysOnly() {
        let s = weekly([2, 4, 6])   // default: 15 min before, nudge +30
        let now = at(20260930, 7, 10)   // Wed 7:10 — today's reminder has passed, nudge (7:30) hasn't
        let plan = RoutineReminderPlanner.plan([input(s)], now: now, calendar: cal, horizonDays: 3)
        XCTAssertEqual(plan.map(\.kind), [.nudge, .reminder, .nudge])
        XCTAssertEqual(plan.map(\.fireDate), [at(20260930, 7, 30), at(20261002, 6, 45), at(20261002, 7, 30)])
        XCTAssertEqual(plan[1].title, "Push Day in 15 min")
        XCTAssertEqual(plan[1].body, "6 blocks · 18 sets")
    }

    func testStartingTodayCancelsItsNudge() {
        let s = weekly([2, 4, 6])
        let now = at(20260930, 7, 10)
        let plan = RoutineReminderPlanner.plan([input(s, done: [day(20260930)])], now: now, calendar: cal, horizonDays: 3)
        XCTAssertFalse(plan.contains { $0.day == day(20260930) })
    }

    func testSkippedDayPlansNothing() {
        var s = weekly([2, 4, 6])
        s.skippedDays = [day(20261002)]
        let plan = RoutineReminderPlanner.plan([input(s)], now: at(20260930, 12), calendar: cal, horizonDays: 3)
        XCTAssertTrue(plan.isEmpty)
    }

    func testHeadsUpFiresTheEveningBeforeAndPausedPlansNothing() {
        var s = weekly([6])
        s.reminder.isOn = false
        s.reminder.headsUp = ScheduleTime(hour: 20, minute: 0)
        let plan = RoutineReminderPlanner.plan([input(s)], now: at(20260930, 12), calendar: cal, horizonDays: 3)
        XCTAssertEqual(plan.map(\.kind), [.headsUp])
        XCTAssertEqual(plan.first?.fireDate, at(20261001, 20))
        s.isEnabled = false
        XCTAssertTrue(RoutineReminderPlanner.plan([input(s)], now: at(20260930, 12), calendar: cal).isEmpty)
    }

    func testAfterSessionsCapsWhatIsPlanned() {
        var s = weekly([2, 4, 6])
        s.reminder.nudgeAfterMinutes = nil
        s.end = .afterSessions(3)
        let plan = RoutineReminderPlanner.plan([input(s, completed: 2)], now: at(20260928, 0), calendar: cal)
        XCTAssertEqual(plan.count, 1, "one session left → one reminder")
        XCTAssertTrue(RoutineReminderPlanner.plan([input(s, completed: 3)], now: at(20260928, 0), calendar: cal).isEmpty)
    }

    func testBudgetKeepsTheSoonest() {
        let s = weekly([1, 2, 3, 4, 5, 6, 7])
        let plan = RoutineReminderPlanner.plan([input(s)], now: at(20260928, 0), calendar: cal, budget: 5)
        XCTAssertEqual(plan.count, 5)
        XCTAssertEqual(plan.map(\.fireDate), plan.map(\.fireDate).sorted())
        XCTAssertEqual(plan.first?.fireDate, at(20260928, 6, 45))
    }

    func testNotificationIDRoundTrips() {
        let id = UUID()
        let raw = PlannedRoutineNotification.makeID(routineID: id, day: day(20261002), kind: .nudge)
        XCTAssertEqual(PlannedRoutineNotification.parse(raw)?.routineID, id)
        XCTAssertEqual(PlannedRoutineNotification.parse(raw)?.day, day(20261002))
        XCTAssertNil(PlannedRoutineNotification.parse("snappet.workout.restComplete"))
    }

    // MARK: - Up next + week

    func testUpNextStaysOnTodayUntilDoneThenMovesOn() {
        let s = weekly([2, 4, 6])
        let late = at(20260930, 21)   // Wed evening, 7:00 plan not done
        XCTAssertEqual(RoutineReminderPlanner.upNext([input(s)], now: late, calendar: cal)?.day, day(20260930))
        XCTAssertEqual(RoutineReminderPlanner.upNext([input(s)], now: late, calendar: cal)?.isToday, true)
        let done = RoutineReminderPlanner.upNext([input(s, done: [day(20260930)])], now: late, calendar: cal)
        XCTAssertEqual(done?.day, day(20261002))
    }

    func testUpNextPicksTheEarliestAcrossRoutines() {
        let a = input(weekly([6]), id: UUID(), name: "Legs")
        var early = weekly([6]); early.time = ScheduleTime(hour: 6, minute: 0)
        let b = input(early, id: UUID(), name: "Push")
        XCTAssertEqual(RoutineReminderPlanner.upNext([a, b], now: at(20260930, 12), calendar: cal)?.routineID, b.routineID)
    }

    func testWeekStripStates() {
        var s = weekly([2, 4, 6])
        s.skippedDays = [day(20261002)]
        let week = RoutineReminderPlanner.week([input(s, done: [day(20260928)])], now: at(20260930, 12), calendar: cal)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.first?.day, day(20260928), "week starts on the calendar's first weekday")
        XCTAssertEqual(week.map(\.state), [.done, .none, .planned, .none, .skipped, .none, .none])
        XCTAssertTrue(week[2].isToday)
        let later = RoutineReminderPlanner.week([input(s)], now: at(20261001, 12), calendar: cal)
        XCTAssertEqual(later[0].state, .missed)
        XCTAssertEqual(later[2].state, .missed)
    }
}
