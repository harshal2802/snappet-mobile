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
        XCTAssertEqual(key.disciplineScope, .climb)
        XCTAssertTrue(key.matches(climb("A", [.sent])))
        XCTAssertTrue(key.matches(climb(nil, id: "adhoc-climbAttempt", [.attempt])))
        XCTAssertFalse(key.matches(bench([60])))
        XCTAssertNil(ActivityKey(exerciseId: "bench", nameKey: "").disciplineScope)
    }

    func testLibraryClimbsAreIdentifiedByName() {
        XCTAssertNotEqual(ActivityKey.of(climb("Blue roof", [.sent])), ActivityKey.of(climb("Red slab", [.sent])))
        XCTAssertEqual(ActivityKey.of(climb(nil, [.sent])), ActivityKey(exerciseId: "climb.boulder", nameKey: ""))
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

    // MARK: - Climbs

    func testClimbsListGroupsNamedClimbsAcrossSessions() {
        let a1 = climb("Blue roof", [.attempt, .attempt])
        let s1 = session(daysAgo: 10, bpm: 130, [a1, climb(nil, [.sent])])
        let a2 = climb("blue roof ", grade: "V5", [.sent])
        let s2 = session(daysAgo: 2, bpm: 130, [a2, climb("Red slab", [.attempt])])
        let clip = ActivityMediaInput(id: UUID(), sessionID: s2.id, assignedExerciseID: a2.id, assignedSetIndex: 0,
                                      kindRaw: "video", offsetSec: 100, durationSec: 5, localIdentifier: "x")
        let list = ActivityInsights.climbs(history: [s1, s2], media: [clip])
        XCTAssertEqual(list.count, 2, "the unnamed climb has no page")
        let blue = list.first { $0.name.lowercased().hasPrefix("blue") }
        XCTAssertEqual(blue?.sessions, 2)
        XCTAssertEqual(blue?.attempts, 3)
        XCTAssertEqual(blue?.sent, true)
        XCTAssertEqual(blue?.grade, "V5", "the latest session's grade")
        XCTAssertEqual(blue?.clipCount, 1)
        XCTAssertEqual(list.first { $0.name == "Red slab" }?.sent, false)
    }
}
