import XCTest
import SwiftData
@testable import Snappet

/// Prompt 150: the pure parts of the training-first Home.
@MainActor
final class TrainingHomeTests: XCTestCase {
    private var container: ModelContainer!
    private var all: [WorkoutSession] = []
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        RoutineHistorySeed.seed(into: container.mainContext, now: now)
        all = try container.mainContext.fetch(FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    override func tearDown() async throws { container = nil }

    func testXPEstimateAveragesTheRoutinesLastThreeSessions() {
        let ledger = Progression.ledger(all, schedules: [:])
        let push = all.filter { $0.routineID == RoutineHistorySeed.pushDayID }.suffix(3)
        let avg = push.compactMap { ledger.awards[$0.id]?.total }.reduce(0, +) / 3
        let est = TrainingHome.xpEstimate(routineID: RoutineHistorySeed.pushDayID, sessions: all, ledger: ledger)
        XCTAssertEqual(est % 5, 0)
        XCTAssertLessThanOrEqual(abs(est - avg), 3)
        XCTAssertEqual(TrainingHome.xpEstimate(routineID: UUID(), sessions: all, ledger: ledger), 115, "never done: 50 + 45 + 20")
        XCTAssertNotNil(TrainingHome.typicalMinutes(routineID: RoutineHistorySeed.pushDayID, sessions: all))
    }

    func testWeekSumsXPPerDay() {
        let ledger = Progression.ledger(all, schedules: [:])
        let week = TrainingHome.week(sessions: all, ledger: ledger, plan: [], now: now)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.filter(\.isToday).count, 1)
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: now)!
        let inWeek = all.filter { start.contains($0.startedAt) }.compactMap { ledger.awards[$0.id]?.total }.reduce(0, +)
        XCTAssertEqual(week.reduce(0) { $0 + $1.xp }, inWeek)
    }

    func testRecentWinsFindTheSeededRecords() {
        let wins = TrainingHome.recentWins(all, now: now.addingTimeInterval(3_600 * 24))
        XCTAssertTrue(wins.contains { $0.title.contains("PR") }, "\(wins)")
        XCTAssertTrue(wins.contains { $0.title.hasPrefix("First V5") }, "\(wins)")
        XCTAssertLessThanOrEqual(wins.count, 6)
    }

    func testNextGrowthAndMilestone() {
        let g = TrainingHome.nextGrowth(Progression.levelInfo(totalXP: 3_150 + 300))   // Level 10, part-way
        XCTAssertEqual(g?.next, .legend)
        XCTAssertEqual(g?.atLevel, 20)
        XCTAssertEqual(g?.levelsToGo, 10)
        XCTAssertLessThan(g!.fraction, 0.1)
        XCTAssertNil(TrainingHome.nextGrowth(Progression.levelInfo(totalXP: 100_000)), "Legend has nowhere to grow")
        let m = TrainingHome.nextMilestone(all)
        XCTAssertEqual(m?.name, "Easy run", "4 runs → 5th is 1 away, the closest")
        XCTAssertEqual(m?.toGo, 1)
    }

    func testMissedNoteIsKindAndQuietWhenPaused() {
        let monday = DayKey(value: 20_260_928)
        let plan = [RoutineReminderPlanner.WeekDay(day: monday, isToday: false, state: .missed, names: ["Push Day"])]
        XCTAssertEqual(TrainingHome.missedNote(plan: plan, paused: false)?.hasPrefix("You missed Monday's Push Day"), true)
        XCTAssertNil(TrainingHome.missedNote(plan: plan, paused: true))
        XCTAssertNil(TrainingHome.missedNote(plan: [], paused: false))
    }
}
