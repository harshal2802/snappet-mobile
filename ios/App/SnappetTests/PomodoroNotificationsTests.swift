import XCTest
@testable import Snappet

/// Unit tests for the pure notification-copy builder. No `UserNotifications`, no device:
/// `phaseCompleteContent` is a plain string-in/string-out function — the wording is testable here.
/// (Scheduling against `UNUserNotificationCenter` is device/simulator-pending.)
final class PomodoroNotificationsTests: XCTestCase {

    func testFocusPhaseNotificationCopy() {
        let (title, body) = PomodoroNotifications.phaseCompleteContent(phase: .focus)
        XCTAssertEqual(title, "Focus session complete")
        XCTAssertEqual(body, "Time for a well-deserved break.")
    }

    func testBreakPhaseNotificationCopy() {
        let (title, body) = PomodoroNotifications.phaseCompleteContent(phase: .breakTime)
        XCTAssertEqual(title, "Break's over")
        XCTAssertEqual(body, "Ready to focus again?")
    }
}
