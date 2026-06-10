import Foundation
import Observation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the **Pomodoro Live Activity** (Lock Screen + Dynamic Island countdown): started
/// when a phase starts, updated on focus↔break auto-advance, ended on pause/reset. The
/// widget renders the countdown off `ContentState.endDate` via `Text(timerInterval:)`,
/// so the OS ticks it on the wall clock — no background CPU, correct across backgrounding
/// by construction.
///
/// A dedicated controller (third alongside the workout + Kilter ones) keeps the three
/// activity types separate (decisions.md 2026-06-06). No HR-style update throttle: state
/// changes only on phase edges, minutes apart. Every entry point is a **no-op** where
/// ActivityKit is unavailable or Live Activities are off.
///
/// **Verification honesty:** the actual Lock Screen / Dynamic Island *rendering* needs a
/// device. A clean build proves the shape, not the on-device activity.
@MainActor
@Observable
final class PomodoroLiveActivityController {

    #if canImport(ActivityKit)
    /// The currently-running activity, if any. `Activity` is iOS 16.1+, hence the box.
    private var activity: Any?

    @available(iOS 16.1, *)
    private var typedActivity: Activity<PomodoroActivityAttributes>? {
        get { activity as? Activity<PomodoroActivityAttributes> }
        set { activity = newValue }
    }
    #endif

    init() {}

    /// Re-attach to a Live Activity that's still on the Lock Screen but whose in-memory
    /// handle was lost (relaunch after termination mid-session — the Kilter
    /// `adoptRunningActivity` pattern). Returns the orphan's state so the caller can
    /// restore the timer (end still ahead) or clean up (end past).
    func adoptRunning() -> (isFocus: Bool, endDate: Date)? {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return nil }
        if typedActivity == nil {
            guard let running = Activity<PomodoroActivityAttributes>.activities.first else { return nil }
            typedActivity = running
        }
        guard let state = typedActivity?.content.state else { return nil }
        return (state.isFocus, state.endDate)
        #else
        return nil
        #endif
    }

    /// Reflect a (re)started or auto-advanced phase: starts an activity if none is
    /// running, otherwise pushes the new phase/end. `phaseStartedAt` is derived from the
    /// phase length so progress animates over the whole phase.
    func sync(isFocus: Bool, endDate: Date, phaseSeconds: TimeInterval) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = PomodoroActivityAttributes.ContentState(
            isFocus: isFocus,
            phaseStartedAt: endDate.addingTimeInterval(-phaseSeconds),
            endDate: endDate)
        let content = ActivityContent(state: state, staleDate: endDate)
        if let activity = typedActivity {
            // `Activity` is documented thread-safe + `Sendable`; strip the main-actor tag
            // so the detached async `update` doesn't trip Swift 6 region isolation
            // (mirrors LiveActivityController).
            nonisolated(unsafe) let act = activity
            Task { await act.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            typedActivity = try Activity.request(
                attributes: PomodoroActivityAttributes(), content: content)
        } catch {
            // Budget exhausted / entitlement missing — degrade silently; the in-app
            // ring and the scheduled notification still work.
            typedActivity = nil
        }
        #endif
    }

    /// End the Live Activity immediately (pause/reset). Safe when none is running.
    func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        self.typedActivity = nil
        nonisolated(unsafe) let act = activity
        Task { await act.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
