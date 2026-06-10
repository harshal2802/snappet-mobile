import Foundation
import Observation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the **Pomodoro focus-timer Live Activity** (Lock Screen + Dynamic Island): starts it when a
/// phase begins/resumes, pushes `ContentState` updates as phase or pause state changes, and ends it
/// when the timer is reset. The activity renders the **phase countdown** off `ContentState.endDate`
/// (the OS ticks it with zero background CPU), plus the phase label so the focus state is visible
/// without the app foregrounded.
///
/// A dedicated controller (rather than generalising the workout controller) keeps the workout path
/// untouched — this owns an `Activity<PomodoroActivityAttributes>`. No HR throttling needed: Pomodoro
/// state changes are infrequent (once per phase). Every entry point is a **no-op** where ActivityKit
/// is unavailable or the user hasn't enabled Live Activities.
///
/// **Verification honesty:** the actual Lock Screen / Dynamic Island *rendering* needs a device.
/// A clean build proves the shape, not the on-device activity.
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

    /// Begin (or restart) a Live Activity for a Pomodoro phase. No-op if unavailable/unauthorized.
    /// Ends any prior activity first so a re-start (e.g. new phase) doesn't orphan the old one.
    func start(phase: PomodoroPhase, endDate: Date, phaseDurationSeconds: Int) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if typedActivity != nil { end() }
        let attributes = PomodoroActivityAttributes()
        let state = PomodoroActivityAttributes.ContentState(
            endDate: endDate,
            phaseLabel: phase.title,
            isFocus: phase == .focus,
            phaseDurationSeconds: phaseDurationSeconds)
        do {
            typedActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil))
        } catch {
            typedActivity = nil
        }
        #endif
    }

    /// Push an updated content state (phase switch, pause/resume). No-op if no activity is running.
    func update(phase: PomodoroPhase, endDate: Date, phaseDurationSeconds: Int,
                paused: Bool = false, remainingSeconds: Int = 0) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        let state = PomodoroActivityAttributes.ContentState(
            endDate: endDate,
            phaseLabel: phase.title,
            isFocus: phase == .focus,
            phaseDurationSeconds: phaseDurationSeconds,
            paused: paused,
            remainingSeconds: remainingSeconds)
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
