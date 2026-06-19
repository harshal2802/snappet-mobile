import XCTest
@testable import Snappet

/// Unit tests for the **pure** `clipMoveTargets(for:)` helper (no device, no SwiftData): the
/// deep-tap "Move to attempt…" submenu's destinations for a climb = its logged attempts, titled
/// "Attempt N" (1-based) and carrying the climb's `exerciseID` + the 0-based attempt index (prompt 11).
final class ClipMoveTargetTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A climb exercise with `count` logged attempts (the values don't matter for targeting — only the
    /// count + the climb's id do).
    private func climb(id: UUID = UUID(), attempts count: Int) -> SessionExercise {
        let sets = (0..<count).map { i in
            SetLog(completedAt: t0.addingTimeInterval(Double(i) * 60),
                   climbGradeLabel: "V4", climbStatusRaw: KilterAscentStatus.sent.rawValue, climbAttempts: 1)
        }
        return SessionExercise(
            id: id, exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: sets, displayName: "Cave Roof", kindRaw: SetKind.climbAttempt.rawValue,
            climbTypeRaw: ClimbType.boulder.rawValue, climbGradeLabel: "V4")
    }

    func testOneTargetPerAttemptOneBasedTitles() {
        let id = UUID()
        let targets = clipMoveTargets(for: climb(id: id, attempts: 3))
        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(targets.map(\.title), ["Attempt 1", "Attempt 2", "Attempt 3"])
        // setIndex is 0-based (the index into `sets`); title is 1-based.
        XCTAssertEqual(targets.map(\.setIndex), [0, 1, 2])
        // Every target points at the owning climb.
        XCTAssertTrue(targets.allSatisfy { $0.exerciseID == id })
    }

    func testTargetIdsAreStableAndUniquePerAttempt() {
        let id = UUID()
        let targets = clipMoveTargets(for: climb(id: id, attempts: 4))
        XCTAssertEqual(targets.map(\.id), (0..<4).map { "\(id)-\($0)" })
        XCTAssertEqual(Set(targets.map(\.id)).count, 4)   // no duplicate ids → the ForEach is stable
    }

    func testNoAttemptsYieldsNoTargets() {
        XCTAssertTrue(clipMoveTargets(for: climb(attempts: 0)).isEmpty)
    }

    func testSingleAttempt() {
        let targets = clipMoveTargets(for: climb(attempts: 1))
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.title, "Attempt 1")
        XCTAssertEqual(targets.first?.setIndex, 0)
    }

    // MARK: - Discipline-aware nouns (Workout-Type Parity)

    private func entity(_ discipline: WorkoutDiscipline, efforts count: Int) -> SessionExercise {
        var ex = SessionExercise(
            exerciseId: "adhoc-\(discipline.rawValue)", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: (0..<count).map { _ in SetLog(completedAt: t0) },
            kindRaw: discipline.defaultSetKind.rawValue)
        ex.disciplineRaw = discipline.rawValue
        return ex
    }

    func testRunUsesLegNoun() {
        XCTAssertEqual(clipMoveTargets(for: entity(.run, efforts: 2)).map(\.title), ["Leg 1", "Leg 2"])
    }

    func testStrengthAndOtherUseSetNoun() {
        XCTAssertEqual(clipMoveTargets(for: entity(.strength, efforts: 2)).map(\.title), ["Set 1", "Set 2"])
        XCTAssertEqual(clipMoveTargets(for: entity(.dance, efforts: 1)).map(\.title), ["Set 1"])
    }
}
