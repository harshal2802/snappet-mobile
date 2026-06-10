import Foundation
import Observation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the **Pomodoro focus-session Live Activity** (Lock Screen + Dynamic Island): starts it
/// when a phase begins, pushes `ContentState` updates on phase transitions and pause/resume,
/// and ends it on reset. The activity renders a **countdown timer** off `ContentState.endDate`
/// (the OS ticks it on the wall clock — no background CPU), plus the current phase label so the
/// session is visible without the app foregrounded.
///
/// **Layering:** this is the only place ActivityKit is touched for the Pomodoro feature; the
/// widget extension only *renders* the shared `PomodoroActivityAttributes`. No HR stream means
/// no throttle is needed — every state transition is pushed immediately.
///
/// **Availability / authorization:** every entry point is a **no-op** where ActivityKit is
/// unavailable or where the user hasn't enabled Live Activities.
///
/// **Verification honesty:** Lock Screen / Dynamic Island *rendering* needs a device or careful
/// sim support. A clean build proves the shape, not the on-device activity.
@MainActor
@Observable
final class PomodoroLiveActivityController {

    #if canImport(ActivityKit)
    private var activity: Any?

    @available(iOS 16.1, *)
    private var typedActivity: Activity<PomodoroActivityAttributes>? {
        get { activity as? Activity<PomodoroActivityAttributes> }
        set { activity = newValue }
    }
    #endif

    init() {}

    /// Whether a Live Activity is currently running.
    var isRunning: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) { return typedActivity != nil }
        return false
        #else
        return false
        #endif
    }

    /// Start (or restart) the Live Activity for a Pomodoro phase. If one is already running it
    /// is updated in place rather than ended and recreated, so the Lock Screen display doesn't
    /// flash. No-op if ActivityKit is unavailable or the user hasn't enabled Live Activities.
    func start(phase: String, endDate: Date) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = PomodoroActivityAttributes.ContentState(endDate: endDate, phase: phase, paused: false)
        if let activity = typedActivity {
            // Phase auto-advanced — update the running activity's endDate and phase label.
            let content = ActivityContent(state: state, staleDate: nil)
            nonisolated(unsafe) let act = activity
            Task { await act.update(content) }
            return
        }
        do {
            typedActivity = try Activity.request(
                attributes: PomodoroActivityAttributes(),
                content: .init(state: state, staleDate: nil))
        } catch {
            // Request can throw if the activity budget is exhausted or the entitlement is
            // missing — degrade silently; the in-app ring timer still works.
            typedActivity = nil
        }
        #endif
    }

    /// Update the running activity to reflect a paused state. No-op if none is running.
    func pause(endDate: Date, phase: String) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        let state = PomodoroActivityAttributes.ContentState(endDate: endDate, phase: phase, paused: true)
        let content = ActivityContent(state: state, staleDate: nil)
        nonisolated(unsafe) let act = activity
        Task { await act.update(content) }
        #endif
    }

    /// End the Live Activity immediately (on reset). Safe to call when none is running.
    func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        self.typedActivity = nil
        nonisolated(unsafe) let act = activity
        Task { await act.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
