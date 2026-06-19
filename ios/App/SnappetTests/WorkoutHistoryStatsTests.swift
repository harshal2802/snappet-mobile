import XCTest
@testable import Snappet

/// Unit tests for the pure `WorkoutHistoryStats` planner seam (workout-redesign E0 skeleton):
/// per-discipline recency + training cadence. Deterministic via a fixed UTC calendar + `now`.
final class WorkoutHistoryStatsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private lazy var now: Date = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    private func day(_ o: Int) -> Date { cal.date(byAdding: .day, value: o, to: now)! }

    private func session(_ d: WorkoutDiscipline, startedAt: Date) -> WorkoutSession {
        var set = SetLog(completedAt: Date(timeIntervalSince1970: 0))
        if d == .strength { set.actualReps = 5; set.actualWeight = 60; set.weightUnit = .kg }
        else if d == .run { set.distanceMeters = 1000; set.durationSec = 300 } else { set.durationSec = 30 }
        var ex = SessionExercise(exerciseId: "ex", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                 sets: [set], kindRaw: d.defaultSetKind.rawValue)
        ex.disciplineRaw = d.rawValue
        return WorkoutSession(routineID: nil, routineName: "S", startedAt: startedAt, exercises: [ex])
    }

    func testEmpty() {
        XCTAssertEqual(WorkoutHistoryStats.make(history: [], now: now, calendar: cal), .empty)
    }

    func testRecencyAndCadence() {
        let h = [session(.strength, startedAt: day(0)),
                 session(.climb,    startedAt: day(-2)),
                 session(.run,      startedAt: day(-5))]
        let s = WorkoutHistoryStats.make(history: h, now: now, calendar: cal)
        XCTAssertEqual(s.daysSinceByDiscipline[.strength], 0)
        XCTAssertEqual(s.daysSinceByDiscipline[.climb], 2)
        XCTAssertEqual(s.daysSinceByDiscipline[.run], 5)
        XCTAssertNotNil(s.lastTrainedByDiscipline[.strength])
        // gaps between consecutive days (newest first): 0↔-2 = 2, -2↔-5 = 3 → median of [2,3] = 3.
        XCTAssertEqual(s.medianGapDays, 3)
    }

    func testKeepsMostRecentPerDiscipline() {
        let h = [session(.strength, startedAt: day(-1)), session(.strength, startedAt: day(-8))]
        let s = WorkoutHistoryStats.make(history: h, now: now, calendar: cal)
        XCTAssertEqual(s.daysSinceByDiscipline[.strength], 1)   // the more recent one wins
    }

    // MARK: - Per-muscle signals (E7)

    /// A resolved session: N completed sets, each carrying `muscles`.
    private func resolved(_ muscles: [Muscle], sets: Int, at startedAt: Date) -> WorkoutHistoryStats.ResolvedSession {
        let s = Array(repeating: WorkoutHistoryStats.ResolvedSet(muscles: muscles), count: sets)
        return WorkoutHistoryStats.ResolvedSession(startedAt: startedAt, completedSets: s)
    }

    func testPerMuscleRecency() {
        let r = [resolved([.chest], sets: 3, at: day(-1)),
                 resolved([.quadriceps], sets: 4, at: day(-6))]
        let s = WorkoutHistoryStats.make(history: [], resolved: r, now: now, calendar: cal)
        XCTAssertEqual(s.daysSinceByMuscle[.chest], 1)
        XCTAssertEqual(s.daysSinceByMuscle[.quadriceps], 6)
        XCTAssertNil(s.daysSinceByMuscle[.biceps], "A never-trained muscle is absent (treated as fresh)")
    }

    func testPerMuscleWeeklyVolumeCountsOnlyLast7Days() {
        let r = [resolved([.chest], sets: 3, at: day(-1)),     // in window
                 resolved([.chest], sets: 5, at: day(-9))]     // out of the 7-day window
        let s = WorkoutHistoryStats.make(history: [], resolved: r, now: now, calendar: cal)
        XCTAssertEqual(s.weeklyVolumeByMuscle[.chest], 3, "Only the in-window 3 sets count toward weekly volume")
    }

    func testPerMuscleKeepsMostRecentDate() {
        let r = [resolved([.lats], sets: 2, at: day(-2)),
                 resolved([.lats], sets: 2, at: day(-5))]
        let s = WorkoutHistoryStats.make(history: [], resolved: r, now: now, calendar: cal)
        XCTAssertEqual(s.daysSinceByMuscle[.lats], 2, "Most-recent training date per muscle wins")
        XCTAssertEqual(s.weeklyVolumeByMuscle[.lats], 4, "Both in-window sessions sum")
    }

    func testDisciplineOnlyMakeLeavesMuscleMapsEmpty() {
        let h = [session(.strength, startedAt: day(0))]
        let s = WorkoutHistoryStats.make(history: h, now: now, calendar: cal)
        XCTAssertTrue(s.daysSinceByMuscle.isEmpty)
        XCTAssertTrue(s.weeklyVolumeByMuscle.isEmpty)
    }
}
