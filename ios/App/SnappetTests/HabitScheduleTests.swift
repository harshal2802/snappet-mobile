import XCTest
@testable import Snappet

/// Prompt 137 — habits that know their days: scheduled-day streaks, excused skips, the rate, and the
/// "due today" filter Home + the widget share.
final class HabitScheduleTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 2
        return c
    }()

    /// 2026-09-28 is a Monday.
    private func d(_ v: Int) -> Date { DayKey(value: v).date(calendar: cal) }
    private func noon(_ v: Int) -> Date { d(v).addingTimeInterval(12 * 3600) }
    private let mwf = HabitSchedule(weekdays: [2, 4, 6])

    // MARK: - Every-day habit is unchanged

    func testEveryDayStreakMatchesTheClassicRule() {
        let days: Set<Date> = [d(20260928), d(20260929)]
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20260929), calendar: cal), 2)
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20260930), calendar: cal), 2, "today still open")
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20261001), calendar: cal), 0, "a full day missed")
        XCTAssertEqual(HabitMilestones.streak(days: [], today: noon(20261001), calendar: cal), 0)
    }

    // MARK: - Scheduled

    func testRestDaysNeitherHelpNorBreakTheStreak() {
        // Mon, Wed, Fri done; checked on the following Sunday — Sat/Sun aren't due.
        let days: Set<Date> = [d(20260928), d(20260930), d(20261002)]
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20261004), schedule: mwf, calendar: cal), 3)
        // Every-day rule would have said 0 by Sunday.
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20261004), calendar: cal), 0)
    }

    func testAMissedDueDayEndsIt() {
        let days: Set<Date> = [d(20260928), d(20261002)]   // Wed missed
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20261002), schedule: mwf, calendar: cal), 1)
    }

    func testOffScheduleCompletionCountsAsABonus() {
        let days: Set<Date> = [d(20260928), d(20260929), d(20260930)]   // Tue is off-schedule but done
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20260930), schedule: mwf, calendar: cal), 3)
    }

    func testExcusedSkipKeepsTheStreakAndMissedPolicyBreaksIt() {
        let days: Set<Date> = [d(20260928), d(20261002)]   // Wed skipped
        let excused = HabitSchedule.resolve(weekdays: [2, 4, 6], skippedDayKeys: [20260930],
                                            skipsBreakStreak: nil, linked: [])
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20261002), schedule: excused, calendar: cal), 2)
        let strict = HabitSchedule.resolve(weekdays: [2, 4, 6], skippedDayKeys: [20260930],
                                           skipsBreakStreak: true, linked: [])
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20261002), schedule: strict, calendar: cal), 1)
    }

    func testLinkedRoutineScheduleDecidesTheDays() {
        var every3 = RoutineSchedule(startDay: DayKey(value: 20260928))
        every3.repeatRule = .everyDays(3)   // 28, 1, 4 …
        let linked = HabitSchedule.resolve(weekdays: [2], skippedDayKeys: nil, skipsBreakStreak: nil, linked: [every3])
        XCTAssertTrue(linked.isLinked)
        XCTAssertTrue(linked.isScheduled(DayKey(value: 20261001), calendar: cal))
        XCTAssertFalse(linked.isScheduled(DayKey(value: 20261005), calendar: cal), "own weekdays ignored while linked")
        let days: Set<Date> = [d(20260928), d(20261001)]
        XCTAssertEqual(HabitMilestones.streak(days: days, today: noon(20261003), schedule: linked, calendar: cal), 2)
    }

    func testPausedLinkedRoutineMakesNothingDue() {
        var s = RoutineSchedule(startDay: DayKey(value: 20260928))
        s.isEnabled = false
        let linked = HabitSchedule(weekdays: nil, routineSchedules: [s])
        XCTAssertFalse(linked.isDue(DayKey(value: 20260930), calendar: cal))
    }

    func testResolveTreatsAllSevenDaysAsEveryDay() {
        XCTAssertTrue(HabitSchedule.resolve(weekdays: [1, 2, 3, 4, 5, 6, 7], skippedDayKeys: nil,
                                            skipsBreakStreak: nil, linked: []).isEveryDay)
        XCTAssertTrue(HabitSchedule.resolve(weekdays: [], skippedDayKeys: nil, skipsBreakStreak: nil, linked: []).isEveryDay)
    }

    // MARK: - Rate

    func testRateCountsDueDaysOnly() {
        // Created Mon 28; checked Sun 4 Oct → due Mon/Wed/Fri = 3, done 2.
        let days: Set<Date> = [d(20260928), d(20260930)]
        let rate = HabitMilestones.completionRate(days: days, createdAt: d(20260928), today: noon(20261004),
                                                  schedule: mwf, calendar: cal)
        XCTAssertEqual(rate, 2.0 / 3.0, accuracy: 0.001)
        // Every-day habit: 2 of the 6 finished days (an open today isn't a miss).
        let daily = HabitMilestones.completionRate(days: days, createdAt: d(20260928), today: noon(20261004), calendar: cal)
        XCTAssertEqual(daily, 2.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(HabitMilestones.completionRate(days: [], createdAt: d(20261004), today: noon(20261004),
                                                      calendar: cal), 0, "day one opens at 0 due, not a miss")
    }

    func testRateIsCappedAndHandlesNothingDue() {
        let days: Set<Date> = [d(20260928), d(20260929), d(20260930)]
        XCTAssertEqual(HabitMilestones.completionRate(days: days, createdAt: d(20260928), today: noon(20260930),
                                                      schedule: mwf, calendar: cal), 1)
        XCTAssertEqual(HabitMilestones.completionRate(days: [], createdAt: d(20260929), today: noon(20260929),
                                                      schedule: mwf, calendar: cal), 0)
    }

    // MARK: - Due today (Home / widget)

    @MainActor
    func testHabitsTodayCountsOnlyDueOrDone() {
        let due = Habit(name: "Water")
        let offToday = Habit(name: "Gym")
        let doneAnyway = Habit(name: "Stretch")
        let completions = [HabitCompletion(habitID: doneAnyway.id, day: d(20260929))]
        let h = TodayDigest.habitsToday(habits: [due, offToday, doneAnyway], completions: completions,
                                        now: noon(20260929), calendar: cal, dueIDs: [due.id])
        XCTAssertEqual(h, TodayDigest.HabitsToday(remaining: 1, total: 2))
        XCTAssertNil(TodayDigest.habitsToday(habits: [offToday], completions: [], now: noon(20260929),
                                             calendar: cal, dueIDs: []), "nothing due → card hidden")
    }
}
