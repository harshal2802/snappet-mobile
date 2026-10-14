import XCTest
@testable import Snappet

/// Unit tests for the **pure** `ActivityDashboard` (activity progress P2, prompt 179).
final class ActivityDashboardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let benchKey = ActivityKey(exerciseId: "bench", nameKey: "")

    private func session(daysAgo: Double, _ exercises: [SessionExercise]) -> WorkoutSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return WorkoutSession(routineName: "Push", startedAt: start, completedAt: start.addingTimeInterval(3600),
                              exercises: exercises)
    }

    private func bench(_ sets: [(Int, Double?)]) -> SessionExercise {
        SessionExercise(exerciseId: "bench", targetSets: sets.count, targetReps: "", targetRestSeconds: 0,
                        sets: sets.map { SetLog(actualReps: $0.0, actualWeight: $0.1, weightUnit: $0.1 == nil ? nil : .kg,
                                                completedAt: now) })
    }

    // MARK: - Strength

    func testStrengthUsesEpleyAndReportsImprovement() throws {
        let old = session(daysAgo: 60, [bench([(8, 60)])])
        let mid = session(daysAgo: 30, [bench([(5, 70), (8, 65)])])
        let new = session(daysAgo: 2, [bench([(8, 75)])])
        let d = try XCTUnwrap(ActivityDashboard.make(key: benchKey, history: [new, old, mid], media: [],
                                                     unit: .kg, now: now, calendar: cal))
        XCTAssertEqual(d.metric, .oneRepMax)
        XCTAssertEqual(d.points.map(\.sessionID), [old.id, mid.id, new.id], "oldest first")
        XCTAssertEqual(d.points[0].value, 76, accuracy: 0.01)          // 60 × (1 + 8/30)
        XCTAssertEqual(d.points[1].value, 82.33, accuracy: 0.01)       // max(70×1.1667, 65×1.2667)
        XCTAssertEqual(d.kpis.first?.title, "Est. 1RM")
        XCTAssertEqual(d.kpis.first?.detail, "▲ 25%")                   // 95 / 76 − 1
        XCTAssertEqual(d.records.map(\.title), ["Est. 1RM", "Best set", "Best volume", "First session"])
        XCTAssertEqual(d.records[1].value, "75 kg × 8")
        XCTAssertEqual(d.sessionCount, 3)
    }

    func testBodyweightFallsBackToMaxReps() throws {
        let d = try XCTUnwrap(ActivityDashboard.make(key: benchKey,
                                                     history: [session(daysAgo: 1, [bench([(12, nil), (15, nil)])])],
                                                     media: [], unit: .kg, now: now, calendar: cal))
        XCTAssertEqual(d.metric, .maxReps)
        XCTAssertEqual(d.points.first?.label, "15 reps")
    }

    func testNoCompletedSessionMeansNoDashboard() {
        var ex = bench([(8, 60)])
        ex.sets[0].completedAt = nil
        XCTAssertNil(ActivityDashboard.make(key: benchKey, history: [session(daysAgo: 1, [ex])], media: [],
                                            unit: .kg, now: now, calendar: cal))
    }

    func testPointsWithClipsAreFlagged() throws {
        let ex = bench([(8, 60)])
        let s1 = session(daysAgo: 10, [ex])
        let s2 = session(daysAgo: 1, [bench([(8, 62.5)])])
        let clip = ActivityMediaInput(id: UUID(), sessionID: s1.id, assignedExerciseID: ex.id, assignedSetIndex: 0,
                                      kindRaw: "video", offsetSec: 10, durationSec: 5, localIdentifier: "x")
        let d = try XCTUnwrap(ActivityDashboard.make(key: benchKey, history: [s1, s2], media: [clip],
                                                     unit: .kg, now: now, calendar: cal))
        XCTAssertEqual(d.points.map(\.hasMedia), [true, false])
    }

    // MARK: - Other disciplines

    func testRunPaceIsLowerIsBetter() throws {
        func run(_ secs: Double) -> SessionExercise {
            var e = SessionExercise(exerciseId: "adhoc-run", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                    sets: [SetLog(completedAt: now, durationSec: secs, distanceMeters: 5_000)],
                                    displayName: "Run", kindRaw: SetKind.duration.rawValue)
            e.disciplineRaw = WorkoutDiscipline.run.rawValue
            return e
        }
        let key = ActivityKey(exerciseId: "adhoc-run", nameKey: "run")
        let d = try XCTUnwrap(ActivityDashboard.make(key: key, history: [session(daysAgo: 20, [run(1_800)]),
                                                                         session(daysAgo: 1, [run(1_650)])],
                                                     media: [], unit: .kg, now: now, calendar: cal))
        XCTAssertEqual(d.metric, .pace)
        XCTAssertFalse(d.metric.higherIsBetter)
        XCTAssertEqual(d.kpis.first?.value, "5:30/km")
        XCTAssertEqual(d.kpis.first?.detail, "▲ 8%")
        XCTAssertTrue(d.records.contains { $0.title == "Longest" })
    }

    func testClimbHardestSendSkipsAttempts() throws {
        func climb(_ grade: String, _ status: KilterAscentStatus) -> SessionExercise {
            var e = SessionExercise(exerciseId: "climb.boulder", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                    sets: [SetLog(completedAt: now, climbGradeLabel: grade, climbStatusRaw: status.rawValue)],
                                    kindRaw: SetKind.climbAttempt.rawValue)
            e.climbGradeLabel = grade
            return e
        }
        let key = ActivityKey(exerciseId: "climb.boulder", nameKey: "")
        let d = try XCTUnwrap(ActivityDashboard.make(
            key: key, history: [session(daysAgo: 9, [climb("V3", .sent), climb("V5", .attempt)]),
                                session(daysAgo: 1, [climb("V4", .flash)])],
            media: [], unit: .kg, now: now, calendar: cal))
        XCTAssertEqual(d.metric, .hardestSend)
        XCTAssertEqual(d.points.map(\.label), ["V3", "V4"])
        XCTAssertEqual(d.records.first?.value, "V4")
        XCTAssertEqual(d.kpis.first?.detail, "▲ from V3", "grades are ranks, not percentages")
    }

    // MARK: - Frequency

    func testWeekCountsAndStreak() {
        let dates = [0.0, 1, 7, 14, 35].map { now.addingTimeInterval(-$0 * 86_400) }
        let weeks = ActivityDashboard.weekCounts(dates: dates, now: now, calendar: cal)
        XCTAssertEqual(weeks.count, ActivityDashboard.weekCount)
        XCTAssertEqual(weeks.reduce(0, +), 5)
        XCTAssertEqual(ActivityDashboard.trailingStreak(weeks), 3)
        XCTAssertEqual(ActivityDashboard.trailingStreak([1, 1, 0]), 2, "an empty current week doesn't break it")
    }
}
