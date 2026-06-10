import Foundation
import Observation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the Pomodoro **Live Activity** (Lock Screen + Dynamic Island): starts it when a session
/// begins (or a phase advances), pushes `ContentState` updates as the phase changes or the timer
/// is paused, and ends it when the timer is reset. The activity renders the **phase countdown**
/// off `ContentState.phaseEndDate` (the OS ticks it on the wall clock — no background CPU), plus
/// the phase label so the session is visible without the app foregrounded.
///
/// **Layering:** this is the only place ActivityKit is touched for Pomodoro in the app target;
/// the widget extension (`SnappetWidgets`) only *renders* the shared `PomodoroActivityAttributes`.
/// The `HighlightEngine` is untouched (no platform import).
///
/// **Availability / authorization:** every entry point is a **no-op** where ActivityKit is
/// unavailable or where the user hasn't enabled Live Activities. Starting twice ends the prior
/// activity first so we never strand an orphan.
///
/// **Verification honesty:** the actual Lock Screen / Dynamic Island *rendering* needs a device
/// (or careful sim support). A clean build proves the shape, not the on-device activity.
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

    var isRunning: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) { return typedActivity != nil }
        return false
        #else
        return false
        #endif
    }

    var isAvailable: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
        #else
        return false
        #endif
    }

    /// Begin a new Live Activity, or update the existing one when a phase advances.
    /// Pass `focusMinutes` for the fixed attribute (only used when starting a fresh activity).
    /// No-op if unavailable / unauthorized.
    func startOrUpdate(phase: PomodoroPhase, phaseEndDate: Date, focusMinutes: Int) {
        if isRunning {
            update(phase: phase, phaseEndDate: phaseEndDate)
        } else {
            start(phase: phase, phaseEndDate: phaseEndDate, focusMinutes: focusMinutes)
        }
    }

    /// Start a Live Activity for a Pomodoro session. No-op if unavailable / unauthorized.
    /// If one is already running it is ended first so a re-start doesn't leave an orphan.
    private func start(phase: PomodoroPhase, phaseEndDate: Date, focusMinutes: Int) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if typedActivity != nil { end() }
        let attributes = PomodoroActivityAttributes(focusMinutes: focusMinutes)
        let state = PomodoroActivityAttributes.ContentState(
            phaseEndDate: phaseEndDate,
            phaseLabel: phase.title)
        do {
            typedActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil))
        } catch {
            // Request can throw if the activity budget is exhausted or the entitlement is
            // missing — degrade silently; the in-app timer still works.
            typedActivity = nil
        }
        #endif
    }

    /// Push a new content state. No-op if no activity is running.
    func update(phase: PomodoroPhase, phaseEndDate: Date, paused: Bool = false) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        let state = PomodoroActivityAttributes.ContentState(
            phaseEndDate: phaseEndDate,
            phaseLabel: phase.title,
            paused: paused)
        let content = ActivityContent(state: state, staleDate: nil)
        nonisolated(unsafe) let act = activity
        Task { await act.update(content) }
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
