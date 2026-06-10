import XCTest
@testable import Snappet

/// Unit tests for the pure Pomodoro timer engine — drift-free countdown math, progress
/// calculation, phase transitions, and the service-callback contract. No device / simulator
/// needed; `PomodoroTimer` is `@Observable` pure logic with no platform I/O.
@MainActor
final class PomodoroTimerTests: XCTestCase {

    // MARK: Initial state

    func testInitialPhaseIsFocus() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.phase, .focus)
    }

    func testInitialStateIsNotRunning() {
        let timer = PomodoroTimer()
        XCTAssertFalse(timer.isRunning)
    }

    func testInitialRemainingEqualsDefaultFocusDuration() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.remaining, 25 * 60, accuracy: 1)
    }

    func testProgressIsOneAtTopOfPhase() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.progress, 1.0, accuracy: 0.01)
    }

    func testTimeTextFormatsDefault() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.timeText, "25:00")
    }

    // MARK: applyDurations

    func testApplyDurationsUpdatesRemainingWhenIdle() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 30, breakMinutes: 10)
        XCTAssertEqual(timer.remaining, 30 * 60, accuracy: 1)
    }

    func testApplyDurationsDoesNotResetRemainingWhenRunning() {
        let timer = PomodoroTimer()
        timer.start()
        let before = timer.remaining
        timer.applyDurations(focusMinutes: 30, breakMinutes: 10)
        // Must NOT jump to 30:00 mid-run — remaining is the wall-clock counter.
        XCTAssertEqual(timer.remaining, before, accuracy: 2)
        timer.reset()
    }

    func testPhaseDurationReflectsConfiguration() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 10, breakMinutes: 3)
        XCTAssertEqual(timer.phaseDuration, 10 * 60)
    }

    // MARK: start / pause / reset

    func testStartSetsIsRunning() {
        let timer = PomodoroTimer()
        timer.start()
        XCTAssertTrue(timer.isRunning)
        timer.reset()
    }

    func testStartIsIdempotentWhenAlreadyRunning() {
        let timer = PomodoroTimer()
        timer.start()
        let endDateAfterFirst = timer.remaining
        timer.start()   // should be a no-op
        XCTAssertEqual(timer.remaining, endDateAfterFirst, accuracy: 2)
        timer.reset()
    }

    func testPauseSetsIsRunningFalse() {
        let timer = PomodoroTimer()
        timer.start()
        timer.pause()
        XCTAssertFalse(timer.isRunning)
    }

    func testResetRestoresToFocusPhase() {
        let timer = PomodoroTimer()
        timer.start()
        timer.reset()
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.phase, .focus)
        XCTAssertEqual(timer.remaining, timer.phaseDuration, accuracy: 1)
    }

    // MARK: onPhaseDidStart callback

    func testOnPhaseDidStartFiredOnStart() {
        let timer = PomodoroTimer()
        var capturedPhase: PomodoroPhase?
        var capturedEndDate: Date?
        timer.onPhaseDidStart = { phase, endDate in
            capturedPhase = phase
            capturedEndDate = endDate
        }
        timer.start()
        XCTAssertEqual(capturedPhase, .focus)
        XCTAssertNotNil(capturedEndDate)
        XCTAssertGreaterThan(capturedEndDate!, Date())
        timer.reset()
    }

    func testOnPhaseDidStartCarriesCorrectEndDate() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 10, breakMinutes: 5)
        var capturedEndDate: Date?
        timer.onPhaseDidStart = { _, endDate in capturedEndDate = endDate }
        let before = Date()
        timer.start()
        let after = Date()
        // endDate should be ~10 minutes from now.
        XCTAssertNotNil(capturedEndDate)
        let expected = 10.0 * 60
        let actual = capturedEndDate!.timeIntervalSince(before)
        XCTAssertEqual(actual, expected, accuracy: after.timeIntervalSince(before) + 1)
        timer.reset()
    }

    // MARK: onTimerDidStop callback

    func testOnTimerDidStopFiredOnPause() {
        let timer = PomodoroTimer()
        var stopCount = 0
        timer.onTimerDidStop = { stopCount += 1 }
        timer.start()
        timer.pause()
        XCTAssertEqual(stopCount, 1)
    }

    func testOnTimerDidStopFiredOnReset() {
        let timer = PomodoroTimer()
        var stopCount = 0
        timer.onTimerDidStop = { stopCount += 1 }
        timer.start()
        timer.reset()
        XCTAssertEqual(stopCount, 1)
    }

    func testOnTimerDidStopNotFiredWhenAlreadyStopped() {
        let timer = PomodoroTimer()
        var stopCount = 0
        timer.onTimerDidStop = { stopCount += 1 }
        // Calling pause/reset without starting should not fire the stop callback.
        timer.pause()
        timer.reset()
        XCTAssertEqual(stopCount, 0, "onTimerDidStop must not fire when the timer was never started")
    }
}
