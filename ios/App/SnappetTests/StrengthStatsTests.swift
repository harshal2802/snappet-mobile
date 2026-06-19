import XCTest
@testable import Snappet

/// Unit tests for the pure `StrengthStats` per-exercise rollups (Workout-Type Parity) — top set + Epley
/// e1RM. No SwiftData, no view, no device.
final class StrengthStatsTests: XCTestCase {

    private func set(_ reps: Int?, _ weight: Double?, unit: WeightUnit = .kg, done: Bool = true) -> SetLog {
        SetLog(actualReps: reps, actualWeight: weight, weightUnit: unit,
               completedAt: done ? Date(timeIntervalSince1970: 0) : nil)
    }
    private func exercise(_ sets: [SetLog]) -> SessionExercise {
        SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                        sets: sets, kindRaw: SetKind.repsWeight.rawValue)
    }

    func testTopSetIsGreatestWeightedLoad() {
        // 5×100 = 500 beats 8×60 = 480 and the warm-up.
        let ex = exercise([set(8, 60), set(5, 80), set(5, 100)])
        let top = StrengthStats.topSet(ex)
        XCTAssertEqual(top?.actualReps, 5)
        XCTAssertEqual(top?.actualWeight, 100)
    }

    func testTopSetIgnoresIncompleteSets() {
        let ex = exercise([set(5, 100, done: false), set(8, 60)])
        XCTAssertEqual(StrengthStats.topSet(ex)?.actualWeight, 60)
    }

    func testTopSetBodyweightRanksByReps() {
        let ex = exercise([set(8, nil), set(12, nil), set(10, nil)])
        XCTAssertEqual(StrengthStats.topSet(ex)?.actualReps, 12)
    }

    func testTopSetNilWhenNoCompletedSet() {
        XCTAssertNil(StrengthStats.topSet(exercise([])))
        XCTAssertNil(StrengthStats.topSet(exercise([set(5, 100, done: false)])))
    }

    func testEpleyOneRepMaxFromBestWeightedSet() {
        // 5 × 100 → 100 × (1 + 5/30) = 116.66…  beats 8 × 60 → 60 × (1+8/30) = 76.
        let ex = exercise([set(8, 60), set(5, 100)])
        let orm = StrengthStats.estimatedOneRepMax(ex)
        XCTAssertNotNil(orm)
        XCTAssertEqual(orm!.value, 100 * (1 + 5.0/30), accuracy: 0.001)
        XCTAssertEqual(orm!.unit, .kg)
    }

    func testEpleyHonorsTheSetsUnit() {
        let ex = exercise([set(5, 225, unit: .lb)])
        XCTAssertEqual(StrengthStats.estimatedOneRepMax(ex)?.unit, .lb)
    }

    func testEpleyNilForBodyweightOnly() {
        XCTAssertNil(StrengthStats.estimatedOneRepMax(exercise([set(10, nil), set(8, nil)])))
    }
}
