import XCTest
@testable import Snappet

/// Unit tests for the **pure** `FreeformSummary` derivations (issue #158, workstreams B & D) — the
/// value-labelled Repeat label, the completion-summary stats with a dominant-kind headline, and the
/// milestone decision. No SwiftData, no view, no device.
final class FreeformSummaryTests: XCTestCase {

    // MARK: - Builders

    private func lift(_ reps: Int?, _ weight: Double?, unit: WeightUnit = .kg, done: Bool = true) -> SetLog {
        SetLog(actualReps: reps, actualWeight: weight, weightUnit: unit,
               completedAt: done ? Date(timeIntervalSince1970: 0) : nil)
    }
    private func climb(_ grade: String?, _ status: KilterAscentStatus,
                       attempts: Int = 1, sec: Double? = nil, done: Bool = true) -> SetLog {
        SetLog(completedAt: done ? Date(timeIntervalSince1970: 0) : nil, durationSec: sec,
               climbGradeLabel: grade, climbStatusRaw: status.rawValue, climbAttempts: attempts)
    }
    private func timed(_ sec: Double, done: Bool = true) -> SetLog {
        SetLog(completedAt: done ? Date(timeIntervalSince1970: 0) : nil, durationSec: sec)
    }
    private func exercise(_ id: String, _ kind: SetKind, _ sets: [SetLog]) -> SessionExercise {
        SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                        sets: sets, kindRaw: kind.rawValue)
    }
    private func session(_ exercises: [SessionExercise], minutes: Double = 0) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 0)
        return WorkoutSession(routineID: nil, routineName: "Quick session", startedAt: start,
                              completedAt: start.addingTimeInterval(minutes * 60), exercises: exercises)
    }

    // MARK: - Repeat label (workstream B)

    func testRepeatLabelReadsLikeTheSetItDuplicates() {
        XCTAssertEqual(FreeformSummary.repeatLabel(for: lift(8, 60), kind: .repsWeight, unit: .kg),
                       "Repeat 8 × 60 kg")
        XCTAssertEqual(FreeformSummary.repeatLabel(for: timed(45), kind: .duration, unit: .kg),
                       "Repeat 0:45")
        XCTAssertEqual(FreeformSummary.repeatLabel(for: climb("V4", .sent), kind: .climbAttempt, unit: .kg),
                       "Repeat V4 · Sent")
    }

    // MARK: - Dominant kind (workstream D)

    func testDominantPicksTheKindWithMostCompletedSets() {
        let lifting = session([
            exercise("bench", .repsWeight, [lift(8, 60), lift(8, 60)]),
            exercise("proj", .climbAttempt, [climb("V3", .sent)]),
        ])
        XCTAssertEqual(FreeformSummary.dominant(for: lifting), .lifting)

        let climbing = session([exercise("proj", .climbAttempt, [climb("V3", .sent), climb("V4", .flash)]),
                                exercise("bench", .repsWeight, [lift(8, 60)])])
        XCTAssertEqual(FreeformSummary.dominant(for: climbing), .climbing)

        let timedSession = session([exercise("plank", .duration, [timed(30), timed(30), timed(30)])])
        XCTAssertEqual(FreeformSummary.dominant(for: timedSession), .timed)
    }

    func testDominantBreaksTiesLiftingFirstAndIsNoneWhenEmpty() {
        let tie = session([exercise("bench", .repsWeight, [lift(8, 60)]),
                           exercise("proj", .climbAttempt, [climb("V3", .sent)])])
        XCTAssertEqual(FreeformSummary.dominant(for: tie), .lifting)
        XCTAssertEqual(FreeformSummary.dominant(for: session([])), .none)
        // Sets without a completion stamp don't count toward dominance.
        let uncommitted = session([exercise("bench", .repsWeight, [lift(8, 60, done: false)])])
        XCTAssertEqual(FreeformSummary.dominant(for: uncommitted), .none)
    }

    // MARK: - Completion stats (workstream D)

    func testStatsLiftingHeadlineIsVolume() {
        let s = session([exercise("bench", .repsWeight, [lift(8, 60), lift(8, 60)])], minutes: 12)
        let stats = FreeformSummary.stats(for: s, unit: .kg)
        XCTAssertEqual(stats.dominant, .lifting)
        XCTAssertEqual(stats.duration, .init(value: "12m", label: "Duration"))
        XCTAssertEqual(stats.sets, .init(value: "2", label: "Sets"))
        XCTAssertEqual(stats.headline, .init(value: "960 kg", label: "Volume"))
    }

    func testStatsClimbingHeadlineIsSends() {
        let s = session([exercise("proj", .climbAttempt,
                                   [climb("V4", .flash), climb("V5", .attempt), climb("V4", .sent)])])
        let stats = FreeformSummary.stats(for: s, unit: .kg)
        XCTAssertEqual(stats.dominant, .climbing)
        XCTAssertEqual(stats.headline, .init(value: "2", label: "Sends"))   // flash + sent, not the attempt
    }

    func testStatsTimedHeadlineIsHoldTime() {
        let s = session([exercise("plank", .duration, [timed(60), timed(90)])])
        let stats = FreeformSummary.stats(for: s, unit: .kg)
        XCTAssertEqual(stats.dominant, .timed)
        XCTAssertEqual(stats.headline, .init(value: "2:30", label: "Hold time"))
    }

    func testStatsDurationFloorsToOneMinute() {
        let s = session([exercise("bench", .repsWeight, [lift(8, 60)])], minutes: 0)
        XCTAssertEqual(FreeformSummary.stats(for: s, unit: .kg).duration.value, "1m")
    }

    // MARK: - Milestone (workstream D)

    func testPersonalRecordFiresWhenBeatingHistory() {
        let prior = session([exercise("bench", .repsWeight, [lift(5, 100)])])    // score 500
        let current = session([exercise("bench", .repsWeight, [lift(5, 120)])])  // score 600
        XCTAssertEqual(FreeformSummary.milestones(for: current, history: [prior]),
                       [.personalRecord(exerciseId: "bench", bestKg: 120, reps: 5)])
    }

    func testNoPRWhenHistoryIsHeavier() {
        let prior = session([exercise("bench", .repsWeight, [lift(5, 120)])])
        let current = session([exercise("bench", .repsWeight, [lift(5, 100)])])
        XCTAssertTrue(FreeformSummary.milestones(for: current, history: [prior]).isEmpty)
    }

    func testFirstWeightedSetWithNoHistoryIsAPR() {
        let current = session([exercise("ohp", .repsWeight, [lift(8, 40)])])
        XCTAssertEqual(FreeformSummary.milestones(for: current, history: []),
                       [.personalRecord(exerciseId: "ohp", bestKg: 40, reps: 8)])
    }

    func testBodyweightBestIsNotCelebrated() {
        let current = session([exercise("pullup", .repsWeight, [lift(12, nil)])])
        XCTAssertTrue(FreeformSummary.milestones(for: current, history: []).isEmpty)
    }

    func testFirstSendFiresWithNoPriorSendAtGrade() {
        let current = session([exercise("proj", .climbAttempt, [climb("V4", .flash)])])
        XCTAssertEqual(FreeformSummary.milestones(for: current, history: []),
                       [.firstSend(grade: "V4")])
    }

    func testFirstSendSuppressedWhenHistoryAlreadyHasASendAtThatGrade() {
        let prior = session([exercise("p", .climbAttempt, [climb("V4", .sent)])])
        let current = session([exercise("proj", .climbAttempt, [climb("V4", .flash)])])
        XCTAssertTrue(FreeformSummary.milestones(for: current, history: [prior]).isEmpty)
    }

    func testFirstSendIgnoresNonSends() {
        let current = session([exercise("proj", .climbAttempt,
                                        [climb("V4", .attempt), climb("V4", .project)])])
        XCTAssertTrue(FreeformSummary.milestones(for: current, history: []).isEmpty)
    }

    func testMilestoneHeadlineText() {
        XCTAssertEqual(FreeformSummary.milestoneHeadline(.personalRecord(exerciseId: "x", bestKg: 1, reps: 1)),
                       "New PR!")
        XCTAssertEqual(FreeformSummary.milestoneHeadline(.firstSend(grade: "V4")), "First V4 send!")
    }
}
