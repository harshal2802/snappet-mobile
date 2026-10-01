import XCTest
import SwiftData
@testable import Snappet

/// Progression P2 (prompt 149): streak freezes, pause mode holding Form and the streak.
@MainActor
final class ProgressionPauseTests: XCTestCase {
    private let cal = Calendar.current
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var thisWeek: Date { cal.dateInterval(of: .weekOfYear, for: now)!.start }
    private func week(_ offset: Int) -> Date { cal.date(byAdding: .weekOfYear, value: offset, to: thisWeek)! }

    private func session(_ start: Date, routineID: UUID? = nil) -> WorkoutSession {
        var set = SetLog(actualReps: 5, actualWeight: 40, weightUnit: .kg)
        set.completedAt = start.addingTimeInterval(60)
        let ex = SessionExercise(exerciseId: "Barbell_Squat", targetSets: 1, targetReps: "5", targetRestSeconds: 90, sets: [set])
        return WorkoutSession(routineID: routineID, routineName: "Test", startedAt: start,
                              completedAt: start.addingTimeInterval(1_800), exercises: [ex])
    }

    private func pause(from: Date, to: Date?, ended: Date? = nil) -> Progression.Pause {
        .init(reason: .injury, start: from, plannedEnd: to, endedAt: ended, muteReminders: true)
    }

    // MARK: - Freezes

    func testFourWeeksEarnAFreezeThatCoversAMissedWeek() {
        // Trained weeks −6…−3, missed −2, trained −1; this week in progress.
        let trained: Set<Date> = [week(-6), week(-5), week(-4), week(-3), week(-1)]
        let s = Progression.streak(trainedWeeks: trained, pauses: [], through: thisWeek, inProgress: thisWeek)
        XCTAssertEqual(s.weeks, 5, "the freeze kept it alive; frozen weeks don't add")
        XCTAssertEqual(s.freezes, 0)
        XCTAssertEqual(s.frozenWeeks, [week(-2)])
    }

    func testWithoutAFreezeAMissedWeekResets() {
        let trained: Set<Date> = [week(-4), week(-3), week(-1)]
        let s = Progression.streak(trainedWeeks: trained, pauses: [], through: thisWeek, inProgress: thisWeek)
        XCTAssertEqual(s.weeks, 1)
        XCTAssertTrue(s.frozenWeeks.isEmpty)
    }

    func testFreezesCapAtTwoAndThisWeekCannotBreakIt() {
        let trained = Set((-12 ... -1).map(week))
        let s = Progression.streak(trainedWeeks: trained, pauses: [], through: thisWeek, inProgress: thisWeek)
        XCTAssertEqual(s.weeks, 12)
        XCTAssertEqual(s.freezes, 2, "12 weeks would earn 3; held to 2")
        XCTAssertEqual(s.nextFreezeIn, 4)
    }

    func testAPausedWeekIsHeld() {
        let trained: Set<Date> = [week(-4), week(-3), week(-1)]
        let p = pause(from: week(-2).addingTimeInterval(3_600), to: week(-1))
        let s = Progression.streak(trainedWeeks: trained, pauses: [p], through: thisWeek, inProgress: thisWeek)
        XCTAssertEqual(s.weeks, 3)
        XCTAssertTrue(s.frozenWeeks.isEmpty, "no freeze spent on a paused week")
    }

    func testStreakBonusXPUsesFreezes() {
        // Five trained weeks with a gap covered by a freeze earned at week 4.
        let sessions = [-7, -6, -5, -4, -2].map { session(week($0).addingTimeInterval(86_400 * 2)) }
        let ledger = Progression.ledger(sessions, schedules: [:])
        let last = ledger.awards[sessions.last!.id]!
        XCTAssertTrue(last.items.contains { $0.label == "🔥 5-week streak" && $0.xp == 50 }, "\(last.items)")
    }

    // MARK: - Pause and Form

    func testFormIsHeldWhilePaused() {
        let id = UUID()
        var sched = RoutineSchedule(startDay: DayKey(now.addingTimeInterval(-86_400 * 90), calendar: cal))
        sched.repeatRule = .weekly(weekdays: [1, 2, 3, 4, 5, 6, 7], everyWeeks: 1)
        // Trained every day until 10 days ago, then paused.
        let sessions = (10...40).map { session(now.addingTimeInterval(-86_400 * Double($0)), routineID: id) }
        let p = pause(from: now.addingTimeInterval(-86_400 * 9.5), to: nil)
        let unpaused = Progression.form(sessions, schedules: [id: sched], now: now)
        let held = Progression.form(sessions, schedules: [id: sched], pauses: [p], now: now)
        XCTAssertLessThan(unpaused.value, 0.75, "nine missed days would drag Form down")
        XCTAssertTrue(held.held)
        XCTAssertEqual(held.value, 1, accuracy: 0.001, "held at its value when the pause began")
    }

    func testPausedDaysAreNeutralAfterThePause() {
        let id = UUID()
        var sched = RoutineSchedule(startDay: DayKey(now.addingTimeInterval(-86_400 * 90), calendar: cal))
        sched.repeatRule = .weekly(weekdays: [1, 2, 3, 4, 5, 6, 7], everyWeeks: 1)
        // Missed days 10…19 ago were a (finished) pause; trained every other day.
        let trainedDays = Array(1...9) + Array(20...27)
        let sessions = trainedDays.map { session(now.addingTimeInterval(-86_400 * Double($0)), routineID: id) }
        let p = pause(from: cal.startOfDay(for: now.addingTimeInterval(-86_400 * 19)),
                      to: nil, ended: cal.startOfDay(for: now.addingTimeInterval(-86_400 * 9)))
        let f = Progression.form(sessions, schedules: [id: sched], pauses: [p], now: now)
        XCTAssertFalse(f.held)
        XCTAssertEqual(f.basis, .plan(done: 17, planned: 17))
    }

    func testActivePauseAndCoverage() {
        let p = pause(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400 * 6))
        XCTAssertEqual(Progression.activePause([p], now: now), p)
        XCTAssertNil(Progression.activePause([p], now: now.addingTimeInterval(86_400 * 7)))
        var ended = p
        ended.endedAt = now.addingTimeInterval(-60)
        XCTAssertNil(Progression.activePause([ended], now: now))
        let untilBack = pause(from: now.addingTimeInterval(-86_400 * 30), to: nil)
        XCTAssertTrue(untilBack.isActive(at: now))
    }

    func testPauseListRoundTripsThroughJSON() {
        let list = [pause(from: now, to: nil), pause(from: now.addingTimeInterval(-86_400 * 40), to: now.addingTimeInterval(-86_400 * 33))]
        XCTAssertEqual(PauseStore.decode(PauseStore.encode(list)), list)
        XCTAssertEqual(PauseStore.decode("garbage"), [])
    }
}
