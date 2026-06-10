import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications for the Pomodoro timer, so a backgrounded / locked phone still learns
/// when a phase ends. Schedules one alert per phase at the phase's absolute `endDate`; cancels
/// it on pause or reset. This complements the Live Activity (persistent status) with a timely
/// "Focus block complete" nudge — straight copy of the `WorkoutNotifications` pattern
/// (decisions.md 2026-06-10).
///
/// **Layering:** the only place `UserNotifications` is touched for Pomodoro. Every entry point
/// is a **no-op** where notifications are unauthorized or the framework is unavailable.
/// The notification *copy* is the pure, testable `phaseEndContent(phase:)`.
@MainActor
final class PomodoroNotifications {

    /// Stable identifier so a re-fired phase-end alert replaces the previous one rather than stacking.
    private static let phaseEndID = "snappet.pomodoro.phaseEnd"

    init() {}

    /// Ask for notification permission once (best-effort). Safe to call repeatedly; a denied
    /// user is respected by the system. No-op where `UserNotifications` is unavailable.
    func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Schedule a phase-end notification to fire at `endDate`. Called when a phase starts running
    /// so the alert still fires if the phone is locked or the app is backgrounded — a foreground
    /// ticker is suspended in the background, but a scheduled local notification is not. Cancel via
    /// `cancel()` on pause or reset. No-op if unauthorized / `endDate` is in the past.
    func schedulePhaseEnd(phase: String, at endDate: Date) {
        #if canImport(UserNotifications)
        let delay = endDate.timeIntervalSinceNow
        guard delay > 0 else { return }
        let (title, body) = Self.phaseEndContent(phase: phase)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: Self.phaseEndID, content: content, trigger: trigger)
        // Replace any prior pending phase-end alert so a re-started phase doesn't stack.
        cancel()
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Cancel any pending or delivered phase-end notification (on pause, reset, or manual stop).
    func cancel() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.phaseEndID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.phaseEndID])
        #endif
    }

    /// Pure, testable notification copy. Platform-free so the wording is unit-tested without
    /// `UserNotifications` or a device. `phase` is "Focus" or "Break".
    nonisolated static func phaseEndContent(phase: String) -> (title: String, body: String) {
        if phase == "Focus" {
            return ("Focus block complete", "Time for a break. Great work!")
        }
        return ("Break over", "Ready to focus? Start your next block.")
    }
}
