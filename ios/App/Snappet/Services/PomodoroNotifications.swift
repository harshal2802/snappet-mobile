import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notifications for the Pomodoro timer, so a phase ending while the app is
/// backgrounded / the phone is locked still reaches the user — the whole point of a
/// 25-minute focus block is not looking at the screen. Scheduled when a phase **starts**
/// (the in-view RunLoop ticker is suspended in the background, a scheduled local
/// notification is not — the `WorkoutNotifications` pattern), and cancelled on
/// pause/reset so a stale "phase over" alert never fires.
///
/// **Layering:** the only Pomodoro code touching `UserNotifications`. Every entry point
/// is a no-op where notifications are unauthorized or the framework is unavailable; the
/// notification *copy* is built by the pure, testable `phaseEndContent`.
@MainActor
final class PomodoroNotifications {

    /// Stable identifier so a re-scheduled phase alert replaces the previous one.
    private static let phaseEndID = "snappet.pomodoro.phaseEnd"

    init() {}

    /// Ask for notification permission once (best-effort). Safe to call repeatedly; a
    /// denied user is respected by the system.
    func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Schedule the end-of-phase alert for the phase that just started running.
    /// `endDate` is the timer's absolute wall-clock end. No-op if it's not in the future.
    func schedulePhaseEnd(for phase: PomodoroPhase, at endDate: Date) {
        #if canImport(UserNotifications)
        let seconds = endDate.timeIntervalSinceNow
        guard seconds > 0 else { return }
        let (title, body) = Self.phaseEndContent(endedPhase: phase)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: Self.phaseEndID, content: content, trigger: trigger)
        // Replace any prior pending alert first so phase auto-advance doesn't stack.
        clear()
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Cancel any pending/delivered phase-end alert (pause, reset).
    func clear() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.phaseEndID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.phaseEndID])
        #endif
    }

    /// Pure, testable notification copy for the moment `endedPhase` finishes.
    nonisolated static func phaseEndContent(endedPhase: PomodoroPhase) -> (title: String, body: String) {
        switch endedPhase {
        case .focus:
            return ("Focus complete", "Nice work — time for a break.")
        case .breakTime:
            return ("Break's over", "Back to focus.")
        }
    }
}
