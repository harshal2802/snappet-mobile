import XCTest
@testable import Snappet

/// Pure logic behind the issue-#80 celebration moments: the habit streak math (shared by
/// the list UI and the toggle-time milestone decision), milestone crossing, and the
/// Kilter first-send-of-a-grade decision.
final class CelebrationTests: XCTestCase {

    private let calendar = Calendar.current

    private func days(_ offsets: [Int], from today: Date) -> Set<Date> {
        let start = calendar.startOfDay(for: today)
        return Set(offsets.compactMap { calendar.date(byAdding: .day, value: -$0, to: start) })
    }

    // MARK: - Streak math (extracted from HabitRootView)

    func testEmptyDaysIsZeroStreak() {
        XCTAssertEqual(HabitMilestones.streak(days: [], today: .now, calendar: calendar), 0)
    }

    func testConsecutiveDaysEndingTodayCount() {
        let today = Date.now
        XCTAssertEqual(HabitMilestones.streak(days: days([0, 1, 2], from: today),
                                              today: today, calendar: calendar), 3)
    }

    func testStreakStaysAliveUntilAFullMissedDay() {
        let today = Date.now
        // Done yesterday + the day before, not yet today: still a 2-streak.
        XCTAssertEqual(HabitMilestones.streak(days: days([1, 2], from: today),
                                              today: today, calendar: calendar), 2)
    }

    func testGapBreaksTheStreak() {
        let today = Date.now
        // Last completion two days ago: broken.
        XCTAssertEqual(HabitMilestones.streak(days: days([2, 3], from: today),
                                              today: today, calendar: calendar), 0)
    }

    // MARK: - Milestone crossing

    func testCrossingSeven() {
        XCTAssertEqual(HabitMilestones.crossed(previousStreak: 6, newStreak: 7), 7)
    }

    func testAlreadyPastSevenDoesNotRefire() {
        XCTAssertNil(HabitMilestones.crossed(previousStreak: 7, newStreak: 8))
    }

    func testCrossingThirty() {
        XCTAssertEqual(HabitMilestones.crossed(previousStreak: 29, newStreak: 30), 30)
    }

    func testBackfillJumpReportsTheHighestCrossedMilestone() {
        // A backfill can bridge a gap and jump the streak past several milestones at
        // once — exactly one burst, for the highest.
        XCTAssertEqual(HabitMilestones.crossed(previousStreak: 5, newStreak: 31), 30)
    }

    func testOrdinaryDayIsNoMilestone() {
        XCTAssertNil(HabitMilestones.crossed(previousStreak: 0, newStreak: 1))
        XCTAssertNil(HabitMilestones.crossed(previousStreak: 10, newStreak: 11))
    }

    func testNoCrossingWhenStreakResets() {
        XCTAssertNil(HabitMilestones.crossed(previousStreak: 12, newStreak: 1))
    }

    // MARK: - Kilter first send of a grade

    func testFirstSentAtGradeCelebrates() {
        XCTAssertTrue(KilterMilestones.isFirstSend(status: .sent, priorSendCountAtGrade: 0))
        XCTAssertTrue(KilterMilestones.isFirstSend(status: .flash, priorSendCountAtGrade: 0))
    }

    func testRepeatSendAtGradeDoesNot() {
        XCTAssertFalse(KilterMilestones.isFirstSend(status: .sent, priorSendCountAtGrade: 3))
    }

    func testNonSendsNeverCelebrate() {
        XCTAssertFalse(KilterMilestones.isFirstSend(status: .attempt, priorSendCountAtGrade: 0))
        XCTAssertFalse(KilterMilestones.isFirstSend(status: .project, priorSendCountAtGrade: 0))
    }
}
