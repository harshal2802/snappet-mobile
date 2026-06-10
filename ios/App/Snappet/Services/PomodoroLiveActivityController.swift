import Foundation
import Observation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the **Pomodoro focus session Live Activity** (Lock Screen + Dynamic Island): starts it
/// when the timer begins, pushes `ContentState` updates as the phase transitions or the timer
/// pauses, and ends it when the timer stops. The activity renders a **phase label + countdown
/// to phase end** off `ContentState.phaseEndDate` (the OS ticks it on the wall clock — no
/// background CPU), making the running session visible without the app foregrounded.
///
/// A dedicated controller (not generalizing `LiveActivityController`) keeps the Pomodoro
/// path separate from WorkoutTracker and Kilter (decisions.md 2026-06-10). Every entry point
/// is a **no-op** where ActivityKit is unavailable or the user hasn't enabled Live Activities.
///
/// **Verification honesty:** Lock Screen / Dynamic Island *rendering* needs a device; a clean
/// build proves the contract shape, not the on-device output.
@MainActor
@Observable
final class PomodoroLiveActivityController {

    #if canImport(ActivityKit)
    /// The currently-running activity, if any. `Activity` is iOS 16.1+, hence the `Any` box.
    private var activity: Any?

    @available(iOS 16.1, *)
    private var typedActivity: Activity<PomodoroActivityAttributes>? {
        get { activity as? Activity<PomodoroActivityAttributes> }
        set { activity = newValue }
    }
    #endif

    init() {}

    var isRunning: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) { return typedActivity != nil }
        return false
        #else
        return false
        #endif
    }

    /// Start or update the Live Activity with the given phase label and phase-end date.
    /// If one is already running it is updated in place (supports phase transitions without
    /// ending and restarting the activity). If none is running, a new activity is started.
    /// No-op if ActivityKit is unavailable or the user hasn't enabled Live Activities.
    func push(phaseLabel: String, phaseEndDate: Date, paused: Bool = false) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = PomodoroActivityAttributes.ContentState(
            phaseEndDate: phaseEndDate, phaseLabel: phaseLabel, paused: paused)
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = typedActivity {
            // Phase transition or pause — update the running activity.
            nonisolated(unsafe) let act = activity
            Task { await act.update(content) }
        } else {
            // No active activity — start a fresh one.
            do {
                typedActivity = try Activity.request(
                    attributes: PomodoroActivityAttributes(),
                    content: content)
            } catch {
                // Request can throw if the activity budget is exhausted or the entitlement is
                // missing — degrade silently; the in-app timer ring still works.
                typedActivity = nil
            }
        }
        #endif
    }

    /// End the Live Activity immediately. Safe to call when none is running.
    func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        self.typedActivity = nil
        nonisolated(unsafe) let act = activity
        Task { await act.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
