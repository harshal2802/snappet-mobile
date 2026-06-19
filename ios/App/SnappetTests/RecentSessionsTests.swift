import XCTest
@testable import Snappet

/// Unit tests for the pure `RecentSessions` dashboard feed selector (workout-redesign E1): discipline
/// detection, the type-adaptive ≤3-fact rollup, the PR flag, and the limit. No view, no device.
final class RecentSessionsTests: XCTestCase {

    private func t(_ days: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(days) * 86_400) }
    private func lift(_ reps: Int, _ kg: Double) -> SetLog {
        SetLog(actualReps: reps, actualWeight: kg, weightUnit: .kg, completedAt: Date(timeIntervalSince1970: 0))
    }
    private func climb(_ grade: String, _ status: KilterAscentStatus) -> SetLog {
        SetLog(completedAt: Date(timeIntervalSince1970: 0), climbGradeLabel: grade, climbStatusRaw: status.rawValue, climbAttempts: 1)
    }
    private func run(_ m: Double, _ sec: Double) -> SetLog {
        var s = SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: sec); s.distanceMeters = m; return s
    }
    private func entity(_ id: String, _ d: WorkoutDiscipline, _ sets: [SetLog]) -> SessionExercise {
        var e = SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: sets, kindRaw: d.defaultSetKind.rawValue)
        e.disciplineRaw = d.rawValue; return e
    }
    private func session(_ name: String, at day: Int, _ ex: [SessionExercise]) -> WorkoutSession {
        WorkoutSession(routineID: nil, routineName: name, startedAt: t(day),
                       completedAt: t(day).addingTimeInterval(1800), exercises: ex)
    }

    func testMixedHistoryNewestFirstWithDisciplineAndFacts() {
        let h = [session("Sunset Sends", at: 2, [entity("c", .climb, [climb("V5", .sent), climb("V3", .flash)])]),
                 session("Push day", at: 1, [entity("bench", .strength, [lift(5, 100), lift(8, 60)])]),
                 session("Morning run", at: 0, [entity("r", .run, [run(5000, 1500)])])]
        let rows = RecentSessions.rows(history: h, unit: .kg)
        XCTAssertEqual(rows.map(\.discipline), [.climb, .strength, .run])   // newest first
        XCTAssertEqual(rows[0].facts[0], "V5")                              // hardest send
        XCTAssertEqual(rows[0].facts[1], "1 sends")
        XCTAssertTrue(rows[1].facts[0].contains("kg"))                     // strength volume
        XCTAssertEqual(rows[1].facts[1], "2 sets")
        XCTAssertTrue(rows[1].facts.contains { $0.hasPrefix("top ") })      // top set fact
        XCTAssertEqual(rows[2].facts[0], SetMeasure.formatDistance(5000, unit: .km))
    }

    func testLimitCapsTheFeed() {
        let h = (0..<8).map { session("S\($0)", at: $0, [entity("bench", .strength, [lift(5, 50)])]) }
        XCTAssertEqual(RecentSessions.rows(history: h, unit: .kg, limit: 3).count, 3)
    }

    func testPRFlagForFirstWeightedSession() {
        // No prior history → the first weighted session is a PR.
        let h = [session("Push", at: 0, [entity("bench", .strength, [lift(5, 100)])])]
        XCTAssertTrue(RecentSessions.rows(history: h, unit: .kg).first?.isPR ?? false)
    }

    func testNoPRWhenNotBeaten() {
        // A later, lighter session does NOT beat the earlier heavier one → not a PR.
        let h = [session("Light", at: 1, [entity("bench", .strength, [lift(5, 60)])]),
                 session("Heavy", at: 0, [entity("bench", .strength, [lift(5, 100)])])]
        let rows = RecentSessions.rows(history: h, unit: .kg)
        XCTAssertEqual(rows.first?.title, "Light")
        XCTAssertFalse(rows.first?.isPR ?? true)
    }

    func testActiveSessionExcluded() {
        let active = WorkoutSession(routineID: nil, routineName: "Live", startedAt: t(0),
                                    exercises: [entity("bench", .strength, [lift(5, 50)])])   // no completedAt
        XCTAssertTrue(RecentSessions.rows(history: [active], unit: .kg).isEmpty)
    }
}
