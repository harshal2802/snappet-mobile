import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications for the Pomodoro timer, so a backgrounded / minimized session can still
/// reach the user's **notification bar**. Fires one alert per phase: *phase complete* — when
/// the focus or break countdown reaches zero while the phone is locked or the app is not in the
/// foreground (a foreground `Timer` tick is suspended in the background, but a scheduled local
/// notification is not).
///
/// **Layering:** the only place `UserNotifications` is touched for Pomodoro. Every entry point
/// is a **no-op** where notifications are unauthorized or the framework is unavailable, so the
/// timer flow never depends on it. The notification *copy* is built by the pure, testable
/// `phaseCompleteContent(phase:)`.
@MainActor
final class PomodoroNotifications {

    /// Stable identifier so a re-fired phase alert replaces the previous one rather than stacking.
    private static let phaseCompleteID = "snappet.pomodoro.phaseComplete"

    init() {}

    /// Ask for notification permission once (best-effort). Safe to call repeatedly; a denied
    /// user is respected by the system. No-op where `UserNotifications` is unavailable.
    func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Schedule a phase-complete notification to fire at `phaseEndDate`. Called when a phase's
    /// countdown **starts** (not when it finishes) so it still reaches the user if the phone is
    /// locked or the app is backgrounded — the in-app ticker is suspended in the background, but a
    /// scheduled local notification is not. Cancel it via `clear()` on pause or reset; the next
    /// `schedulePhaseComplete` replaces the prior request so auto-advance doesn't stack.
    /// No-op if unauthorized / `phaseEndDate` is in the past.
    func schedulePhaseComplete(for phase: PomodoroPhase, at phaseEndDate: Date) {
        #if canImport(UserNotifications)
        let seconds = phaseEndDate.timeIntervalSinceNow
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
        // Replace any prior pending alert so auto-advance doesn't stack notifications.
        clear()
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Clear any pending / delivered phase-complete notification (e.g. on pause or reset).
    func clear() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.phaseCompleteID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.phaseCompleteID])
        #endif
    }

    /// Pure, testable notification copy. Kept platform-free (plain strings) so the wording is
    /// unit-tested without `UserNotifications` or a device.
    nonisolated static func phaseCompleteContent(phase: PomodoroPhase) -> (title: String, body: String) {
        switch phase {
        case .focus:
            return ("Focus block complete", "Time for a break — great work!")
        case .breakTime:
            return ("Break's over", "Ready for your next focus block?")
        }
    }
}
