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
