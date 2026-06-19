import XCTest
@testable import Snappet

/// Unit tests for the pure `WorkoutDashboardStats` (workout-redesign E0) — discipline-aware dashboard
/// aggregates that replace the inline `WorkoutDashboardSection` math. Deterministic via a fixed UTC
/// calendar + a fixed `now` (a Tuesday, so `now / now-1 / now-2` land in one week and form a streak).
final class WorkoutDashboardStatsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2023-11-14 (Tuesday) — startOfDay so day arithmetic is exact in UTC.
    private lazy var now: Date = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: now)! }

    private func completed(_ discipline: WorkoutDiscipline) -> SetLog {
        var s = SetLog(completedAt: Date(timeIntervalSince1970: 0))
        switch discipline {
        case .strength: s.actualReps = 5; s.actualWeight = 60; s.weightUnit = .kg
        case .run:      s.distanceMeters = 1000; s.durationSec = 300
        default:        s.durationSec = 30
        }
        return s
    }
    private func session(_ discipline: WorkoutDiscipline, startedAt: Date) -> WorkoutSession {
        var ex = SessionExercise(exerciseId: "ex", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                 sets: [completed(discipline)], kindRaw: discipline.defaultSetKind.rawValue)
        ex.disciplineRaw = discipline.rawValue
        return WorkoutSession(routineID: nil, routineName: "S", startedAt: startedAt,
                              completedAt: startedAt.addingTimeInterval(1800), exercises: [ex])
    }

    func testEmptyHistory() {
        XCTAssertEqual(WorkoutDashboardStats.make(history: [], now: now, calendar: cal), .empty)
    }

    func testStreakParityWithOldInlineDefinition() {
        // 3 consecutive days ending today → streak 3; older session after a gap doesn't extend it.
        let h = [session(.strength, startedAt: day(0)),
                 session(.climb,    startedAt: day(-1)),
                 session(.run,      startedAt: day(-2)),
                 session(.strength, startedAt: day(-5))]   // gap at day(-3)/-4
        XCTAssertEqual(WorkoutDashboardStats.currentStreak(history: h, now: now, calendar: cal), 3)
    }

    func testStreakAllowsYesterdayStart() {
        let h = [session(.strength, startedAt: day(-1)), session(.strength, startedAt: day(-2))]
        XCTAssertEqual(WorkoutDashboardStats.currentStreak(history: h, now: now, calendar: cal), 2)
    }

    func testThisWeekAndDisciplineCounts() {
        // This week (Sun Nov12 – Sat Nov18): 2 strength + 1 climb + 1 run; last week excluded.
        let h = [session(.strength, startedAt: day(0)),
                 session(.strength, startedAt: day(-1)),
                 session(.climb,    startedAt: day(-2)),
                 session(.run,      startedAt: day(0).addingTimeInterval(3600)),
                 session(.climb,    startedAt: day(-9))]   // previous week → excluded from week counts
        let s = WorkoutDashboardStats.make(history: h, now: now, calendar: cal)
        XCTAssertEqual(s.totalSessions, 5)
        XCTAssertEqual(s.thisWeekCount, 4)
        XCTAssertEqual(s.weeklyActiveDays, 3)   // day0, day-1, day-2
        // strength=2 (top), climb=1, run=1; sorted count-desc then fixed order (climb before run).
        XCTAssertEqual(s.disciplineCounts.map(\.discipline), [.strength, .climb, .run])
        XCTAssertEqual(s.disciplineCounts.first?.count, 2)
    }

    func testDominantRecentDiscipline() {
        // Most frequent over recent sessions = climb (3 climbs vs 1 strength).
        let h = [session(.climb, startedAt: day(0)), session(.climb, startedAt: day(-1)),
                 session(.climb, startedAt: day(-2)), session(.strength, startedAt: day(-3))]
        let s = WorkoutDashboardStats.make(history: h, now: now, calendar: cal)
        XCTAssertEqual(s.dominantRecentDiscipline, .climb)
    }

    func testDominantDisciplineSkipsUncompleted() {
        var ex = SessionExercise(exerciseId: "ex", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                 sets: [SetLog()], kindRaw: SetKind.repsWeight.rawValue)   // no completedAt
        ex.disciplineRaw = WorkoutDiscipline.strength.rawValue
        let s = WorkoutSession(routineID: nil, routineName: "S", startedAt: now, exercises: [ex])
        XCTAssertNil(WorkoutDashboardStats.dominantDiscipline(of: s))
    }
}
