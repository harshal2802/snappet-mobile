import XCTest
@testable import Snappet

/// The #70 background-reliability seam: `PomodoroTimer.onScheduleChanged` must report an
/// absolute end date whenever a phase starts and `nil` whenever the countdown stops —
/// it's the single signal the phase-end notification + Live Activity hang off, so its
/// edges are locked here. Plus the pure notification copy.
@MainActor
final class PomodoroScheduleTests: XCTestCase {

    private struct Event: Equatable {
        let phase: PomodoroPhase
        let hasEnd: Bool
    }

    private func record(_ timer: PomodoroTimer) -> (events: () -> [Event], ends: () -> [Date?]) {
        var events: [Event] = []
        var ends: [Date?] = []
        timer.onScheduleChanged = { phase, end in
            events.append(Event(phase: phase, hasEnd: end != nil))
            ends.append(end)
        }
        return ({ events }, { ends })
    }

    func testStartReportsFocusEndDateAtRemaining() throws {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 25, breakMinutes: 5)
        let (events, ends) = record(timer)

        let before = Date()
        timer.start()

        XCTAssertEqual(events(), [Event(phase: .focus, hasEnd: true)])
        let end = try XCTUnwrap(ends().first ?? nil)
        // endDate ≈ now + 25 min (loose 5 s tolerance; the engine derives from the wall clock).
        XCTAssertEqual(end.timeIntervalSince(before), 25 * 60, accuracy: 5)
    }

    func testPauseReportsNil() {
        let timer = PomodoroTimer()
        let (events, _) = record(timer)
        timer.start()
        timer.pause()
        XCTAssertEqual(events().last, Event(phase: .focus, hasEnd: false))
    }

    func testResetReportsNilAndFocusPhase() {
        let timer = PomodoroTimer()
        let (events, _) = record(timer)
        timer.start()
        timer.reset()
        XCTAssertEqual(events().last, Event(phase: .focus, hasEnd: false))
        XCTAssertFalse(timer.isRunning)
    }

    func testPauseWhileIdleReportsNothing() {
        let timer = PomodoroTimer()
        let (events, _) = record(timer)
        timer.pause()
        XCTAssertTrue(events().isEmpty, "pause on an idle timer must not fire the seam")
    }

    func testApplyDurationsAloneDoesNotFireTheSeam() {
        let timer = PomodoroTimer()
        let (events, _) = record(timer)
        timer.applyDurations(focusMinutes: 50, breakMinutes: 10)
        XCTAssertTrue(events().isEmpty, "config changes don't move the schedule")
    }

    func testEndDateIsExposedWhileRunningAndNilWhenIdle() {
        let timer = PomodoroTimer()
        XCTAssertNil(timer.endDate)
        timer.start()
        XCTAssertNotNil(timer.endDate)
        timer.pause()
        XCTAssertNil(timer.endDate)
    }

    // MARK: - Paused-session preservation (#70 review)

    func testApplyDurationsPreservesAPausedSessionsRemaining() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 25, breakMinutes: 5)
        timer.start()
        timer.pause()
        let pausedRemaining = timer.remaining
        XCTAssertTrue(timer.isPaused)

        // The root view re-applies durations on every appearance; a paused session's
        // progress must survive it.
        timer.applyDurations(focusMinutes: 25, breakMinutes: 5)
        XCTAssertEqual(timer.remaining, pausedRemaining, accuracy: 0.01)

        // Reset returns to idle, where re-seeding is correct again.
        timer.reset()
        XCTAssertFalse(timer.isPaused)
        timer.applyDurations(focusMinutes: 50, breakMinutes: 10)
        XCTAssertEqual(timer.remaining, 50 * 60, accuracy: 0.01)
    }

    // MARK: - Wall-clock catch-up across suspended boundaries (#70 review)

    /// Locked through the whole focus block + 2 min of break: catch-up must land 2 min
    /// INTO the break (anchored at the focus phase's end), not restart a phase at
    /// catch-up time — and log exactly one completed focus.
    func testCatchUpAnchorsAtPhaseEndsNotAtResumeTime() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 25, breakMinutes: 5)
        var completedFocusMinutes: [Int] = []
        timer.onFocusCompleted = { completedFocusMinutes.append($0) }
        timer.start()

        timer.sync(now: Date().addingTimeInterval(27 * 60))

        XCTAssertEqual(timer.phase, .breakTime)
        XCTAssertEqual(completedFocusMinutes, [25])
        // Break started at +25 and ends at +30; at +27 there are ~3 min left.
        XCTAssertEqual(timer.remaining, 3 * 60, accuracy: 5)
        XCTAssertTrue(timer.isRunning)
    }

    /// Locked through focus AND break: lands in the SECOND focus with both completions
    /// honored on the wall clock (one focus logged, one break crossed).
    func testCatchUpWalksMultipleBoundaries() {
        let timer = PomodoroTimer()
        timer.applyDurations(focusMinutes: 25, breakMinutes: 5)
        var focusCompletions = 0
        timer.onFocusCompleted = { _ in focusCompletions += 1 }
        let (events, _) = record(timer)
        timer.start()

        timer.sync(now: Date().addingTimeInterval(32 * 60))

        XCTAssertEqual(timer.phase, .focus, "25 focus + 5 break elapsed; +32 is in focus #2")
        XCTAssertEqual(focusCompletions, 1)
        // Focus #2 spans +30...+55; at +32 there are ~23 min left.
        XCTAssertEqual(timer.remaining, 23 * 60, accuracy: 5)
        // The seam fired once per schedule move: start + one consolidated catch-up.
        XCTAssertEqual(events(), [Event(phase: .focus, hasEnd: true),
                                  Event(phase: .focus, hasEnd: true)])
    }

    // MARK: - Relaunch restore from an orphaned Live Activity (#70 review)

    func testRestoreReattachesAMidPhaseCountdown() {
        let timer = PomodoroTimer()
        let end = Date().addingTimeInterval(10 * 60)
        timer.restore(phase: .breakTime, endDate: end)
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.phase, .breakTime)
        XCTAssertEqual(timer.remaining, 10 * 60, accuracy: 5)
    }

    func testRestoreRejectsAPastEndAndARunningTimer() {
        let timer = PomodoroTimer()
        timer.restore(phase: .focus, endDate: Date().addingTimeInterval(-60))
        XCTAssertFalse(timer.isRunning, "a stale orphan must not start the timer")

        timer.start()
        let runningEnd = timer.endDate
        timer.restore(phase: .breakTime, endDate: Date().addingTimeInterval(99))
        XCTAssertEqual(timer.endDate, runningEnd, "restore must never clobber a live session")
        XCTAssertEqual(timer.phase, .focus)
    }

    // MARK: - Notification copy

    func testFocusEndCopy() {
        let (title, body) = PomodoroNotifications.phaseEndContent(endedPhase: .focus)
        XCTAssertEqual(title, "Focus complete")
        XCTAssertEqual(body, "Nice work — time for a break.")
    }

    func testBreakEndCopy() {
        let (title, body) = PomodoroNotifications.phaseEndContent(endedPhase: .breakTime)
        XCTAssertEqual(title, "Break's over")
        XCTAssertEqual(body, "Back to focus.")
    }
}
