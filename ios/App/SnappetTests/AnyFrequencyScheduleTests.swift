import XCTest
@testable import Snappet

/// Prompt 144 — any-frequency schedules: several sessions a day (set times / every N min·h in a window),
/// per-slot planning within iOS's notification budget, and back-compat with once-a-day schedules.
final class AnyFrequencyScheduleTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 2
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    private func day(_ v: Int) -> DayKey { DayKey(value: v) }
    private func at(_ v: Int, _ h: Int, _ m: Int = 0) -> Date { ScheduleTime(hour: h, minute: m).on(day(v), calendar: cal) }
    private func t(_ h: Int, _ m: Int = 0) -> ScheduleTime { ScheduleTime(hour: h, minute: m) }

    /// Mon–Fri (2026-09-28 is a Monday), every 2 h from 8:00 to 20:00.
    private var everyTwoHours: RoutineSchedule {
        var s = RoutineSchedule(startDay: day(20260928))
        s.repeatRule = .weekly(weekdays: [2, 3, 4, 5, 6], everyWeeks: 1)
        s.daily = .every(minutes: 120, from: t(8), until: t(20))
        s.reminder.leadMinutes = 0
        s.reminder.nudgeAfterMinutes = 30
        return s
    }

    private func input(_ s: RoutineSchedule, starts: [Date] = []) -> ScheduledRoutineInput {
        ScheduledRoutineInput(routineID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!, name: "Abrahangs",
                              blockCount: 1, setCount: 1, schedule: s,
                              doneDays: Set(starts.map { DayKey($0, calendar: cal) }), completedSessions: 0,
                              sessionStarts: starts)
    }

    // MARK: - Slots

    func testEveryNMinutesWithinAWindow() {
        XCTAssertEqual(DailyRepeat.every(minutes: 120, from: t(8), until: t(20)).slotTimes.count, 7)
        XCTAssertEqual(DailyRepeat.every(minutes: 15, from: t(9), until: t(17)).slotTimes.count, 33)
        XCTAssertEqual(DailyRepeat.every(minutes: 1, from: t(0), until: t(23, 59)).slotTimes.count, 1440)
        XCTAssertEqual(DailyRepeat.every(minutes: 120, from: t(8), until: t(20)).minimumGapMinutes, 120)
    }

    func testSetTimesAreSortedAndDeduplicated() {
        let d = DailyRepeat.times([t(21), t(7), t(12, 30), t(7)])
        XCTAssertEqual(d.slotTimes, [t(7), t(12, 30), t(21)])
    }

    func testSlotsSkipOneSlotOrAWholeDay() {
        var s = everyTwoHours
        s.skippedSlots = [SlotKey(day: day(20260928), index: 0)]
        s.skippedDays = [day(20260929)]
        let slots = s.slots(from: day(20260928), through: day(20260930), calendar: cal)
        XCTAssertEqual(slots.filter { $0.key.day == day(20260928) }.count, 6)
        XCTAssertTrue(slots.allSatisfy { $0.key.day != day(20260929) })
        XCTAssertEqual(slots.filter { $0.key.day == day(20260930) }.count, 7)
    }

    func testOnceADayIsUnchanged() {
        var s = RoutineSchedule(startDay: day(20260928))
        s.repeatRule = .weekly(weekdays: [2], everyWeeks: 1)
        XCTAssertFalse(s.isMultiSlot)
        XCTAssertEqual(s.slotStarts(on: day(20260928), calendar: cal), [at(20260928, 7)])
    }

    // MARK: - Codec

    func testCodecRoundTripsAndOlderBuildsKeepTheFirstTime() throws {
        var s = everyTwoHours
        s.time = t(8)
        s.skippedSlots = [SlotKey(day: day(20260928), index: 3)]
        s.doneAfterSessions = 3
        s.reminder.everySession = false
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(RoutineSchedule.self, from: data), s)
        // An older decoder only knows `t`: it still gets 8:00.
        struct Old: Decodable { let t: Int }
        XCTAssertEqual(try JSONDecoder().decode(Old.self, from: data).t, 8 * 60)
    }

    func testSharingDropsSkippedSlots() {
        var s = everyTwoHours
        s.skippedSlots = [SlotKey(day: day(20260928), index: 1)]
        XCTAssertTrue(s.forSharing.skippedSlots.isEmpty)
    }

    // MARK: - Planner

    func testOneReminderPerSessionWithSlotIDs() {
        let plan = RoutineReminderPlanner.plan([input(everyTwoHours)], now: at(20260928, 9), calendar: cal,
                                               horizonDays: 0)
        let reminders = plan.filter { $0.kind == .reminder }
        XCTAssertEqual(reminders.map(\.fireDate), (5...10).map { at(20260928, 2 * $0) }, "10:00 … 20:00 still ahead")
        XCTAssertEqual(PlannedRoutineNotification.slot(of: reminders[0].id), 1)
        XCTAssertEqual(PlannedRoutineNotification.parse(reminders[0].id)?.day, day(20260928))
        XCTAssertEqual(plan.filter { $0.kind == .nudge }.count, 6 + 0, "two hours apart → nudges allowed")
    }

    func testNudgesAreOffUnderAnHourApart() {
        var s = everyTwoHours
        s.daily = .every(minutes: 30, from: t(9), until: t(12))
        let plan = RoutineReminderPlanner.plan([input(s)], now: at(20260928, 8), calendar: cal, horizonDays: 0)
        XCTAssertTrue(plan.allSatisfy { $0.kind == .reminder })
        XCTAssertEqual(plan.count, 7)
    }

    func testFirstOfTheDayOnly() {
        var s = everyTwoHours
        s.reminder.everySession = false
        s.reminder.nudgeAfterMinutes = nil
        let plan = RoutineReminderPlanner.plan([input(s)], now: at(20260928, 7), calendar: cal, horizonDays: 1)
        XCTAssertEqual(plan.map(\.fireDate), [at(20260928, 8), at(20260929, 8)])
    }

    func testAnEveryMinuteScheduleStaysWithinBudgetAndSoonestFirst() {
        var s = everyTwoHours
        s.daily = .every(minutes: 1, from: t(0), until: t(23, 59))
        let plan = RoutineReminderPlanner.plan([input(s)], now: at(20260928, 12), calendar: cal)
        XCTAssertEqual(plan.count, RoutineReminderPlanner.defaultBudget)
        XCTAssertEqual(plan.first?.fireDate, at(20260928, 12, 1))
        XCTAssertEqual(plan.map(\.fireDate), plan.map(\.fireDate).sorted())
    }

    func testASessionCountsForItsNearestSlot() {
        let i = input(everyTwoHours, starts: [at(20260928, 9, 50)])   // nearest = 10:00 (slot 1)
        let done = i.doneSlots(on: day(20260928), starts: everyTwoHours.slotStarts(on: day(20260928), calendar: cal),
                               calendar: cal)
        XCTAssertEqual(done, [1])
        let plan = RoutineReminderPlanner.plan([i], now: at(20260928, 9), calendar: cal, horizonDays: 0)
        XCTAssertFalse(plan.contains { PlannedRoutineNotification.slot(of: $0.id) == 1 }, "10:00 is done")
    }

    func testHeadsUpOnlyForTheFirstSession() {
        var s = everyTwoHours
        s.reminder.isOn = false
        s.reminder.headsUp = t(20)
        let plan = RoutineReminderPlanner.plan([input(s)], now: at(20260928, 12), calendar: cal, horizonDays: 1)
        XCTAssertEqual(plan.map(\.kind), [.headsUp])
    }

    // MARK: - Up next + week

    func testUpNextMovesPastAMissedSession() {
        let up = RoutineReminderPlanner.upNext([input(everyTwoHours)], now: at(20260928, 10, 20), calendar: cal)
        XCTAssertEqual(up?.start, at(20260928, 12), "10:00 is 20 min past → missed; next is 12:00")
        XCTAssertEqual(up?.slot, 2)
        XCTAssertEqual(up?.slotsOnDay, 7)
        let soon = RoutineReminderPlanner.upNext([input(everyTwoHours)], now: at(20260928, 10, 10), calendar: cal)
        XCTAssertEqual(soon?.start, at(20260928, 10), "within 15 min it's still up next")
    }

    func testWeekCountsSessionsAndDayDoneThreshold() {
        var s = everyTwoHours
        s.doneAfterSessions = 2
        let starts = [at(20260928, 8), at(20260928, 10)]
        let week = RoutineReminderPlanner.week([input(s, starts: starts)], now: at(20260929, 9), calendar: cal)
        XCTAssertEqual(week[0].done, 2)
        XCTAssertEqual(week[0].planned, 7)
        XCTAssertEqual(week[0].state, .done, "2 sessions meet 'done after 2'")
        XCTAssertEqual(s.sessionsForDayDone, 2)
    }

    func testSummaryDescribesTheFrequency() {
        let text = everyTwoHours.summary(calendar: cal).replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(text, "Mon · Tue · Wed · Thu · Fri · every 2 h, 8:00 AM–8:00 PM")
    }
}
