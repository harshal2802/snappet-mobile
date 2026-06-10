import XCTest
@testable import Snappet

/// Unit tests for `PomodoroTimer` pure logic. No device, no simulator: the timer's math
/// (progress, timeText, phaseDuration, applyDurations) is tested here. Scheduling the RunLoop
/// ticker is out of scope for unit tests — that's device/sim-pending.
@MainActor
final class PomodoroTimerTests: XCTestCase {

    func testInitialStateIsFocusPhaseNotRunning() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.remaining, 25 * 60, accuracy: 0.01)
    }

    func testPhaseDurationFocus() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.phaseDuration, 25 * 60, accuracy: 0.01)
    }

    func testPhaseDurationBreak() {
        let timer = PomodoroTimer()
        // Manually seed a break phase to check break duration.
        timer.focusMinutes = 25
        timer.breakMinutes = 5
        // applyDurations re-seeds remaining for the current (focus) phase; check values.
        timer.applyDurations(focusMinutes: 25, breakMinutes: 5)
        XCTAssertEqual(timer.phaseDuration, 25 * 60, accuracy: 0.01) // still focus phase
    }

    func testApplyDurationsUpdatesRemainingWhenIdle() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 30, breakMinutes: 10)
        XCTAssertEqual(timer.focusMinutes, 30)
        XCTAssertEqual(timer.breakMinutes, 10)
        XCTAssertEqual(timer.remaining, 30 * 60, accuracy: 0.01)
    }

    func testProgressIsOneAtStart() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.progress, 1.0, accuracy: 0.001)
    }

    func testTimeTextFormatMMSS() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 25, breakMinutes: 5)
        // remaining = 25*60 = 1500 → "25:00"
        XCTAssertEqual(timer.timeText, "25:00")
    }

    func testResetRestoresToFocusPhase() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 10, breakMinutes: 3)
        timer.reset()
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.remaining, 10 * 60, accuracy: 0.01)
    }

    func testPhaseEndDateIsNilBeforeStart() {
        let timer = PomodoroTimer()
        XCTAssertNil(timer.phaseEndDate)
    }
}
