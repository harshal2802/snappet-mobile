import XCTest
import SwiftData
@testable import Snappet

/// Unit tests for the **pure** `TodayDigest` derivations behind the Home tab's actionable Today
/// cards (#71): habits remaining, the resume-workout candidate, today's focus minutes, the budget
/// month pace, and the Kilter plan hint. Each derivation's `nil` IS the card's render gate, so the
/// nil cases are asserted as carefully as the values. Time is injected (fixed `now` + a UTC
/// gregorian calendar) — no wall-clock flakiness.
@MainActor
final class TodayDigestTests: XCTestCase {

    /// Kept as a property: a `ModelContext` does NOT retain its `ModelContainer`, so letting the
    /// container deallocate makes every later SwiftData call trap (the ExpenseGroupDeletionTests
    /// gotcha). Model rows are inserted so their backing data is container-backed.
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    /// Fixed, DST-free clock: 2026-06-10 12:00:00 UTC — mid-month, midday.
    private let now = Date(timeIntervalSince1970: 1_781_092_800)
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var todayStart: Date { cal.startOfDay(for: now) }
    private func daysAgo(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now)! }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    // MARK: - Habits

    func testHabitsNilWithoutAnyHabits() {
        XCTAssertNil(TodayDigest.habitsToday(habits: [], completions: [], now: now, calendar: cal))
    }

    func testHabitsCountsOnlyTodayCompletions() {
        let read = Habit(name: "Read")
        let run = Habit(name: "Run")
        let stretch = Habit(name: "Stretch")
        for row in [read, run, stretch] { context.insert(row) }
        // Read done today (mid-day timestamp — must normalize to start-of-day to count),
        // Run done only yesterday, Stretch never.
        let doneToday = HabitCompletion(habitID: read.id, day: todayStart.addingTimeInterval(9 * 3600))
        let doneYesterday = HabitCompletion(habitID: run.id, day: cal.startOfDay(for: daysAgo(1)))
        for row in [doneToday, doneYesterday] { context.insert(row) }

        let h = TodayDigest.habitsToday(habits: [read, run, stretch],
                                        completions: [doneToday, doneYesterday],
                                        now: now, calendar: cal)
        XCTAssertEqual(h, TodayDigest.HabitsToday(remaining: 2, total: 3))
        XCTAssertFalse(h!.allDone)
    }

    func testHabitsAllDoneAndDuplicateCompletionsCountOnce() {
        let read = Habit(name: "Read")
        context.insert(read)
        let a = HabitCompletion(habitID: read.id, day: todayStart)
        let b = HabitCompletion(habitID: read.id, day: todayStart)   // duplicate row
        for row in [a, b] { context.insert(row) }

        let h = TodayDigest.habitsToday(habits: [read], completions: [a, b],
                                        now: now, calendar: cal)
        XCTAssertEqual(h, TodayDigest.HabitsToday(remaining: 0, total: 1))
        XCTAssertTrue(h!.allDone)
    }

    // MARK: - Resume workout

    func testResumeNilWhenNothingActive() {
        let done = WorkoutSession(routineName: "Push Day",
                                  startedAt: daysAgo(1), completedAt: now)
        context.insert(done)
        XCTAssertNil(TodayDigest.resumeWorkout(sessions: []))
        XCTAssertNil(TodayDigest.resumeWorkout(sessions: [done]))
    }

    func testResumePicksTheActiveSession() {
        let done = WorkoutSession(routineName: "Push Day",
                                  startedAt: daysAgo(2), completedAt: daysAgo(2))
        let active = WorkoutSession(routineName: "Leg Day", startedAt: daysAgo(0).addingTimeInterval(-1800))
        for row in [done, active] { context.insert(row) }

        let r = TodayDigest.resumeWorkout(sessions: [done, active])
        XCTAssertEqual(r?.sessionID, active.id)
        XCTAssertEqual(r?.routineName, "Leg Day")
        XCTAssertEqual(r?.startedAt, active.startedAt)
    }

    func testResumeMostRecentlyStartedWinsOnDrift() {
        // The store invariant is "one active", but if two ever coexist the newer start wins.
        let stale = WorkoutSession(routineName: "Old", startedAt: daysAgo(3))
        let fresh = WorkoutSession(routineName: "New", startedAt: daysAgo(0).addingTimeInterval(-600))
        for row in [stale, fresh] { context.insert(row) }
        XCTAssertEqual(TodayDigest.resumeWorkout(sessions: [stale, fresh])?.routineName, "New")
    }

    // MARK: - Focus

    func testFocusNilUntilTheModuleHasEverLoggedABlock() {
        XCTAssertNil(TodayDigest.focusToday(sessions: [], now: now, calendar: cal))
    }

    func testFocusSumsOnlyTodaysMinutes() {
        let early = PomodoroSession(minutes: 25, completedAt: todayStart.addingTimeInterval(8 * 3600))
        let late = PomodoroSession(minutes: 15, completedAt: todayStart.addingTimeInterval(11 * 3600))
        let yesterday = PomodoroSession(minutes: 50, completedAt: daysAgo(1))
        for row in [early, late, yesterday] { context.insert(row) }

        let f = TodayDigest.focusToday(sessions: [early, late, yesterday], now: now, calendar: cal)
        XCTAssertEqual(f, TodayDigest.FocusToday(minutesToday: 40, blocksToday: 2))
    }

    func testFocusZeroTodayStillRenders() {
        // In-use module with nothing today → the card still renders (it's the "start focus"
        // nudge), with honest zeros.
        let yesterday = PomodoroSession(minutes: 50, completedAt: daysAgo(1))
        context.insert(yesterday)
        let f = TodayDigest.focusToday(sessions: [yesterday], now: now, calendar: cal)
        XCTAssertEqual(f, TodayDigest.FocusToday(minutesToday: 0, blocksToday: 0))
    }

    // MARK: - Budget pace

    func testBudgetNilWithoutAPositiveLimit() {
        XCTAssertNil(TodayDigest.budgetPace(categories: [], transactions: [],
                                            now: now, calendar: cal))
        let zero = BudgetCategory(name: "Misc", monthlyLimit: 0)
        context.insert(zero)
        XCTAssertNil(TodayDigest.budgetPace(categories: [zero], transactions: [],
                                            now: now, calendar: cal))
    }

    func testBudgetPaceProratesAndScopesToTheMonth() throws {
        let groceries = BudgetCategory(name: "Groceries", monthlyLimit: 200)
        let fun = BudgetCategory(name: "Fun", monthlyLimit: 100)
        for row in [groceries, fun] { context.insert(row) }
        let inMonthA = BudgetTransaction(categoryID: groceries.id, amount: 50, date: daysAgo(2))
        let inMonthB = BudgetTransaction(categoryID: fun.id, amount: 30, date: daysAgo(0))
        let lastMonth = BudgetTransaction(categoryID: groceries.id, amount: 500, date: daysAgo(20))
        let orphan = BudgetTransaction(categoryID: UUID(), amount: 999, date: daysAgo(1))
        for row in [inMonthA, inMonthB, lastMonth, orphan] { context.insert(row) }

        let b = try XCTUnwrap(TodayDigest.budgetPace(
            categories: [groceries, fun],
            transactions: [inMonthA, inMonthB, lastMonth, orphan],
            now: now, calendar: cal))
        XCTAssertEqual(b.spent, 80, accuracy: 0.001)          // May's 500 + the orphan excluded
        XCTAssertEqual(b.monthlyBudget, 300, accuracy: 0.001)
        // June 10, 12:00 of a 30-day month → 9.5/30 elapsed → 300 × 0.31666… = 95.
        XCTAssertEqual(b.expectedByNow, 95, accuracy: 0.001)
        XCTAssertTrue(b.onPace)
    }

    func testBudgetOverPaceFlips() throws {
        let cat = BudgetCategory(name: "Eating out", monthlyLimit: 300)
        context.insert(cat)
        let splurge = BudgetTransaction(categoryID: cat.id, amount: 96, date: daysAgo(1))
        context.insert(splurge)
        let b = try XCTUnwrap(TodayDigest.budgetPace(categories: [cat], transactions: [splurge],
                                                     now: now, calendar: cal))
        XCTAssertFalse(b.onPace)   // 96 > the 95 expected by Jun 10 noon
    }

    // MARK: - Kilter plan

    private func climb(_ uuid: String, grade: String, difficulty: Double,
                       status: KilterAscentStatus) -> KilterClimbLog {
        KilterClimbLog(climbUUID: uuid, climbName: uuid, gradeLabel: grade,
                       difficulty: difficulty, status: status, attempts: 1,
                       startedAt: nil, endedAt: nil, loggedAt: now)
    }

    func testClimbPlanNilWithoutHistory() {
        XCTAssertNil(TodayDigest.climbPlan(history: []))
    }

    func testClimbPlanColdStartHasNoGradeLabel() {
        // Attempts only — no sends → no working grade, but the card still renders with a count.
        let plan = TodayDigest.climbPlan(history: [
            climb("a", grade: "V3", difficulty: 18, status: .attempt),
            climb("b", grade: "V4", difficulty: 20, status: .project),
        ])
        XCTAssertEqual(plan, TodayDigest.ClimbPlan(loggedClimbs: 2, workingGradeLabel: nil))
    }

    func testClimbPlanLabelsTheWorkingGradeFromOwnSends() {
        // Two V4 sends qualify the bucket (threshold 2); the lone harder V5 send doesn't.
        let plan = TodayDigest.climbPlan(history: [
            climb("a", grade: "V4", difficulty: 20, status: .sent),
            climb("b", grade: "V4", difficulty: 20.2, status: .flash),
            climb("c", grade: "V5", difficulty: 21, status: .sent),
            climb("d", grade: "V2", difficulty: 16, status: .attempt),
        ])
        XCTAssertEqual(plan?.loggedClimbs, 4)
        XCTAssertEqual(plan?.workingGradeLabel, "V4")
    }
}
