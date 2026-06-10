import XCTest
@testable import Snappet

/// Unit tests for the **pure** piece of the Pomodoro notifications path — the phase-complete
/// copy builder. No `UserNotifications`, no device: `phaseCompleteContent(phase:)` is a plain
/// enum-in/string-out function, so the wording for both phases is testable here.
/// (Scheduling against `UNUserNotificationCenter` is device/simulator-pending.)
final class PomodoroNotificationsTests: XCTestCase {

    func testFocusCompleteTitle() {
        let (title, _) = PomodoroNotifications.phaseCompleteContent(phase: .focus)
        XCTAssertEqual(title, "Focus block complete")
    }

    func testFocusCompleteBodyEncouragesBreak() {
        let (_, body) = PomodoroNotifications.phaseCompleteContent(phase: .focus)
        XCTAssertFalse(body.isEmpty, "focus-complete body must not be empty")
        XCTAssertTrue(body.lowercased().contains("break"),
                      "focus-complete body should mention a break; got '\(body)'")
    }

    func testBreakCompleteTitle() {
        let (title, _) = PomodoroNotifications.phaseCompleteContent(phase: .breakTime)
        XCTAssertEqual(title, "Break's over")
    }

    func testBreakCompleteBodyEncouragesFocus() {
        let (_, body) = PomodoroNotifications.phaseCompleteContent(phase: .breakTime)
        XCTAssertFalse(body.isEmpty, "break-complete body must not be empty")
        XCTAssertTrue(body.lowercased().contains("focus"),
                      "break-complete body should mention the next focus block; got '\(body)'")
    }

    func testFocusAndBreakTitlesDiffer() {
        let (focusTitle, _) = PomodoroNotifications.phaseCompleteContent(phase: .focus)
        let (breakTitle, _) = PomodoroNotifications.phaseCompleteContent(phase: .breakTime)
        XCTAssertNotEqual(focusTitle, breakTitle,
                          "focus and break completion should have distinct notification titles")
    }
}
