import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications for the Pomodoro timer, so a backgrounded / locked-screen user still
/// learns when a **focus or break phase ends**. Complements the always-on Live Activity
/// (which provides the persistent countdown) with a timely "phase ended" nudge.
///
/// **Layering:** the only place `UserNotifications` is touched for Pomodoro. Every entry point
/// is a **no-op** where notifications are unauthorized or the framework is unavailable, so the
/// timer flow never depends on it. The notification *copy* is built by the pure, testable
/// `phaseEndContent` — platform-free strings so the wording is unit-tested without a device.
///
/// **Schedule-at-start, cancel-on-stop:** a notification is scheduled when a phase **starts**
/// (not when it finishes), so it still reaches the user if the app is minimised or the phone
/// is locked — a RunLoop timer is suspended in the background, but a `UNCalendarNotificationTrigger`
/// fires regardless of app state. On pause or reset the pending notification is cancelled.
@MainActor
final class PomodoroNotifications {

    /// Stable identifier so a new phase-end alert replaces the previous one rather than
    /// stacking — at most one pending notification at a time.
    private static let phaseEndID = "snappet.pomodoro.phaseEnd"

    init() {}

    /// Ask for notification permission once (best-effort). Safe to call repeatedly; a denied
    /// user is respected by the system. No-op where `UserNotifications` is unavailable.
    func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Schedule a phase-end notification to fire at `date`. Call this when a phase **starts**
    /// so it reaches the user even when the app is backgrounded or the screen is locked.
    /// Cancels any prior pending alert first so a phase transition doesn't stack duplicate
    /// alerts. No-op if unauthorized or `date` is already in the past.
    func schedulePhaseEnd(phase: PomodoroPhase, at date: Date) {
        #if canImport(UserNotifications)
        guard date > Date() else { return }
        let (title, body) = Self.phaseEndContent(phase: phase)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // Calendar trigger fires at the absolute wall-clock moment, surviving suspension.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.phaseEndID, content: content, trigger: trigger)
        // Replace any prior pending alert first so a phase transition doesn't stack.
        clear()
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Cancel any pending or delivered phase-end notification (on pause or reset).
    func clear() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.phaseEndID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.phaseEndID])
        #endif
    }

    /// Pure, testable notification copy. Kept platform-free (plain strings) so the wording is
    /// unit-tested in `PomodoroNotificationsTests` without `UserNotifications` or a device.
    nonisolated static func phaseEndContent(phase: PomodoroPhase) -> (title: String, body: String) {
        switch phase {
        case .focus:
            return ("Focus complete!", "Great work. Time for a break.")
        case .breakTime:
            return ("Break's over", "Ready to focus again?")
        }
    }
}
