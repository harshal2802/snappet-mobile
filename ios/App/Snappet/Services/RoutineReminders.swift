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
    nonisolated static let startActionID = "snappet.routine.start"
    nonisolated static let snoozeActionID = "snappet.routine.snooze"
    nonisolated static let skipActionID = "snappet.routine.skip"
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
    //
    // The COMPLETION-HANDLER forms, completed on the main thread (prompt 193). The `async` forms let iOS run its
    // completion off-main, which calls into UIApplication state restoration and trips a main-thread assertion —
    // tapping a reminder crashed the app (2 device reports, 2026-10-19: `-[UIApplication
    // _performBlockAfterCATransactionCommitSynchronizes:]` from a cooperative thread).

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        let options: UNNotificationPresentationOptions =
            notification.request.content.categoryIdentifier == Self.categoryID ? [.banner, .list, .sound] : []
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async { done(options) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // Read everything off the response now — it isn't Sendable.
        let content = response.notification.request.content
        let tap = Tap(category: content.categoryIdentifier, id: response.notification.request.identifier,
                      actionID: response.actionIdentifier, original: content.userInfo["original"] as? String,
                      title: content.title, body: content.body, sound: content.sound != nil,
                      level: content.interruptionLevel)
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            await self.handle(tap)
            done()   // on the main thread
        }
    }

    /// A tapped notification, as plain values.
    struct Tap: Sendable {
        let category: String
        let id: String
        let actionID: String
        let original: String?
        let title: String
        let body: String
        let sound: Bool
        let level: UNNotificationInterruptionLevel
    }

    /// What a tap means (pure): an action for the shell, a snooze to schedule, or nothing.
    enum TapOutcome: Equatable, Sendable {
        case action(Action)
        case snooze(originalID: String, routineID: UUID)
        case ignore
    }

    nonisolated static func outcome(of tap: Tap) -> TapOutcome {
        guard tap.category == categoryID else { return .ignore }
        // Snoozes carry the original id in userInfo (their own id is the per-routine snooze slot).
        let originalID = tap.original ?? tap.id
        guard let (routineID, day) = PlannedRoutineNotification.parse(originalID) else { return .ignore }
        switch tap.actionID {
        case startActionID: return .action(.start(routineID))
        case skipActionID: return .action(.skip(routineID, day))
        case snoozeActionID: return .snooze(originalID: originalID, routineID: routineID)
        case UNNotificationDefaultActionIdentifier: return .action(.open(routineID))
        default: return .ignore
        }
    }

    private func handle(_ tap: Tap) async {
        switch Self.outcome(of: tap) {
        case .action(let action):
            pendingAction = action
        case .snooze(let originalID, let routineID):
            let snooze = UNMutableNotificationContent()
            snooze.title = tap.title
            snooze.body = tap.body
            snooze.sound = tap.sound ? .default : nil
            snooze.interruptionLevel = tap.level
            snooze.categoryIdentifier = Self.categoryID
            snooze.userInfo = ["original": originalID]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(Self.snoozeMinutes * 60),
                                                            repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.snoozePrefix + routineID.uuidString,
                                                        content: snooze, trigger: trigger))
        case .ignore:
            break
        }
    }
}
