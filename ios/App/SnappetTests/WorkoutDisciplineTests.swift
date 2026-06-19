import XCTest
@testable import Snappet

/// Unit tests for the **pure** `WorkoutDiscipline` axis (Workout-Type Parity, Phase 0) and the
/// `SessionExercise.discipline` derivation — no SwiftUI, no SwiftData, no device. Also proves the
/// additive-Optional migration safety: a pre-parity blob (no `disciplineRaw`/`distanceMeters`/`rpe`)
/// still decodes and the discipline derives from the legacy `kind`.
final class WorkoutDisciplineTests: XCTestCase {

    // MARK: - legacyKind ↔ defaultSetKind

    func testLegacyKindDerivation() {
        XCTAssertEqual(WorkoutDiscipline(legacyKind: .repsWeight), .strength)
        XCTAssertEqual(WorkoutDiscipline(legacyKind: .duration), .timed)
        XCTAssertEqual(WorkoutDiscipline(legacyKind: .climbAttempt), .climb)
    }

    func testDefaultSetKind() {
        XCTAssertEqual(WorkoutDiscipline.strength.defaultSetKind, .repsWeight)
        XCTAssertEqual(WorkoutDiscipline.climb.defaultSetKind, .climbAttempt)
        for d in [WorkoutDiscipline.run, .dance, .timed, .other] {
            XCTAssertEqual(d.defaultSetKind, .duration, "\(d) should default to .duration")
        }
    }

    func testPrimaryAxis() {
        XCTAssertEqual(WorkoutDiscipline.strength.primaryAxis, .repsWeight)
        XCTAssertEqual(WorkoutDiscipline.climb.primaryAxis, .outcome)
        XCTAssertEqual(WorkoutDiscipline.run.primaryAxis, .distance)
        XCTAssertEqual(WorkoutDiscipline.timed.primaryAxis, .duration)
        XCTAssertEqual(WorkoutDiscipline.dance.primaryAxis, .duration)
        XCTAssertEqual(WorkoutDiscipline.other.primaryAxis, .duration)
    }

    func testRawValueRoundTrip() {
        for d in WorkoutDiscipline.allCases {
            XCTAssertEqual(WorkoutDiscipline(rawValue: d.rawValue), d)
        }
        XCTAssertEqual(WorkoutDiscipline.allCases.count, 6)
    }

    func testLabelsAndSymbolsAreNonEmpty() {
        for d in WorkoutDiscipline.allCases {
            XCTAssertFalse(d.label.isEmpty)
            XCTAssertFalse(d.symbol.isEmpty)
        }
    }

    // MARK: - SessionExercise.discipline

    func testDisciplineDerivesFromKindWhenUnset() {
        let strength = SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "",
                                       targetRestSeconds: 0, sets: [], kindRaw: SetKind.repsWeight.rawValue)
        XCTAssertNil(strength.disciplineRaw)
        XCTAssertEqual(strength.discipline, .strength)

        let climb = SessionExercise(exerciseId: "c", targetSets: 0, targetReps: "",
                                    targetRestSeconds: 0, sets: [], kindRaw: SetKind.climbAttempt.rawValue)
        XCTAssertEqual(climb.discipline, .climb)

        let timed = SessionExercise(exerciseId: "t", targetSets: 0, targetReps: "",
                                    targetRestSeconds: 0, sets: [], kindRaw: SetKind.duration.rawValue)
        XCTAssertEqual(timed.discipline, .timed)
    }

    func testExplicitDisciplineWins() {
        // A run entity is `.duration` kind but `.run` discipline.
        var run = SessionExercise(exerciseId: "r", targetSets: 0, targetReps: "",
                                  targetRestSeconds: 0, sets: [], kindRaw: SetKind.duration.rawValue)
        run.disciplineRaw = WorkoutDiscipline.run.rawValue
        XCTAssertEqual(run.discipline, .run)
        XCTAssertEqual(run.kind, .duration)
    }

    // MARK: - Migration safety (decode a pre-parity blob)

    func testLegacySessionExerciseDecodesAndDerivesDiscipline() throws {
        // A current `.climbAttempt` entity with NO disciplineRaw → synthesized Codable omits the nil
        // optional, so the encoded JSON is exactly a "pre-parity" blob. Decoding it must succeed and the
        // discipline must derive from the legacy kind.
        let ex = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: [], kindRaw: SetKind.climbAttempt.rawValue)
        let data = try JSONEncoder().encode(ex)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("disciplineRaw"), "nil disciplineRaw must be omitted (golden-stable)")

        let decoded = try JSONDecoder().decode(SessionExercise.self, from: data)
        XCTAssertNil(decoded.disciplineRaw)
        XCTAssertEqual(decoded.discipline, .climb)
    }

    func testLegacySetLogDecodesWithNilNewAxes() throws {
        let set = SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg,
                         completedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(set)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("distanceMeters"), "nil distanceMeters must be omitted")
        XCTAssertFalse(json.contains("rpe"), "nil rpe must be omitted")

        let decoded = try JSONDecoder().decode(SetLog.self, from: data)
        XCTAssertNil(decoded.distanceMeters)
        XCTAssertNil(decoded.rpe)
        XCTAssertEqual(decoded.actualReps, 8)
    }

    func testNewAxesRoundTripWhenSet() throws {
        var set = SetLog(completedAt: Date(timeIntervalSince1970: 0))
        set.distanceMeters = 5200
        set.rpe = 8
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(SetLog.self, from: data)
        XCTAssertEqual(decoded.distanceMeters, 5200)
        XCTAssertEqual(decoded.rpe, 8)
    }
}
