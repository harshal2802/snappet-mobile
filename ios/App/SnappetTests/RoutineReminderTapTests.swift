import XCTest
import UserNotifications
@testable import Snappet

/// What tapping a routine reminder means (prompt 193 — the delegate now completes on the main thread; the decision
/// it makes is pure and tested here).
final class RoutineReminderTapTests: XCTestCase {
    private let routine = UUID()
    private let day = DayKey(Date(timeIntervalSince1970: 1_800_000_000), calendar: .current)

    private func tap(_ action: String, category: String = RoutineReminders.categoryID,
                     id: String? = nil, original: String? = nil) -> RoutineReminders.Tap {
        .init(category: category,
              id: id ?? PlannedRoutineNotification.makeID(routineID: routine, day: day, kind: .reminder),
              actionID: action, original: original, title: "Push Day", body: "Time to train", sound: true,
              level: .timeSensitive)
    }

    func testTheActions() {
        XCTAssertEqual(RoutineReminders.outcome(of: tap(RoutineReminders.startActionID)), .action(.start(routine)))
        XCTAssertEqual(RoutineReminders.outcome(of: tap(RoutineReminders.skipActionID)), .action(.skip(routine, day)))
        XCTAssertEqual(RoutineReminders.outcome(of: tap(UNNotificationDefaultActionIdentifier)), .action(.open(routine)))
    }

    func testSnoozeKeepsTheOriginalID() {
        let original = PlannedRoutineNotification.makeID(routineID: routine, day: day, kind: .reminder)
        // A snoozed reminder's own id is the snooze slot; the original rides in userInfo.
        let t = tap(RoutineReminders.snoozeActionID, id: "snappet.routineSnooze.\(routine)", original: original)
        XCTAssertEqual(RoutineReminders.outcome(of: t), .snooze(originalID: original, routineID: routine))
        XCTAssertEqual(RoutineReminders.outcome(of: tap(UNNotificationDefaultActionIdentifier,
                                                        id: "snappet.routineSnooze.\(routine)", original: original)),
                       .action(.open(routine)), "tapping a snoozed one opens its routine")
    }

    func testOtherNotificationsAreIgnored() {
        XCTAssertEqual(RoutineReminders.outcome(of: tap(UNNotificationDefaultActionIdentifier, category: "other")), .ignore)
        XCTAssertEqual(RoutineReminders.outcome(of: tap(UNNotificationDefaultActionIdentifier, id: "garbage")), .ignore)
        XCTAssertEqual(RoutineReminders.outcome(of: tap(UNNotificationDismissActionIdentifier)), .ignore)
    }
}
