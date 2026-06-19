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

    func testSplitDurationCarriesAtTheMinuteBoundary() {
        // Rounding up to a full minute must carry into minutes, never emit seconds == "60".
        XCTAssertEqual(SetMeasure.splitDuration(59.6).minutes, "1")
        XCTAssertEqual(SetMeasure.splitDuration(59.6).seconds, "0")
        // …and the carry still round-trips through the save path's min*60 + sec.
        for secs in [59.6, 119.5, 3599.7] {
            let (min, sec) = SetMeasure.splitDuration(secs)
            XCTAssertEqual(Double(min)! * 60 + Double(sec)!, secs.rounded(), "carry round trip for \(secs)s")
        }
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

    // MARK: - climbAttempt + optional per-attempt timer (durationSec reuse — PR 4)

    func testClimbWithTimedAttemptAppendsDuration() {
        // The optional per-attempt timer (PR 4) stores its capture in the otherwise-unused durationSec;
        // the summary appends it after grade/status/tries via the one duration funnel.
        let s = SetLog(durationSec: 42, climbGradeLabel: "V4",
                       climbStatusRaw: KilterAscentStatus.sent.rawValue, climbAttempts: 3)
        XCTAssertEqual(SetMeasure.summary(s, kind: .climbAttempt, unit: .kg), "V4 · Sent · 3 tries · 0:42")
    }

    func testClimbSingleTryWithDurationStillOmitsTries() {
        // tries == 1 still omits "1 tries"; the duration is appended right after grade/status.
        let s = SetLog(durationSec: 90, climbGradeLabel: "V2",
                       climbStatusRaw: KilterAscentStatus.flash.rawValue, climbAttempts: 1)
        XCTAssertEqual(SetMeasure.summary(s, kind: .climbAttempt, unit: .kg), "V2 · Flash · 1:30")
    }

    func testClimbWithoutDurationIsUnchanged() {
        // No timer used → durationSec stays nil → the summary is exactly the pre-PR-4 format.
        let s = SetLog(climbGradeLabel: "V4", climbStatusRaw: KilterAscentStatus.sent.rawValue,
                       climbAttempts: 3)
        XCTAssertEqual(SetMeasure.summary(s, kind: .climbAttempt, unit: .kg), "V4 · Sent · 3 tries")
        // A zero/absent capture is dropped too (matches the .duration "> 0" rule).
        let zero = SetLog(durationSec: 0, climbGradeLabel: "V4",
                          climbStatusRaw: KilterAscentStatus.sent.rawValue, climbAttempts: 3)
        XCTAssertEqual(SetMeasure.summary(zero, kind: .climbAttempt, unit: .kg), "V4 · Sent · 3 tries")
    }

    // MARK: - attemptRow (per-attempt row under a climb card — Quick Session redesign)

    func testAttemptRowBoulderOutcomeOnly() {
        // The grade is NEVER in the row (it's on the card header); a single try omits the count.
        let s = SetLog(climbStatusRaw: KilterAscentStatus.sent.rawValue, climbAttempts: 1)
        XCTAssertEqual(SetMeasure.attemptRow(s, type: .boulder), "Sent")
    }

    func testAttemptRowAppendsDurationButNeverGrade() {
        // Even though the attempt is stamped with the climb grade, the row shows outcome + time only.
        let s = SetLog(durationSec: 42, climbGradeLabel: "V4",
                       climbStatusRaw: KilterAscentStatus.sent.rawValue, climbAttempts: 1)
        XCTAssertEqual(SetMeasure.attemptRow(s, type: .boulder), "Sent · 0:42")
        XCTAssertFalse(SetMeasure.attemptRow(s, type: .boulder).contains("V4"))
    }

    func testAttemptRowShowsTriesWhenAboveOne() {
        let s = SetLog(climbStatusRaw: KilterAscentStatus.project.rawValue, climbAttempts: 2)
        XCTAssertEqual(SetMeasure.attemptRow(s, type: .boulder), "Project · 2 tries")
    }

    func testAttemptRowRelabelsRouteOutcomes() {
        // A route relabels the same KilterAscentStatus via ClimbType.statusLabel (flash→Onsight, …).
        let flash = SetLog(climbStatusRaw: KilterAscentStatus.flash.rawValue, climbAttempts: 1)
        XCTAssertEqual(SetMeasure.attemptRow(flash, type: .lead), "Onsight")
        let sent = SetLog(durationSec: 90, climbStatusRaw: KilterAscentStatus.sent.rawValue,
                          climbAttempts: 1)
        XCTAssertEqual(SetMeasure.attemptRow(sent, type: .sport), "Redpoint · 1:30")
        let fell = SetLog(climbStatusRaw: KilterAscentStatus.attempt.rawValue, climbAttempts: 3)
        XCTAssertEqual(SetMeasure.attemptRow(fell, type: .topRope), "Fell · 3 tries")
    }

    func testAttemptRowWithNoOutcomeIsDash() {
        XCTAssertEqual(SetMeasure.attemptRow(SetLog(), type: .boulder), "—")
    }

    // MARK: - climbName (named free-flow climb session — PR 5)

    func testClimbNameTrimsSurroundingWhitespace() {
        XCTAssertEqual(SetMeasure.climbName("  Cave Project  "), "Cave Project")
        XCTAssertEqual(SetMeasure.climbName("Blue V4"), "Blue V4")
    }

    func testClimbNameFallsBackToClimbingWhenBlank() {
        // Empty/whitespace-only entries must never log under a blank header → the generic "Climbing".
        XCTAssertEqual(SetMeasure.climbName(""), "Climbing")
        XCTAssertEqual(SetMeasure.climbName("   "), "Climbing")
        XCTAssertEqual(SetMeasure.climbName("\n\t "), "Climbing")
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

    // MARK: - duplicate (one-tap repeat-set loop — PR 3)

    func testDuplicateClearsOnlyTheCompletedAtStamp() {
        // The repeat loop logs a NEW set identical to the last — same fields, no stamp (appendLog owns it).
        let original = SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg,
                              completedAt: Date(timeIntervalSince1970: 1_000))
        let copy = SetMeasure.duplicate(original)
        XCTAssertNil(copy.completedAt, "the copy carries no stamp — appendLog stamps it on append")
        // Everything else round-trips verbatim — easiest proof: clear the stamp and compare wholesale.
        var expected = original
        expected.completedAt = nil
        XCTAssertEqual(copy, expected)
    }

    func testDuplicateCarriesEveryRepsWeightField() {
        let copy = SetMeasure.duplicate(
            SetLog(actualReps: 5, actualWeight: 62.5, weightUnit: .lb, completedAt: .now))
        XCTAssertEqual(copy.actualReps, 5)
        XCTAssertEqual(copy.actualWeight, 62.5)
        XCTAssertEqual(copy.weightUnit, .lb)
        XCTAssertNil(copy.completedAt, "the stamp is cleared; appendLog stamps it on append")
        // The summary of the copy reads identically to the original's — a logged loop of the same set.
        XCTAssertEqual(SetMeasure.summary(copy, kind: .repsWeight, unit: .kg), "5 × 62.5 lb")
    }

    func testDuplicateCarriesDurationField() {
        let copy = SetMeasure.duplicate(SetLog(completedAt: .now, durationSec: 45))
        XCTAssertEqual(copy.durationSec, 45)
        XCTAssertNil(copy.completedAt, "the stamp is cleared; appendLog stamps it on append")
        XCTAssertEqual(SetMeasure.summary(copy, kind: .duration, unit: .kg), "0:45")
    }

    func testDuplicateCarriesEveryClimbField() {
        let original = SetLog(completedAt: .now, climbGradeLabel: "7a",
                              climbStatusRaw: KilterAscentStatus.project.rawValue, climbAttempts: 4)
        let copy = SetMeasure.duplicate(original)
        XCTAssertEqual(copy.climbGradeLabel, "7a")
        XCTAssertEqual(copy.climbStatusRaw, KilterAscentStatus.project.rawValue)
        XCTAssertEqual(copy.climbAttempts, 4)
        XCTAssertNil(copy.completedAt, "the stamp is cleared; appendLog stamps it on append")
        XCTAssertEqual(SetMeasure.summary(copy, kind: .climbAttempt, unit: .kg), "7a · Project · 4 tries")
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

    // MARK: - Combined reps×weight×time (Workout-Type Parity, Phase 0)

    func testRepsWeightAppendsDurationWhenTimed() {
        let s = SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg,
                       completedAt: .now, durationSec: 42)
        XCTAssertEqual(SetMeasure.summary(s, kind: .repsWeight, unit: .kg), "8 × 60 kg · 0:42")
    }

    func testRepsWeightNoDurationIsUnchanged() {
        let s = SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg, completedAt: .now, durationSec: 0)
        XCTAssertEqual(SetMeasure.summary(s, kind: .repsWeight, unit: .kg), "8 × 60 kg")
    }

    func testEmptyRepsWeightStaysDashEvenWithDuration() {
        let s = SetLog(completedAt: .now, durationSec: 30)
        XCTAssertEqual(SetMeasure.summary(s, kind: .repsWeight, unit: .kg), "—")
    }

    // MARK: - Distance / pace / run summary (Workout-Type Parity, Phase 0)

    func testFormatDistanceKm() {
        XCTAssertEqual(SetMeasure.formatDistance(5200, unit: .km), "5.2 km")
        XCTAssertEqual(SetMeasure.formatDistance(5000, unit: .km), "5 km")
        XCTAssertEqual(SetMeasure.formatDistance(0, unit: .km), "—")
    }

    func testFormatDistanceMi() {
        XCTAssertEqual(SetMeasure.formatDistance(1609.344, unit: .mi), "1 mi")
        XCTAssertEqual(SetMeasure.formatDistance(8046.72, unit: .mi), "5 mi")
    }

    func testFormatPace() {
        XCTAssertEqual(SetMeasure.formatPace(secPerKm: 300, unit: .km), "5:00/km")
        XCTAssertEqual(SetMeasure.formatPace(secPerKm: 301, unit: .km), "5:01/km")
        XCTAssertEqual(SetMeasure.formatPace(secPerKm: 0, unit: .km), "—")
        // 300 s/km → 300 × 1.609344 ≈ 482.8 s/mi → 8:03/mi
        XCTAssertEqual(SetMeasure.formatPace(secPerKm: 300, unit: .mi), "8:03/mi")
    }

    func testRunSummaryAllAxes() {
        var s = SetLog(completedAt: .now, durationSec: 1564)
        s.distanceMeters = 5200
        XCTAssertEqual(SetMeasure.runSummary(s, unit: .km), "5.2 km · 26:04 · 5:01/km")
    }

    func testRunSummaryDistanceOnly() {
        var s = SetLog(completedAt: .now)
        s.distanceMeters = 5000
        XCTAssertEqual(SetMeasure.runSummary(s, unit: .km), "5 km")
    }

    func testRunSummaryEmptyIsDash() {
        XCTAssertEqual(SetMeasure.runSummary(SetLog(), unit: .km), "—")
    }
}
