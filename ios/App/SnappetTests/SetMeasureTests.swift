import XCTest
@testable import Snappet

/// Unit tests for the **pure** `SetMeasure` formatting/validation across `SetKind`s — no SwiftData,
/// no view, no device.
final class SetMeasureTests: XCTestCase {

    // MARK: - repsWeight

    func testRepsWeightSummary() {
        let s = SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg, completedAt: .now)
        XCTAssertEqual(SetMeasure.summary(s, kind: .repsWeight, unit: .kg), "8 × 60 kg")
    }

    func testRepsWeightHonorsSetUnitOverDefault() {
        let s = SetLog(actualReps: 5, actualWeight: 135, weightUnit: .lb, completedAt: .now)
        XCTAssertEqual(SetMeasure.summary(s, kind: .repsWeight, unit: .kg), "5 × 135 lb")
    }

    func testRepsOnlyAndWeightOnly() {
        let repsOnly = SetLog(actualReps: 12, weightUnit: .kg, completedAt: .now)
        XCTAssertEqual(SetMeasure.summary(repsOnly, kind: .repsWeight, unit: .kg), "12 reps")
        let weightOnly = SetLog(actualWeight: 40, weightUnit: .kg, completedAt: .now)
        XCTAssertEqual(SetMeasure.summary(weightOnly, kind: .repsWeight, unit: .kg), "40 kg")
    }

    func testEmptyRepsWeightIsDash() {
        XCTAssertEqual(SetMeasure.summary(SetLog(), kind: .repsWeight, unit: .kg), "—")
    }

    // MARK: - duration

    func testDurationSummary() {
        XCTAssertEqual(SetMeasure.summary(SetLog(durationSec: 45), kind: .duration, unit: .kg), "0:45")
        XCTAssertEqual(SetMeasure.summary(SetLog(durationSec: 90), kind: .duration, unit: .kg), "1:30")
        XCTAssertEqual(SetMeasure.summary(SetLog(durationSec: 3661), kind: .duration, unit: .kg), "1:01:01")
    }

    func testZeroDurationIsDash() {
        XCTAssertEqual(SetMeasure.summary(SetLog(durationSec: 0), kind: .duration, unit: .kg), "—")
    }

    // MARK: - splitDuration (timed-set capture → Min/Sec, the inverse of min*60+sec — PR 2)

    func testSplitDurationRoundTripsThroughTheSavePath() {
        // What the live timer captures must rebuild to the same seconds the Manual fields would,
        // since `build()` does (Double(min) ?? 0)*60 + (Double(sec) ?? 0).
        for secs in [0.0, 5, 45, 60, 90, 599, 600, 3661] {
            let (m, s) = SetMeasure.splitDuration(secs)
            let rebuilt = (Double(m) ?? 0) * 60 + (Double(s) ?? 0)
            XCTAssertEqual(rebuilt, secs.rounded(), "round trip for \(secs)s")
        }
    }

    func testSplitDurationCountsTotalMinutesNoHourWrap() {
        // Two minute/second fields → minutes is the full total (3661s = 61:01), not 1:01:01.
        let (m, s) = SetMeasure.splitDuration(3661)
        XCTAssertEqual(m, "61")
        XCTAssertEqual(s, "1")
    }

    func testSplitDurationRoundsAndClampsBadInput() {
        XCTAssertEqual(SetMeasure.splitDuration(44.6).minutes, "0")
        XCTAssertEqual(SetMeasure.splitDuration(44.6).seconds, "45")   // rounds, like formatDuration
        XCTAssertEqual(SetMeasure.splitDuration(0).minutes, "0")
        XCTAssertEqual(SetMeasure.splitDuration(0).seconds, "0")
        XCTAssertEqual(SetMeasure.splitDuration(-10).seconds, "0")     // clamps negatives
        XCTAssertEqual(SetMeasure.splitDuration(.infinity).seconds, "0")
    }

    // MARK: - climbAttempt

    func testClimbFlashSummary() {
        let s = SetLog(climbGradeLabel: "V4", climbStatusRaw: KilterAscentStatus.flash.rawValue,
                       climbAttempts: 1)
        XCTAssertEqual(SetMeasure.summary(s, kind: .climbAttempt, unit: .kg), "V4 · Flash")
    }

    func testClimbProjectWithTries() {
        let s = SetLog(climbGradeLabel: "7a", climbStatusRaw: KilterAscentStatus.project.rawValue,
                       climbAttempts: 4)
        XCTAssertEqual(SetMeasure.summary(s, kind: .climbAttempt, unit: .kg), "7a · Project · 4 tries")
    }

    func testClimbSingleTryOmitsTriesCount() {
        let s = SetLog(climbGradeLabel: "V2", climbStatusRaw: KilterAscentStatus.sent.rawValue,
                       climbAttempts: 1)
        XCTAssertEqual(SetMeasure.summary(s, kind: .climbAttempt, unit: .kg), "V2 · Sent")
    }

    // MARK: - hasInput / isSend

    func testHasInput() {
        XCTAssertFalse(SetMeasure.hasInput(SetLog(), kind: .repsWeight))
        XCTAssertTrue(SetMeasure.hasInput(SetLog(actualReps: 1), kind: .repsWeight))
        XCTAssertFalse(SetMeasure.hasInput(SetLog(durationSec: 0), kind: .duration))
        XCTAssertTrue(SetMeasure.hasInput(SetLog(durationSec: 30), kind: .duration))
        XCTAssertFalse(SetMeasure.hasInput(SetLog(), kind: .climbAttempt))
        XCTAssertTrue(SetMeasure.hasInput(SetLog(climbGradeLabel: "V3"), kind: .climbAttempt))
    }

    func testIsSend() {
        XCTAssertTrue(SetMeasure.isSend(SetLog(climbStatusRaw: KilterAscentStatus.flash.rawValue)))
        XCTAssertTrue(SetMeasure.isSend(SetLog(climbStatusRaw: KilterAscentStatus.sent.rawValue)))
        XCTAssertFalse(SetMeasure.isSend(SetLog(climbStatusRaw: KilterAscentStatus.project.rawValue)))
        XCTAssertFalse(SetMeasure.isSend(SetLog()))
    }

    func testWeightFormatTrimsTrailingZero() {
        XCTAssertEqual(SetMeasure.formatWeight(60), "60")
        XCTAssertEqual(SetMeasure.formatWeight(62.5), "62.5")
    }

    func testWeightFormatDoesNotTrapOnHugeValues() {
        // 1e19 > Int.max — Int(exactly:) falls back to the plain description instead of trapping.
        XCTAssertEqual(SetMeasure.formatWeight(1e19), "1e+19")
    }

    // MARK: - Input parsing (shared by the live player + the summary's edit mode, issue #73)

    func testParseRepsTrimsAndRejectsNonNumeric() {
        XCTAssertEqual(SetMeasure.parseReps(" 8 "), 8)
        XCTAssertNil(SetMeasure.parseReps(""))
        XCTAssertNil(SetMeasure.parseReps("abc"))
        XCTAssertNil(SetMeasure.parseReps("8.5"))
    }

    func testParseWeightAcceptsDecimalCommaAndTrims() {
        XCTAssertEqual(SetMeasure.parseWeight("62,5"), 62.5)
        XCTAssertEqual(SetMeasure.parseWeight(" 60 "), 60)
        XCTAssertNil(SetMeasure.parseWeight(""))
        XCTAssertNil(SetMeasure.parseWeight("heavy"))
    }

    func testParseWeightBoundsTheInput() {
        XCTAssertEqual(SetMeasure.parseWeight("99999"), 99999)
        XCTAssertNil(SetMeasure.parseWeight("100000"))
        XCTAssertNil(SetMeasure.parseWeight("1e19"))
        XCTAssertNil(SetMeasure.parseWeight("inf"))
        XCTAssertNil(SetMeasure.parseWeight("nan"))
    }
}
