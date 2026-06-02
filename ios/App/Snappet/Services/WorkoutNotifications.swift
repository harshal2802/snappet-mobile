import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications for the WorkoutTracker, so a backgrounded / minimized workout can still
/// reach the user's **notification bar**. Today it fires one alert: *rest complete* — when the
/// per-set rest timer finishes while the app isn't foregrounded (e.g. the player was minimized,
/// the phone is pocketed, the screen is locked). This complements the always-on Live Activity
/// (which is the persistent notification-area status) with a timely "your rest is over" nudge.
///
/// **Layering:** the only place `UserNotifications` is touched. Every entry point is a **no-op**
/// where notifications are unauthorized or the framework is unavailable, so the workout flow never
/// depends on it. The notification *copy* is built by the pure, testable `restCompleteContent`.
@MainActor
final class WorkoutNotifications {

    /// Stable identifier so a re-fired rest alert replaces the previous one rather than stacking.
    private static let restCompleteID = "snappet.workout.restComplete"

    init() {}

    /// Ask for notification permission once (best-effort). Safe to call repeatedly; a denied
    /// user is respected by the system. No-op where `UserNotifications` is unavailable.
    func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Schedule a "rest complete" notification to fire after `seconds`. Scheduled when the rest
    /// timer **starts** (not when it finishes) so it still reaches the user if the player is
    /// minimized or the phone is locked — a foreground `Task.sleep` countdown is suspended in the
    /// background, but a scheduled local notification is not. Cancel it via `clear()` when the
    /// user skips rest, pauses, or the rest completes while the app is foregrounded. `nextUp` is
    /// the optional "Next: …" line. No-op if unauthorized / `seconds <= 0`.
    func scheduleRestComplete(after seconds: TimeInterval, nextUp: String?) {
        #if canImport(UserNotifications)
        guard seconds > 0 else { return }
        let (title, body) = Self.restCompleteContent(nextUp: nextUp)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: Self.restCompleteID, content: content, trigger: trigger)
        // Replace any prior pending rest alert first so a re-started rest doesn't stack.
        clear()
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Clear any pending/delivered rest-complete notification (e.g. on workout end), so a stale
    /// "rest over" alert doesn't linger after the session.
    func clear() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.restCompleteID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.restCompleteID])
        #endif
    }

    /// Pure, testable notification copy. Kept platform-free (plain strings) so the wording +
    /// the next-up fallback are unit-tested without `UserNotifications` or a device.
    nonisolated static func restCompleteContent(nextUp: String?) -> (title: String, body: String) {
        let title = "Rest complete"
        if let nextUp, !nextUp.trimmingCharacters(in: .whitespaces).isEmpty {
            return (title, nextUp)
        }
        return (title, "Time for your next set.")
    }
}
