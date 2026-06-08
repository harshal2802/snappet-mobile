import Foundation
import Observation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the WorkoutTracker **Live Activity** (Lock Screen + Dynamic Island): starts it when
/// a session begins/resumes, pushes `ContentState` updates as HR / exercise / set progress
/// change, and ends it when the session finishes. The activity renders the **overall timer**
/// off `ContentState.startedAt` (the OS ticks it on the wall clock — no background CPU), plus
/// the live HR and current exercise so the workout is visible without the app foregrounded.
///
/// **Layering:** this is the only place ActivityKit is touched in the app target; the widget
/// extension (`SnappetWidgets`) only *renders* the shared `WorkoutActivityAttributes`. The
/// `HighlightEngine` is untouched (no platform import). Lifecycle is co-located with the
/// existing session lifecycle in `WorkoutHomeView`, alongside `LiveWorkoutService.start/stop`.
///
/// **Availability / authorization:** every entry point is a **no-op** where ActivityKit is
/// unavailable (older OS, or the framework can't be imported) or where the user hasn't enabled
/// Live Activities (`areActivitiesEnabled == false`). Starting twice ends the prior activity
/// first so we never strand an orphan.
///
/// **Verification honesty:** the actual Lock Screen / Dynamic Island *rendering* needs a device
/// (or careful sim support). A clean build proves the shape, not the on-device activity.
@MainActor
@Observable
final class LiveActivityController {

    #if canImport(ActivityKit)
    /// The currently-running activity, if any. `Activity` is iOS 16.1+, hence the guard.
    private var activity: Any?

    @available(iOS 16.1, *)
    private var typedActivity: Activity<WorkoutActivityAttributes>? {
        get { activity as? Activity<WorkoutActivityAttributes> }
        set { activity = newValue }
    }
    #endif

    /// Last snapshot pushed + when — drives the `shouldPush` throttle so a ~1 Hz HR stream
    /// doesn't exceed ActivityKit's update budget.
    private var lastSnapshot: WorkoutLiveSnapshot?
    private var lastPushedAt: Date?

    init() {}

    /// Whether a Live Activity is currently running (so callers can avoid restarting it —
    /// e.g. a warm resume shouldn't end+recreate the activity that's already showing).
    var isRunning: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) { return typedActivity != nil }
        return false
        #else
        return false
        #endif
    }

    /// Whether the platform can run a workout Live Activity *and* the user has them enabled.
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

    /// Begin a Live Activity for a workout. No-op if unavailable/unauthorized. If one is
    /// already running it is ended first so a re-start (resume) doesn't leave an orphan.
    func start(routineName: String, startedAt: Date,
               exerciseName: String = "Starting…", setProgress: String = "", maxHR: Double? = nil) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if typedActivity != nil { end() }
        let attributes = WorkoutActivityAttributes(routineName: routineName, maxHR: maxHR)
        let state = WorkoutActivityAttributes.ContentState(
            startedAt: startedAt, hrBpm: nil,
            exerciseName: exerciseName, setProgress: setProgress)
        do {
            typedActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil))
            // Seed the throttle with what we just pushed via `request`.
            lastSnapshot = WorkoutLiveSnapshot(startedAt: startedAt, hrBpm: nil,
                                               exerciseName: exerciseName, setProgress: setProgress)
            lastPushedAt = .now
        } catch {
            // Request can throw if the activity budget is exhausted or the entitlement is
            // missing — degrade silently; the in-app overall timer still works.
            typedActivity = nil
            lastSnapshot = nil
            lastPushedAt = nil
        }
        #endif
    }

    /// Push a new content state from the pure `WorkoutLiveSnapshot` (the same source of truth
    /// the in-player overall timer reads). No-op if no activity is running. `startedAt` is
    /// preserved from the running activity so the overall timer keeps ticking from the original
    /// start, regardless of the snapshot's own `startedAt`.
    func update(_ snapshot: WorkoutLiveSnapshot, now: Date = .now) {
        // Throttle: structural changes push immediately; HR-only changes are rate-limited so a
        // ~1 Hz HR stream can't exhaust ActivityKit's update budget (and lag the Lock Screen).
        guard WorkoutLiveSnapshot.shouldPush(snapshot, after: lastSnapshot,
                                             lastPushedAt: lastPushedAt, now: now) else { return }
        lastSnapshot = snapshot
        lastPushedAt = now
        update(hrBpm: snapshot.hrBpm, exerciseName: snapshot.exerciseName,
               setProgress: snapshot.setProgress, paused: snapshot.paused)
    }

    /// Push a new content state. No-op if no activity is running. `startedAt` is preserved
    /// from the running activity so the overall timer keeps ticking from the original start.
    func update(hrBpm: Int?, exerciseName: String, setProgress: String, paused: Bool = false) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        let startedAt = activity.content.state.startedAt
        let state = WorkoutActivityAttributes.ContentState(
            startedAt: startedAt, hrBpm: hrBpm,
            exerciseName: exerciseName, setProgress: setProgress, paused: paused)
        let content = ActivityContent(state: state, staleDate: nil)
        // `Activity` is documented thread-safe and `Sendable`; `nonisolated(unsafe)` strips the
        // main-actor tag the local picks up from the `@MainActor` getter so the detached async
        // `update` doesn't trip Swift 6 region isolation (the receiver is safe to call off-actor).
        nonisolated(unsafe) let act = activity
        Task { await act.update(content) }
        #endif
    }

    /// End the Live Activity immediately. Safe to call when none is running.
    func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        self.typedActivity = nil
        lastSnapshot = nil
        lastPushedAt = nil
        nonisolated(unsafe) let act = activity
        Task { await act.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
