import XCTest
@testable import Snappet

/// Unit tests for activity progress P4 (prompt 181): discipline keys, climb identity, the HR effort read, and the
/// climbs list.
final class ActivityInsightsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A session whose HR is flat at `bpm`, with the given exercises' sets completed 60 s apart from t = 120 s.
    private func session(daysAgo: Double, bpm: Double, _ exercises: [SessionExercise]) -> WorkoutSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var t = 120.0
        let stamped = exercises.map { ex -> SessionExercise in
            var ex = ex
            for i in ex.sets.indices { ex.sets[i].completedAt = start.addingTimeInterval(t); t += 60 }
            return ex
        }
        let hr = stride(from: 0.0, through: t + 120, by: 5).map { HRPoint(t: $0, bpm: bpm) }
        return WorkoutSession(routineName: "S", startedAt: start, completedAt: start.addingTimeInterval(t + 120),
                              exercises: stamped, hrSeries: hr)
    }

    private func bench(_ kgs: [Double]) -> SessionExercise {
        SessionExercise(exerciseId: "bench", targetSets: kgs.count, targetReps: "", targetRestSeconds: 0,
                        sets: kgs.map { SetLog(actualReps: 5, actualWeight: $0, weightUnit: .kg) })
    }

    private func climb(_ name: String?, id: String = "climb.boulder", grade: String = "V4",
                       _ statuses: [KilterAscentStatus]) -> SessionExercise {
        var e = SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                sets: statuses.map { SetLog(climbGradeLabel: grade, climbStatusRaw: $0.rawValue) },
                                displayName: name, kindRaw: SetKind.climbAttempt.rawValue)
        e.disciplineRaw = WorkoutDiscipline.climb.rawValue
        e.climbGradeLabel = grade
        return e
    }

    // MARK: - Keys

    func testDisciplineKeyMatchesEveryEntityOfIt() {
        let key = ActivityKey.discipline(.climb)
        let ids = ActivityIdentity(sessions: [])
        XCTAssertEqual(key.disciplineScope, .climb)
        XCTAssertTrue(ids.matches(key, climb("A", [.sent])))
        XCTAssertTrue(ids.matches(key, climb(nil, id: "adhoc-climbAttempt", [.attempt])))
        XCTAssertFalse(ids.matches(key, bench([60])))
        XCTAssertNil(ActivityKey(exerciseId: "bench", nameKey: "").disciplineScope)
    }

    func testLibraryAndAddAClimbLogsOfOneClimbShareAKey() {
        let fromLibrary = climb("Blue roof", [.attempt])
        let fromSheet = climb("blue roof", id: "adhoc-climbAttempt", [.sent])
        let s1 = session(daysAgo: 6, bpm: 120, [fromLibrary]), s2 = session(daysAgo: 2, bpm: 120, [fromSheet])
        let ids = ActivityIdentity(sessions: [s1, s2])
        XCTAssertEqual(ids.key(for: fromLibrary), ids.key(for: fromSheet), "the library id isn't part of a climb's identity")
        XCTAssertNotEqual(ids.key(for: fromLibrary), ids.key(for: climb("Red slab", [.sent])))
    }

    // MARK: - Effort

    func testEffortComparesTheRepeatedLoadAndCallsFitter() throws {
        // 60 kg appears in all three sessions; the 70 kg top set only once — so 60 kg is the reference.
        let s1 = session(daysAgo: 30, bpm: 150, [bench([60, 60])])
        let s2 = session(daysAgo: 15, bpm: 146, [bench([60, 70])])
        let s3 = session(daysAgo: 1, bpm: 140, [bench([60])])
        let e = try XCTUnwrap(ActivityInsights.effort(key: ActivityKey(exerciseId: "bench", nameKey: ""),
                                                      history: [s3, s1, s2], unit: .kg))
        XCTAssertEqual(e.referenceKg, 60)
        XCTAssertEqual(e.title, "Peak ♥ at 60 kg")
        XCTAssertEqual(e.points.map(\.sessionID), [s1.id, s2.id, s3.id])
        XCTAssertEqual(e.change, -10)
        XCTAssertTrue(e.fitter)
    }

    func testEffortWithoutARepeatedLoadIsNeutral() throws {
        let e = try XCTUnwrap(ActivityInsights.effort(
            key: ActivityKey(exerciseId: "bench", nameKey: ""),
            history: [session(daysAgo: 9, bpm: 150, [bench([50])]), session(daysAgo: 1, bpm: 130, [bench([80])])],
            unit: .kg))
        XCTAssertNil(e.referenceKg)
        XCTAssertEqual(e.title, "Peak ♥ per set")
        XCTAssertFalse(e.fitter, "a lower peak at a different load proves nothing")
    }

    func testEffortNeedsTwoSessionsWithHR() {
        let noHR = session(daysAgo: 5, bpm: 140, [bench([60])])
        noHR.hrSeries = []
        XCTAssertNil(ActivityInsights.effort(key: ActivityKey(exerciseId: "bench", nameKey: ""),
                                             history: [noHR, session(daysAgo: 1, bpm: 140, [bench([60])])], unit: .kg))
    }
}
