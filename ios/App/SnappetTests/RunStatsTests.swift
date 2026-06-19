import XCTest
@testable import Snappet

/// Unit tests for the pure `RunStats` per-run rollups (Workout-Type Parity) — total distance, total time,
/// average pace. No SwiftData, no view, no device.
final class RunStatsTests: XCTestCase {

    private func leg(_ meters: Double, sec: Double, done: Bool = true) -> SetLog {
        var s = SetLog(completedAt: done ? Date(timeIntervalSince1970: 0) : nil, durationSec: sec)
        s.distanceMeters = meters
        return s
    }
    private func run(_ legs: [SetLog]) -> SessionExercise {
        var ex = SessionExercise(exerciseId: "adhoc-run", targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: legs, kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.run.rawValue
        return ex
    }

    func testTotalsSumCompletedLegs() {
        let ex = run([leg(5000, sec: 1500), leg(2000, sec: 600)])
        XCTAssertEqual(RunStats.totalDistanceMeters(ex), 7000)
        XCTAssertEqual(RunStats.totalDurationSec(ex), 2100)
    }

    func testTotalsIgnoreIncompleteLegs() {
        let ex = run([leg(5000, sec: 1500), leg(9999, sec: 9999, done: false)])
        XCTAssertEqual(RunStats.totalDistanceMeters(ex), 5000)
        XCTAssertEqual(RunStats.totalDurationSec(ex), 1500)
    }

    func testAvgPaceIsTotalTimeOverTotalDistance() {
        // 7 km in 2100 s → 300 s/km (5:00/km).
        let ex = run([leg(5000, sec: 1500), leg(2000, sec: 600)])
        XCTAssertEqual(RunStats.avgPaceSecPerKm(ex)!, 300, accuracy: 0.001)
    }

    func testAvgPaceNilWithoutDistanceOrTime() {
        XCTAssertNil(RunStats.avgPaceSecPerKm(run([])))
        XCTAssertNil(RunStats.avgPaceSecPerKm(run([leg(0, sec: 600)])))
        XCTAssertNil(RunStats.avgPaceSecPerKm(run([leg(5000, sec: 0)])))
    }
}
