import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications for the Pomodoro focus timer, so a backgrounded / locked-screen session
/// delivers an alert when a phase ends. Scheduled at **phase start** (not on completion) so the
/// alert reaches the user even when the app is suspended — a foreground Timer is suspended in the
/// background, but a scheduled `UNNotification` is not (same rationale as `WorkoutNotifications`).
///
/// **Layering:** the only place `UserNotifications` is touched for Pomodoro. Every entry point is
/// a **no-op** where notifications are unauthorized or the framework is unavailable, so the timer
/// flow never depends on it. The notification *copy* is built by the pure, testable `phaseCompleteContent`.
@MainActor
final class PomodoroNotifications {

    /// Stable identifier so a re-fired phase alert replaces the previous one rather than stacking.
    private static let phaseCompleteID = "snappet.pomodoro.phaseComplete"

    init() {}

    /// Request notification permission once (best-effort). Safe to call repeatedly.
    func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Schedule a phase-complete notification to fire after `seconds`. Called when a phase
    /// **starts** so it fires even if the phone is locked or the app is backgrounded for the
    /// full block. Cancel via `clear()` when the user pauses or resets. No-op if `seconds <= 0`.
    func schedulePhaseComplete(phase: PomodoroPhase, after seconds: TimeInterval) {
        #if canImport(UserNotifications)
        guard seconds > 0 else { return }
        let (title, body) = Self.phaseCompleteContent(phase: phase)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: Self.phaseCompleteID,
                                            content: content, trigger: trigger)
        // Replace any prior pending alert first so a re-started phase doesn't stack.
        clear()
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Cancel any pending or delivered phase-complete notification (e.g. on pause / reset).
    func clear() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.phaseCompleteID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.phaseCompleteID])
        #endif
    }

    /// Pure, testable notification copy. Platform-free (plain strings) so wording is unit-tested
    /// without `UserNotifications` or a device.
    nonisolated static func phaseCompleteContent(phase: PomodoroPhase) -> (title: String, body: String) {
        switch phase {
        case .focus:
            return ("Focus session complete", "Time for a well-deserved break.")
        case .breakTime:
            return ("Break's over", "Ready to focus again?")
        }
    }
}
