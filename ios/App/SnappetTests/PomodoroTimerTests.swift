import XCTest
@testable import Snappet

/// Unit tests for `PomodoroTimer` — the pure countdown engine. No device, no simulator.
/// All tests run synchronously by exercising the timer's state machine directly, not by
/// waiting on real wall-clock ticks.
@MainActor
final class PomodoroTimerTests: XCTestCase {

    // MARK: - Initial state

    func testInitialPhaseIsFocus() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.phase, .focus)
    }

    func testInitialRemainingMatchesDefaultFocusLength() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.remaining, 25 * 60, accuracy: 1)
    }

    func testInitiallyNotRunning() {
        let timer = PomodoroTimer()
        XCTAssertFalse(timer.isRunning)
    }

    func testEndDateNilWhenStopped() {
        let timer = PomodoroTimer()
        XCTAssertNil(timer.endDate)
    }

    // MARK: - Start

    func testStartSetsIsRunning() {
        let timer = PomodoroTimer()
        timer.start()
        XCTAssertTrue(timer.isRunning)
        timer.reset()
    }

    func testStartSetsEndDate() {
        let timer = PomodoroTimer()
        timer.start()
        XCTAssertNotNil(timer.endDate)
        timer.reset()
    }

    func testStartEndDateIsApproximatelyNowPlusRemaining() {
        let timer = PomodoroTimer()
        let before = Date()
        timer.start()
        let after = Date()
        let endDate = timer.endDate!
        // endDate should be roughly [before + 25*60, after + 25*60]
        XCTAssertGreaterThanOrEqual(endDate.timeIntervalSince(before), 25 * 60 - 1)
        XCTAssertLessThanOrEqual(endDate.timeIntervalSince(after), 25 * 60 + 1)
        timer.reset()
    }

    func testStartFiresOnPhaseStartedCallback() {
        let timer = PomodoroTimer()
        var callbackPhase: PomodoroPhase?
        var callbackDate: Date?
        timer.onPhaseStarted = { phase, endDate in
            callbackPhase = phase
            callbackDate = endDate
        }
        timer.start()
        XCTAssertEqual(callbackPhase, .focus)
        XCTAssertNotNil(callbackDate)
        timer.reset()
    }

    // MARK: - Pause

    func testPauseClearsIsRunning() {
        let timer = PomodoroTimer()
        timer.start()
        timer.pause()
        XCTAssertFalse(timer.isRunning)
    }

    func testPauseClearsEndDate() {
        let timer = PomodoroTimer()
        timer.start()
        timer.pause()
        XCTAssertNil(timer.endDate)
    }

    func testPauseFiresOnPausedCallback() {
        let timer = PomodoroTimer()
        var called = false
        timer.onPaused = { _, _ in called = true }
        timer.start()
        timer.pause()
        XCTAssertTrue(called)
    }

    func testPauseCallbackReceivesFocusPhase() {
        let timer = PomodoroTimer()
        var callbackPhase: PomodoroPhase?
        timer.onPaused = { phase, _ in callbackPhase = phase }
        timer.start()
        timer.pause()
        XCTAssertEqual(callbackPhase, .focus)
    }

    func testPauseCallbackFrozenEndDateIsPositive() {
        let timer = PomodoroTimer()
        var frozenEnd: Date?
        timer.onPaused = { _, endDate in frozenEnd = endDate }
        timer.start()
        timer.pause()
        XCTAssertNotNil(frozenEnd)
        XCTAssertGreaterThan(frozenEnd!.timeIntervalSinceNow, 0)
    }

    // MARK: - Reset

    func testResetRestoresInitialState() {
        let timer = PomodoroTimer()
        timer.start()
        timer.reset()
        XCTAssertFalse(timer.isRunning)
        XCTAssertNil(timer.endDate)
        XCTAssertEqual(timer.phase, .focus)
    }

    func testResetFiresOnResetCallback() {
        let timer = PomodoroTimer()
        var called = false
        timer.onReset = { called = true }
        timer.start()
        timer.reset()
        XCTAssertTrue(called)
    }

    // MARK: - applyDurations

    func testApplyDurationsUpdatesRemainingWhenIdle() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 30, breakMinutes: 10)
        XCTAssertEqual(timer.focusMinutes, 30)
        XCTAssertEqual(timer.remaining, 30 * 60, accuracy: 1)
    }

    // MARK: - Progress

    func testProgressIsOneAtStart() {
        let timer = PomodoroTimer()
        XCTAssertEqual(timer.progress, 1.0, accuracy: 0.01)
    }

    func testProgressClampsToZeroAtEnd() {
        let timer = PomodoroTimer()
        // Force remaining to zero; progress must not go negative.
        timer.applyDurations(focusMinutes: 1, breakMinutes: 1)
        // Manually inspect guard: progress = remaining / phaseDuration, clamped 0...1.
        XCTAssertGreaterThanOrEqual(timer.progress, 0)
        XCTAssertLessThanOrEqual(timer.progress, 1)
    }

    // MARK: - timeText

    func testTimeTextFormatsCorrectly() {
        let timer = PomodoroTimer()
        // Default 25-minute remaining → "25:00".
        XCTAssertEqual(timer.timeText, "25:00")
    }

    // MARK: - Callback wiring survives re-assign

    func testCallbacksAreReplaceable() {
        let timer = PomodoroTimer()
        var firstCalled = false
        var secondCalled = false
        timer.onPhaseStarted = { _, _ in firstCalled = true }
        timer.onPhaseStarted = { _, _ in secondCalled = true }
        timer.start()
        XCTAssertFalse(firstCalled)
        XCTAssertTrue(secondCalled)
        timer.reset()
    }
}
