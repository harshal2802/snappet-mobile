import XCTest
@testable import Snappet

/// Unit tests for the **pure** piece of the Pomodoro notifications path — the phase-end
/// copy builder. No `UserNotifications`, no device: `phaseEndContent(phase:)` is a plain
/// string-in/string-out function, so the wording is testable here.
/// (Scheduling against `UNUserNotificationCenter` is device/simulator-pending.)
final class PomodoroNotificationsTests: XCTestCase {

    func testFocusPhaseEndContent() {
        let (title, body) = PomodoroNotifications.phaseEndContent(phase: "Focus")
        XCTAssertEqual(title, "Focus block complete")
        XCTAssertFalse(body.isEmpty)
    }

    func testBreakPhaseEndContent() {
        let (title, body) = PomodoroNotifications.phaseEndContent(phase: "Break")
        XCTAssertEqual(title, "Break over")
        XCTAssertFalse(body.isEmpty)
    }

    func testFocusTitleIsDistinctFromBreakTitle() {
        let (focusTitle, _) = PomodoroNotifications.phaseEndContent(phase: "Focus")
        let (breakTitle, _) = PomodoroNotifications.phaseEndContent(phase: "Break")
        XCTAssertNotEqual(focusTitle, breakTitle)
    }

    func testFocusBodyIsDistinctFromBreakBody() {
        let (_, focusBody) = PomodoroNotifications.phaseEndContent(phase: "Focus")
        let (_, breakBody) = PomodoroNotifications.phaseEndContent(phase: "Break")
        XCTAssertNotEqual(focusBody, breakBody)
    }
}
