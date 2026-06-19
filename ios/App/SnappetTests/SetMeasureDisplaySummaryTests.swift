import XCTest
@testable import Snappet

/// Regression guard for `SetMeasure.displaySummary` (workout-redesign E2) — the one funnel the session
/// detail's per-set row now uses. Confirms it preserves the prior `SetTileRow.detailText` behavior:
/// the kg→display-unit conversion for strength, the timed-strength "· 0:42" append, the bodyweight
/// fallback, and delegation to `summary`/`runSummary` for climb/duration/run.
final class SetMeasureDisplaySummaryTests: XCTestCase {

    func testStrengthConvertsToDisplayUnit() {
        let set = SetLog(actualReps: 5, actualWeight: 60, weightUnit: .kg, completedAt: Date(timeIntervalSince1970: 0))
        let expected = "\(WorkoutMath.formatWeight(kg: WorkoutMath.toKg(60, .kg), unit: .kg)) kg × 5"
        XCTAssertEqual(SetMeasure.displaySummary(set, discipline: .strength, kind: .repsWeight, unit: .kg, distanceUnit: .km), expected)
    }

    func testStrengthCrossUnitConversion() {
        // A set stored in kg, displayed in lb, converts (the detail view's WYSIWYG behavior).
        let set = SetLog(actualReps: 5, actualWeight: 60, weightUnit: .kg, completedAt: Date(timeIntervalSince1970: 0))
        let expected = "\(WorkoutMath.formatWeight(kg: WorkoutMath.toKg(60, .kg), unit: .lb)) lb × 5"
        XCTAssertEqual(SetMeasure.displaySummary(set, discipline: .strength, kind: .repsWeight, unit: .lb, distanceUnit: .km), expected)
    }

    func testTimedStrengthAppendsDuration() {
        var set = SetLog(actualReps: 5, actualWeight: 60, weightUnit: .kg, completedAt: Date(timeIntervalSince1970: 0))
        set.durationSec = 42
        let s = SetMeasure.displaySummary(set, discipline: .strength, kind: .repsWeight, unit: .kg, distanceUnit: .km)
        XCTAssertTrue(s.hasSuffix(" · " + SetMeasure.formatDuration(42)), s)
    }

    func testBodyweightFallback() {
        let set = SetLog(actualReps: 8, completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(SetMeasure.displaySummary(set, discipline: .strength, kind: .repsWeight, unit: .kg, distanceUnit: .km), "8 reps")
    }

    func testDurationDelegates() {
        let set = SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: 45)
        XCTAssertEqual(SetMeasure.displaySummary(set, discipline: .timed, kind: .duration, unit: .kg, distanceUnit: .km),
                       SetMeasure.summary(set, kind: .duration, unit: .kg))
    }

    func testClimbDelegates() {
        let set = SetLog(completedAt: Date(timeIntervalSince1970: 0), climbGradeLabel: "V4",
                         climbStatusRaw: KilterAscentStatus.flash.rawValue, climbAttempts: 1)
        XCTAssertEqual(SetMeasure.displaySummary(set, discipline: .climb, kind: .climbAttempt, unit: .kg, distanceUnit: .km),
                       SetMeasure.summary(set, kind: .climbAttempt, unit: .kg))
    }

    func testRunUsesRunSummary() {
        var set = SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: 1500)
        set.distanceMeters = 5000
        XCTAssertEqual(SetMeasure.displaySummary(set, discipline: .run, kind: .duration, unit: .kg, distanceUnit: .km),
                       SetMeasure.runSummary(set, unit: .km))
    }
}
