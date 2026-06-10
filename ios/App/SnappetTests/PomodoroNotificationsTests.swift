import XCTest
@testable import Snappet

/// Unit tests for the pure Pomodoro notification copy — `phaseEndContent(phase:)`.
/// No `UserNotifications`, no device: this is a plain string-in / string-out function,
/// so the wording for both phases is testable without any platform framework.
final class PomodoroNotificationsTests: XCTestCase {

    func testFocusPhaseEndHasNonEmptyTitle() {
        let (title, _) = PomodoroNotifications.phaseEndContent(phase: .focus)
        XCTAssertFalse(title.isEmpty, "Focus phase-end notification must have a title")
    }

    func testFocusPhaseEndHasNonEmptyBody() {
        let (_, body) = PomodoroNotifications.phaseEndContent(phase: .focus)
        XCTAssertFalse(body.isEmpty, "Focus phase-end notification must have a body")
    }

    func testBreakPhaseEndHasNonEmptyTitle() {
        let (title, _) = PomodoroNotifications.phaseEndContent(phase: .breakTime)
        XCTAssertFalse(title.isEmpty, "Break phase-end notification must have a title")
    }

    func testBreakPhaseEndHasNonEmptyBody() {
        let (_, body) = PomodoroNotifications.phaseEndContent(phase: .breakTime)
        XCTAssertFalse(body.isEmpty, "Break phase-end notification must have a body")
    }

    func testFocusAndBreakNotificationsAreDifferent() {
        let focus = PomodoroNotifications.phaseEndContent(phase: .focus)
        let breakTime = PomodoroNotifications.phaseEndContent(phase: .breakTime)
        XCTAssertNotEqual(focus.title, breakTime.title,
                          "Focus and break notifications should have distinct titles")
    }
}
