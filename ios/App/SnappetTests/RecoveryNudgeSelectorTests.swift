import XCTest
import HighlightEngine
@testable import Snappet

/// Phase 4 (recovery nudge + effort-aligned selector) app-side tests: the achievement-window
/// derivations that feed the engine's `EffortAlignedSelector`. The `RecoveryReadiness` math and the
/// selector/fusion scoring are covered by the engine `swift test`; the live nudge UI + the watch
/// indicator are device-only (no live HR in the simulator).
final class RecoveryNudgeSelectorTests: XCTestCase {

    private let s0 = Date(timeIntervalSince1970: 1_000)

    // MARK: Kilter sent-climb windows

    func testSentClimbWindowsOnlyCoverSends() {
        let send = KilterClimbLog(climbUUID: "a", climbName: "A", gradeLabel: "V4", difficulty: 4,
                                  status: .sent, attempts: 1,
                                  startedAt: s0, endedAt: s0.addingTimeInterval(60), loggedAt: s0.addingTimeInterval(60))
        let tryOnly = KilterClimbLog(climbUUID: "b", climbName: "B", gradeLabel: "V5", difficulty: 5,
                                     status: .attempt, attempts: 3,
                                     startedAt: s0.addingTimeInterval(120), endedAt: s0.addingTimeInterval(180),
                                     loggedAt: s0.addingTimeInterval(180))
        let windows = KilterSessionStats.sentClimbWindows(from: [send, tryOnly], start: s0)
        XCTAssertEqual(windows.count, 1)                 // only the send contributes
        XCTAssertEqual(windows[0].lowerBound, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(windows[0].upperBound, 60)   // end extended past the logged end by the HR lag
    }

    func testNoSendsNoWindows() {
        let tryOnly = KilterClimbLog(climbUUID: "b", climbName: "B", gradeLabel: "V5", difficulty: 5,
                                     status: .attempt, attempts: 3,
                                     startedAt: s0, endedAt: s0.addingTimeInterval(30), loggedAt: s0.addingTimeInterval(30))
        XCTAssertTrue(KilterSessionStats.sentClimbWindows(from: [tryOnly], start: s0).isEmpty)
    }

    // MARK: WorkoutTracker peak-effort windows

    private func setLog(at completedAt: Date?) -> SetLog {
        SetLog(actualReps: nil, actualWeight: nil, weightUnit: nil, completedAt: completedAt,
               durationSec: nil, climbGradeLabel: nil, climbStatusRaw: nil, climbAttempts: nil)
    }

    func testPeakEffortWindowsCoverScoredSets() {
        let exID = UUID()
        let ex = SessionExercise(id: exID, exerciseId: "ex", targetSets: 1, targetReps: "",
                                 targetRestSeconds: 0, targetWeight: nil, targetWeightUnit: nil,
                                 sets: [setLog(at: s0.addingTimeInterval(40))],
                                 skipped: false, displayName: nil, kindRaw: SetKind.repsWeight.rawValue)
        let hr = [HRSample(t: 0, bpm: 120), HRSample(t: 20, bpm: 180), HRSample(t: 40, bpm: 120)]
        let windows = WorkoutHRStats.peakEffortWindows(for: [ex], sessionStart: s0, hr: hr)
        XCTAssertEqual(windows.count, 1)                 // the one completed, HR-scored set
        XCTAssertTrue(windows[0].contains(40))           // covers the set's completion moment
    }

    func testPeakEffortWindowsEmptyWithoutHR() {
        let ex = SessionExercise(id: UUID(), exerciseId: "ex", targetSets: 1, targetReps: "",
                                 targetRestSeconds: 0, targetWeight: nil, targetWeightUnit: nil,
                                 sets: [setLog(at: s0.addingTimeInterval(40))],
                                 skipped: false, displayName: nil, kindRaw: SetKind.repsWeight.rawValue)
        XCTAssertTrue(WorkoutHRStats.peakEffortWindows(for: [ex], sessionStart: s0, hr: []).isEmpty)
    }
}
