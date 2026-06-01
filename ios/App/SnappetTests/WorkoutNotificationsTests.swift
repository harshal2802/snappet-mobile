import XCTest
@testable import Snappet

/// Unit tests for the **pure** piece of the workout notifications path — the "rest complete"
/// copy builder. No `UserNotifications`, no device: `restCompleteContent` is a plain
/// string-in/string-out function, so the wording + the next-up fallback are testable here.
/// (Scheduling against `UNUserNotificationCenter` is device/simulator-pending.)
final class WorkoutNotificationsTests: XCTestCase {

    func testRestCompleteUsesNextUpWhenPresent() {
        let (title, body) = WorkoutNotifications.restCompleteContent(nextUp: "Next: Back Squat · set 2")
        XCTAssertEqual(title, "Rest complete")
        XCTAssertEqual(body, "Next: Back Squat · set 2")
    }

    func testRestCompleteFallsBackWhenNoNextUp() {
        let (title, body) = WorkoutNotifications.restCompleteContent(nextUp: nil)
        XCTAssertEqual(title, "Rest complete")
        XCTAssertEqual(body, "Time for your next set.")
    }

    func testRestCompleteTreatsBlankNextUpAsMissing() {
        // A whitespace-only next-up line must not produce an empty notification body.
        let (_, body) = WorkoutNotifications.restCompleteContent(nextUp: "   ")
        XCTAssertEqual(body, "Time for your next set.")
    }
}
