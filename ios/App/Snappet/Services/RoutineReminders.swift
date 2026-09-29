import Foundation
import Observation
import UserNotifications

/// The `UserNotifications` edge for scheduled routines (prompt 136): installs the reminder category
/// (Start now · Snooze 15 min · Skip today), replaces the pending routine notifications with a planner
/// result, and — as the app's `UNUserNotificationCenterDelegate` — turns a tapped action into a
/// `pendingAction` the shell dispatches (it owns the router + model context this service must not).
///
/// The delegate only claims **routine** notifications: anything else keeps the pre-136 behaviour (no
/// banner while foregrounded, a tap just opens the app), so rest-complete / Pomodoro / festival alerts
/// are unchanged.
@MainActor
@Observable
final class RoutineReminders: NSObject, UNUserNotificationCenterDelegate {
    enum Action: Equatable, Sendable {
        /// "Start now" — open the tracker and start this routine.
        case start(UUID)
        /// A tap on the notification body — open the tracker's Routines (the Up next card).
        case open(UUID)
        /// "Skip today" — mark `day` skipped for this routine.
        case skip(UUID, DayKey)
    }

    /// Set by a notification response; the shell consumes + clears it.
    var pendingAction: Action?

    nonisolated static let categoryID = "snappet.routine.reminder"
    private nonisolated static let startActionID = "snappet.routine.start"
    private nonisolated static let snoozeActionID = "snappet.routine.snooze"
    private nonisolated static let skipActionID = "snappet.routine.skip"
    private nonisolated static let snoozePrefix = "snappet.routineSnooze."
    nonisolated static let snoozeMinutes = 15

    private var center: UNUserNotificationCenter { .current() }

    /// Become the notification delegate and register the action category. Call once, at launch, so a
    /// cold start from a tapped action is delivered.
    func install() {
        center.delegate = self
        let start = UNNotificationAction(identifier: Self.startActionID, title: "Start now",
                                         options: [.foreground], icon: .init(systemImageName: "play.fill"))
        let snooze = UNNotificationAction(identifier: Self.snoozeActionID, title: "Snooze \(Self.snoozeMinutes) min",
                                          options: [], icon: .init(systemImageName: "clock"))
        let skip = UNNotificationAction(identifier: Self.skipActionID, title: "Skip today",
                                        options: [], icon: .init(systemImageName: "arrow.uturn.right"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [start, snooze, skip],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Ask for permission (alert + sound). Returns whether reminders can be delivered.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Make the pending routine notifications exactly `plan` (snoozes are left alone).
    func apply(_ plan: [PlannedRoutineNotification]) async {
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(PlannedRoutineNotification.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for item in plan {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = item.sound ? .default : nil
            content.interruptionLevel = item.timeSensitive ? .timeSensitive : .active
            content.categoryIdentifier = Self.categoryID
            content.threadIdentifier = "snappet.routine.\(item.routineID.uuidString)"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                        from: item.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
        }
    }

    /// Drop the delivered notifications for `routineID` (after it's started / skipped) plus any snooze.
    func clearDelivered(for routineID: UUID) async {
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let mine = delivered.filter { PlannedRoutineNotification.parse($0)?.routineID == routineID }
        center.removeDeliveredNotifications(withIdentifiers: mine)
        center.removePendingNotificationRequests(withIdentifiers: [Self.snoozePrefix + routineID.uuidString])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == Self.categoryID ? [.banner, .list, .sound] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == Self.categoryID else { return }
        let id = response.notification.request.identifier
        let actionID = response.actionIdentifier
        let title = content.title, body = content.body
        let sound = content.sound != nil
        let level = content.interruptionLevel
        // Snoozes carry the original id in userInfo (their own id is the per-routine snooze slot).
        let originalID = (content.userInfo["original"] as? String) ?? id
        guard let (routineID, day) = PlannedRoutineNotification.parse(originalID) else { return }

        switch actionID {
        case Self.startActionID:
            await MainActor.run { pendingAction = .start(routineID) }
        case Self.skipActionID:
            await MainActor.run { pendingAction = .skip(routineID, day) }
        case Self.snoozeActionID:
            let snooze = UNMutableNotificationContent()
            snooze.title = title
            snooze.body = body
            snooze.sound = sound ? .default : nil
            snooze.interruptionLevel = level
            snooze.categoryIdentifier = Self.categoryID
            snooze.userInfo = ["original": originalID]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(Self.snoozeMinutes * 60),
                                                            repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.snoozePrefix + routineID.uuidString,
                                                        content: snooze, trigger: trigger))
        case UNNotificationDefaultActionIdentifier:
            await MainActor.run { pendingAction = .open(routineID) }
        default:
            break
        }
    }
}
