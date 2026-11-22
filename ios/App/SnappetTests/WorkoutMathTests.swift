import XCTest
@testable import Snappet

/// Unit tests for `WorkoutMath` per-exercise analytics — previously untested. Focus: the review fix
/// that aggregates **every** matching exercise in a session (a freeform session can log the same
/// `exerciseId` twice), plus baseline single-occurrence behavior + unit conversion.
final class WorkoutMathTests: XCTestCase {

    // MARK: - Builders

    private func set(_ reps: Int?, _ weight: Double?, unit: WeightUnit = .kg, done: Bool = true) -> SetLog {
        SetLog(actualReps: reps, actualWeight: weight, weightUnit: unit,
               completedAt: done ? Date(timeIntervalSince1970: 0) : nil)
    }

    private func exercise(_ id: String, _ sets: [SetLog]) -> SessionExercise {
        SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: sets)
    }

    private func session(_ exercises: [SessionExercise],
                         startedAt: Date = Date(timeIntervalSince1970: 0)) -> WorkoutSession {
        WorkoutSession(routineID: nil, routineName: "s", startedAt: startedAt, exercises: exercises)
    }

    // MARK: - Duplicate-exercise aggregation (the review fix)

    func testTotalVolumeSumsDuplicateExercisesInOneSession() {
        // Same exerciseId twice in one session (a freeform re-add) — both occurrences must count.
        let s = session([
            exercise("bench", [set(10, 50)]),   // 500
            exercise("bench", [set(8, 60)]),    // 480
        ])
        XCTAssertEqual(WorkoutMath.totalVolumeKg(history: [s], exerciseId: "bench"), 980)
    }

    func testTopSetConsidersDuplicateExercisesInOneSession() {
        // The heavier set lives in the SECOND occurrence — the old `first(where:)` would miss it.
        let s = session([
            exercise("bench", [set(10, 50)]),   // score 500
            exercise("bench", [set(5, 120)]),   // score 600 → the PR
        ])
        let top = WorkoutMath.topSet(history: [s], exerciseId: "bench")
        XCTAssertEqual(top?.bestKg, 120)
        XCTAssertEqual(top?.bestReps, 5)
    }

    /// Prompt 279: the one-pass `topSets` answers exactly what `topSet` answers per exercise.
    func testTopSetsInOnePassMatchesTopSetPerExercise() {
        let history = [
            session([exercise("bench", [set(10, 50)]), exercise("bench", [set(5, 120)]), exercise("ohp", [set(8, 40)])]),
            session([exercise("bench", [set(6, 100)]), exercise("pullup", [set(12, nil)]), exercise("ohp", [set(8, 40)])]),
        ]
        let all = WorkoutMath.topSets(history: history)
        XCTAssertEqual(Set(all.keys), ["bench", "ohp", "pullup"])
        for id in all.keys {
            let one = WorkoutMath.topSet(history: history, exerciseId: id)
            XCTAssertEqual(all[id]?.bestKg, one?.bestKg, id)
            XCTAssertEqual(all[id]?.bestReps, one?.bestReps, id)
            XCTAssertEqual(all[id]?.date, one?.date, id)
        }
        XCTAssertEqual(all["pullup"]?.bestKg, 0, "bodyweight ranks, and reports no weight")
    }

    /// Prompt 287: the one-pass `sessionCounts` answers exactly what `sessionCount` answers per exercise.
    func testSessionCountsInOnePassMatchesSessionCountPerExercise() {
        let history = [
            session([exercise("bench", [set(10, 50)]), exercise("bench", [set(5, 120)]), exercise("ohp", [set(8, 40, done: false)])]),
            session([exercise("bench", [set(6, 100)]), exercise("pullup", [set(12, nil)]), exercise("ohp", [set(8, 40)])]),
        ]
        let all = WorkoutMath.sessionCounts(history: history)
        XCTAssertEqual(all, ["bench": 2, "ohp": 1, "pullup": 1], "twice in one session counts once; unfinished sets do not count")
        for id in ["bench", "ohp", "pullup", "squat"] {
            XCTAssertEqual(all[id] ?? 0, WorkoutMath.sessionCount(history: history, exerciseId: id), id)
        }
    }

    // MARK: - Baseline

    func testTotalVolumeAcrossSessions() {
        let a = session([exercise("squat", [set(5, 100), set(5, 100)])])  // 1000
        let b = session([exercise("squat", [set(5, 80)])])                // 400
        XCTAssertEqual(WorkoutMath.totalVolumeKg(history: [a, b], exerciseId: "squat"), 1400)
    }

    func testTopSetSkipsIncompleteAndZeroRepSets() {
        let s = session([exercise("ohp", [
            set(nil, 40),               // no reps → skipped
            set(5, 30, done: false),    // not completed → skipped
            set(8, 25),                 // counts: score 200
        ])])
        let top = WorkoutMath.topSet(history: [s], exerciseId: "ohp")
        XCTAssertEqual(top?.bestReps, 8)
        XCTAssertEqual(top?.bestKg, 25)
    }

    func testSessionCountCountsSessionsWithACompletedSet() {
        let a = session([exercise("row", [set(10, 40)])])
        let b = session([exercise("row", [set(10, 40, done: false)])])   // no completed set
        XCTAssertEqual(WorkoutMath.sessionCount(history: [a, b], exerciseId: "row"), 1)
    }

    func testBodyweightSetRanksButReportsZeroKg() {
        let s = session([exercise("pullup", [set(12, nil)])])   // weight nil → scores 1×reps, reports 0 kg
        let top = WorkoutMath.topSet(history: [s], exerciseId: "pullup")
        XCTAssertEqual(top?.bestReps, 12)
        XCTAssertEqual(top?.bestKg, 0)
    }

    func testLbConvertedToKgForVolume() {
        // 100 lb × 10 = 1000 lb-reps → kg = 1000 × 0.453592 = 453.592 → rounded 454.
        let s = session([exercise("dl", [set(10, 100, unit: .lb)])])
        XCTAssertEqual(WorkoutMath.totalVolumeKg(history: [s], exerciseId: "dl"), 454)
    }
}
