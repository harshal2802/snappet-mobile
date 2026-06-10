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

    /// Stable identifiers — one per scheduled boundary — so re-scheduling replaces
    /// rather than stacks. Two boundaries are kept scheduled (the running phase's end
    /// **and** the following phase's end) because the app can't schedule anything while
    /// suspended: locking the phone through a whole focus block still gets the user the
    /// "break's over" alert that follows it.
    private static let boundaryIDs = ["snappet.pomodoro.phaseEnd", "snappet.pomodoro.phaseEnd.next"]

    init() {}

    /// Ask for notification permission once (best-effort). Safe to call repeatedly; a
    /// denied user is respected by the system. Called from the Pomodoro screen's appear
    /// so the dialog shows in context, before the first Start.
    func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Schedule alerts for the upcoming phase boundaries (absolute wall-clock ends,
    /// soonest first; anything past or beyond `boundaryIDs.count` is dropped). The adds
    /// are issued **from the authorization completion** — `requestAuthorization` is an
    /// immediate pass-through once status is determined, and routing through it means a
    /// first-ever schedule isn't silently dropped while the permission dialog is still
    /// up (`add()` fails while status is .notDetermined; #70 review blocker).
    func scheduleBoundaries(_ boundaries: [(phase: PomodoroPhase, endDate: Date)]) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.boundaryIDs)
        center.removeDeliveredNotifications(withIdentifiers: Self.boundaryIDs)
        let plan = boundaries.prefix(Self.boundaryIDs.count).map { ($0.phase, $0.endDate) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            // Re-resolve the center inside the @Sendable completion (UNUserNotificationCenter
            // isn't statically Sendable under Swift 6 even though it's thread-safe).
            let center = UNUserNotificationCenter.current()
            for (index, boundary) in plan.enumerated() {
                // Recompute the interval after the (possibly slow) grant so the trigger
                // still lands on the absolute end date.
                let seconds = boundary.1.timeIntervalSinceNow
                guard seconds > 0 else { continue }
                let (title, body) = Self.phaseEndContent(endedPhase: boundary.0)
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
                center.add(UNNotificationRequest(identifier: Self.boundaryIDs[index],
                                                 content: content, trigger: trigger))
            }
        }
        #endif
    }

    /// Cancel all pending/delivered phase-end alerts (pause, reset, orphan cleanup).
    func clear() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.boundaryIDs)
        center.removeDeliveredNotifications(withIdentifiers: Self.boundaryIDs)
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
