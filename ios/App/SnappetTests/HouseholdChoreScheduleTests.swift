import XCTest
@testable import Snappet

/// Household P1 (prompt 156): when chores are due.
final class HouseholdChoreScheduleTests: XCTestCase {
    private let cal = HouseholdChoreBoardTests.cal
    private let me = UUID()
    private let choreID = UUID()

    private func day(_ n: Int, hour: Int = 9) -> Date { HouseholdChoreBoardTests.day(n, hour: hour) }

    /// Status of a chore with `repeats`, ticked by me at `done`, seen at `now`.
    private func status(_ repeats: ChoreRepeat, done: [Date], now: Date) -> ChoreStatus {
        let device = UUID()
        var ops = [ChoreOp(id: UUID(), device: device, seq: 1, at: day(-30),
                           kind: .createChore(chore: choreID, fields: ChoreFields(name: "C", repeats: repeats)))]
        for (i, d) in done.enumerated() {
            ops.append(ChoreOp(id: UUID(), device: device, seq: i + 2, at: d, kind: .complete(chore: choreID, member: me)))
        }
        let board = ChoreBoard.fold(ops)
        return board.status(of: board.chores[choreID]!, now: now, calendar: cal)
    }

    private func isDone(_ s: ChoreStatus) -> Bool { if case .done = s { return true } else { return false } }

    func testAfterDoneIsDueNDaysAfterTheLatestCompletionAndReanchors() {
        let r = ChoreRepeat.afterDone(days: 14)
        XCTAssertEqual(status(r, done: [], now: day(0)), .due(overdueDays: 0), "never done = due now")
        XCTAssertTrue(isDone(status(r, done: [day(0)], now: day(0, hour: 18))))
        XCTAssertEqual(status(r, done: [day(0)], now: day(5)), .notDue(next: DayKey(day(14), calendar: cal)))
        XCTAssertEqual(status(r, done: [day(0)], now: day(14)), .due(overdueDays: 0))
        XCTAssertEqual(status(r, done: [day(0)], now: day(16)), .due(overdueDays: 2))
        XCTAssertEqual(status(r, done: [day(0), day(16)], now: day(20)), .notDue(next: DayKey(day(30), calendar: cal)),
                       "each completion re-anchors the next date")
        XCTAssertEqual(status(r, done: [day(0), day(10)], now: day(20)), .notDue(next: DayKey(day(24), calendar: cal)),
                       "an early extra tick re-anchors too")
    }

    func testWeekdaysUseHabitScheduleDays() {
        let r = ChoreRepeat.weekdays([2, 5])   // Mon, Thu
        XCTAssertEqual(status(r, done: [], now: day(0)), .due(overdueDays: 0), "Monday")
        XCTAssertEqual(status(r, done: [], now: day(1)), .notDue(next: DayKey(day(3), calendar: cal)), "Tuesday → Thursday")
        XCTAssertEqual(status(r, done: [], now: day(3)), .due(overdueDays: 0), "Thursday")
        XCTAssertEqual(status(r, done: [], now: day(4)), .notDue(next: DayKey(day(7), calendar: cal)), "Friday → Monday")
        XCTAssertTrue(isDone(status(r, done: [day(1)], now: day(1, hour: 18))), "done on an off day still shows done")
    }

    func testWeeklyIsDueAllWeekUntilDone() {
        XCTAssertEqual(status(.weekly, done: [], now: day(3)), .due(overdueDays: 0))
        XCTAssertTrue(isDone(status(.weekly, done: [day(0)], now: day(4))), "done Monday covers Friday")
        XCTAssertEqual(status(.weekly, done: [day(0)], now: day(7)), .due(overdueDays: 0), "a new week")
    }

    func testDailyAndOnce() {
        XCTAssertEqual(status(.daily, done: [day(0)], now: day(1)), .due(overdueDays: 0))
        XCTAssertTrue(isDone(status(.daily, done: [day(1)], now: day(1, hour: 22))))
        XCTAssertEqual(status(.once, done: [], now: day(9)), .due(overdueDays: 0))
        XCTAssertTrue(isDone(status(.once, done: [day(2)], now: day(2, hour: 20))))
        XCTAssertEqual(status(.once, done: [day(2)], now: day(3)), .notDue(next: nil))
    }

    func testWeekKeyAndSummaries() {
        XCTAssertEqual(ChoreSchedule.weekKey(day(3), calendar: cal), "2026-10-05")
        XCTAssertEqual(ChoreSchedule.weekKey(day(7), calendar: cal), "2026-10-12")
        XCTAssertEqual(ChoreSchedule.summary(.afterDone(days: 14), calendar: cal), "Every 14 days after it's done")
        XCTAssertEqual(ChoreSchedule.summary(.weekdays([5, 2]), calendar: cal), "Mon, Thu", "week order, Monday first")
        XCTAssertEqual(ChoreSchedule.summary(.weekdays([]), calendar: cal), "Daily")
    }
}
