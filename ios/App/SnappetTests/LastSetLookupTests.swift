import XCTest
@testable import Snappet

/// Unit tests for the **pure** `LastSetLookup` cross-session prefill (issue #73) — no SwiftData
/// container, no view, no device. Covers session ordering, the prefill = last-completed-set rule,
/// every hint shape, and the inputs that must be ignored (active sessions, other exercises,
/// non-reps/weight kinds, "done"-only sets).
final class LastSetLookupTests: XCTestCase {

    // MARK: - Builders

    private func set(_ reps: Int?, _ weight: Double?, unit: WeightUnit? = .kg,
                     done: Bool = true) -> SetLog {
        SetLog(actualReps: reps, actualWeight: weight, weightUnit: unit,
               completedAt: done ? Date(timeIntervalSince1970: 0) : nil)
    }

    private func exercise(_ id: String, _ sets: [SetLog], kind: SetKind? = nil) -> SessionExercise {
        SessionExercise(exerciseId: id, targetSets: sets.count, targetReps: "",
                        targetRestSeconds: 0, sets: sets, kindRaw: kind?.rawValue)
    }

    private func session(_ exercises: [SessionExercise], daysAgo: Double,
                         completed: Bool = true) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400)
        return WorkoutSession(routineName: "Push Day", startedAt: start,
                              completedAt: completed ? start.addingTimeInterval(3600) : nil,
                              exercises: exercises)
    }

    // MARK: - Which session decides

    func testMostRecentCompletedSessionWins() {
        let old = session([exercise("bench", [set(8, 50)])], daysAgo: 10)
        let recent = session([exercise("bench", [set(8, 60)])], daysAgo: 2)
        let result = LastSetLookup.lastTime(exerciseId: "bench", history: [old, recent])
        XCTAssertEqual(result?.weight, 60, "order of the history array must not matter")
    }

    func testActiveSessionsAreIgnored() {
        let active = session([exercise("bench", [set(8, 100)])], daysAgo: 0, completed: false)
        let done = session([exercise("bench", [set(8, 60)])], daysAgo: 3)
        let result = LastSetLookup.lastTime(exerciseId: "bench", history: [active, done])
        XCTAssertEqual(result?.weight, 60)
    }

    func testSkipsSessionsWithoutTheExercise() {
        let other = session([exercise("squat", [set(5, 100)])], daysAgo: 1)
        let match = session([exercise("bench", [set(8, 60)])], daysAgo: 5)
        let result = LastSetLookup.lastTime(exerciseId: "bench", history: [other, match])
        XCTAssertEqual(result?.weight, 60)
    }

    func testNoUsableHistoryReturnsNil() {
        // Completed but "done"-only sets (no reps, no weight) say nothing worth prefilling.
        let doneOnly = session([exercise("bench", [set(nil, nil)])], daysAgo: 1)
        XCTAssertNil(LastSetLookup.lastTime(exerciseId: "bench", history: [doneOnly]))
        XCTAssertNil(LastSetLookup.lastTime(exerciseId: "bench", history: []))
    }

    func testDoneOnlySessionFallsThroughToOlderUsableOne() {
        let doneOnly = session([exercise("bench", [set(nil, nil)])], daysAgo: 1)
        let usable = session([exercise("bench", [set(8, 55)])], daysAgo: 4)
        let result = LastSetLookup.lastTime(exerciseId: "bench", history: [doneOnly, usable])
        XCTAssertEqual(result?.weight, 55)
    }

    func testNonRepsWeightKindsAreIgnored() {
        let timed = session([exercise("plank", [SetLog(completedAt: .now, durationSec: 60)],
                                      kind: .duration)], daysAgo: 1)
        XCTAssertNil(LastSetLookup.lastTime(exerciseId: "plank", history: [timed]))
    }

    // MARK: - Prefill values

    func testPrefillIsTheLastCompletedSetOfThatSession() {
        let s = session([exercise("bench", [set(8, 60), set(8, 60), set(6, 55),
                                            set(nil, nil, done: false)])], daysAgo: 1)
        let result = LastSetLookup.lastTime(exerciseId: "bench", history: [s])
        XCTAssertEqual(result?.reps, 6)
        XCTAssertEqual(result?.weight, 55)
        XCTAssertEqual(result?.unit, .kg)
    }

    func testFreeformDuplicateExerciseAggregatesAcrossOccurrences() {
        // The same exerciseId twice in one session (a freeform re-add) — the second occurrence's
        // set is "last", and the hint covers both.
        let s = session([exercise("bench", [set(10, 50)]),
                         exercise("bench", [set(5, 70)])], daysAgo: 1)
        let result = LastSetLookup.lastTime(exerciseId: "bench", history: [s])
        XCTAssertEqual(result?.weight, 70)
        XCTAssertEqual(result?.hint, "Last time: 10/5 @ 50–70 kg")
    }

    // MARK: - Hint shapes

    func testUniformSetsHint() {
        let s = session([exercise("bench", [set(8, 60), set(8, 60), set(8, 60)])], daysAgo: 1)
        XCTAssertEqual(LastSetLookup.lastTime(exerciseId: "bench", history: [s])?.hint,
                       "Last time: 3×8 @ 60 kg")
    }

    func testMixedRepsHintListsThem() {
        let s = session([exercise("bench", [set(8, 60), set(8, 60), set(6, 60)])], daysAgo: 1)
        XCTAssertEqual(LastSetLookup.lastTime(exerciseId: "bench", history: [s])?.hint,
                       "Last time: 8/8/6 @ 60 kg")
    }

    func testMixedWeightsHintShowsRange() {
        let s = session([exercise("bench", [set(8, 55), set(8, 60), set(8, 57.5)])], daysAgo: 1)
        XCTAssertEqual(LastSetLookup.lastTime(exerciseId: "bench", history: [s])?.hint,
                       "Last time: 3×8 @ 55–60 kg")
    }

    func testBodyweightHintOmitsWeight() {
        let s = session([exercise("pullup", [set(12, nil), set(10, nil)])], daysAgo: 1)
        XCTAssertEqual(LastSetLookup.lastTime(exerciseId: "pullup", history: [s])?.hint,
                       "Last time: 12/10")
    }

    func testWeightOnlyHintOmitsReps() {
        let s = session([exercise("carry", [set(nil, 40)])], daysAgo: 1)
        XCTAssertEqual(LastSetLookup.lastTime(exerciseId: "carry", history: [s])?.hint,
                       "Last time: 40 kg")
    }

    func testHintUsesTheSetsStoredUnit() {
        let s = session([exercise("bench", [set(5, 135, unit: .lb), set(5, 135, unit: .lb)])],
                        daysAgo: 1)
        let result = LastSetLookup.lastTime(exerciseId: "bench", history: [s])
        XCTAssertEqual(result?.hint, "Last time: 2×5 @ 135 lb")
        XCTAssertEqual(result?.unit, .lb)
    }

    func testMixedUnitsConvertIntoTheLastSetsUnitWithoutFloatNoise() {
        // 132 lb ≈ 59.9 kg — the converted value must print rounded, never "59.87…".
        let s = session([exercise("bench", [set(5, 132, unit: .lb), set(5, 60, unit: .kg)])],
                        daysAgo: 1)
        XCTAssertEqual(LastSetLookup.lastTime(exerciseId: "bench", history: [s])?.hint,
                       "Last time: 2×5 @ 59.9–60 kg")
    }
}
