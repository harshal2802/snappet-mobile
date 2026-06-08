import Foundation
import Observation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the **Kilter climbing-session Live Activity** (Lock Screen + Dynamic Island): starts it
/// when a session begins, pushes `ContentState` updates as HR / current climb / climb count change,
/// and ends it when the session ends. The activity renders the **overall timer** off
/// `ContentState.startedAt` (the OS ticks it on the wall clock — no background CPU), plus live HR and
/// the current climb so the session is visible without the app foregrounded.
///
/// A dedicated controller (rather than generalizing `LiveActivityController`) keeps the workout path
/// untouched — this owns an `Activity<KilterActivityAttributes>`, that one owns the workout type
/// (decisions.md 2026-06-06). Every entry point is a **no-op** where ActivityKit is unavailable or
/// the user hasn't enabled Live Activities; starting twice ends the prior activity first.
///
/// **Verification honesty:** the actual Lock Screen / Dynamic Island *rendering* needs a device. A
/// clean build proves the shape, not the on-device activity.
@MainActor
@Observable
final class KilterLiveActivityController {

    #if canImport(ActivityKit)
    /// The currently-running activity, if any. `Activity` is iOS 16.1+, hence the `Any` box + guard.
    private var activity: Any?

    @available(iOS 16.1, *)
    private var typedActivity: Activity<KilterActivityAttributes>? {
        get { activity as? Activity<KilterActivityAttributes> }
        set { activity = newValue }
    }
    #endif

    /// Last snapshot pushed + when — drives the `shouldPush` throttle so a ~1 Hz HR stream doesn't
    /// exceed ActivityKit's update budget.
    private var lastSnapshot: KilterLiveSnapshot?
    private var lastPushedAt: Date?

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

    /// Re-attach to a Live Activity that's still on the Lock Screen but whose in-memory handle we lost
    /// (e.g. after a relaunch, or the session manager being recreated). Rehydrates the throttle baseline
    /// from the running state so the first post-recovery `update(_:)` isn't dropped. Returns whether an
    /// activity is now held — so recovery can decide between re-attaching and (re)starting one.
    @discardableResult
    func adoptRunningActivity() -> Bool {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return false }
        if typedActivity != nil { return true }
        guard let running = Activity<KilterActivityAttributes>.activities.first else { return false }
        typedActivity = running
        let s = running.content.state
        lastSnapshot = KilterLiveSnapshot(startedAt: s.startedAt, hrBpm: s.hrBpm,
                                          currentClimbName: s.currentClimbName,
                                          currentGrade: s.currentGrade, climbCount: s.climbCount)
        lastPushedAt = .now
        return true
        #else
        return false
        #endif
    }

    /// Begin a Live Activity for a climbing session. No-op if unavailable/unauthorized. If one is
    /// already running it is ended first so a re-start doesn't leave an orphan.
    func start(boardName: String, startedAt: Date, angle: Int,
               currentClimbName: String = "Resting", currentGrade: String = "", climbCount: Int = 0,
               maxHR: Double? = nil) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if typedActivity != nil { end() }
        let attributes = KilterActivityAttributes(boardName: boardName, maxHR: maxHR)
        let state = KilterActivityAttributes.ContentState(
            startedAt: startedAt, hrBpm: nil,
            currentClimbName: currentClimbName, currentGrade: currentGrade,
            climbCount: climbCount, angle: angle)
        do {
            typedActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil))
            lastSnapshot = KilterLiveSnapshot(startedAt: startedAt, hrBpm: nil,
                                              currentClimbName: currentClimbName,
                                              currentGrade: currentGrade, climbCount: climbCount)
            lastPushedAt = .now
        } catch {
            // Request can throw if the activity budget is exhausted or the entitlement is missing —
            // degrade silently; the in-app HUD timer still works.
            typedActivity = nil
            lastSnapshot = nil
            lastPushedAt = nil
        }
        #endif
    }

    /// Push a new content state from the pure `KilterLiveSnapshot`. No-op if no activity is running.
    /// `startedAt` and `angle` are preserved from the running activity so the overall timer keeps
    /// ticking from the original start.
    func update(_ snapshot: KilterLiveSnapshot, now: Date = .now) {
        guard KilterLiveSnapshot.shouldPush(snapshot, after: lastSnapshot,
                                            lastPushedAt: lastPushedAt, now: now) else { return }
        lastSnapshot = snapshot
        lastPushedAt = now
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = typedActivity else { return }
        let startedAt = activity.content.state.startedAt
        let angle = activity.content.state.angle
        let state = KilterActivityAttributes.ContentState(
            startedAt: startedAt, hrBpm: snapshot.hrBpm,
            currentClimbName: snapshot.currentClimbName, currentGrade: snapshot.currentGrade,
            climbCount: snapshot.climbCount, angle: angle, paused: snapshot.paused,
            recoveryReady: snapshot.recoveryReady)
        let content = ActivityContent(state: state, staleDate: nil)
        // `Activity` is documented thread-safe + `Sendable`; strip the main-actor tag so the detached
        // async `update` doesn't trip Swift 6 region isolation (mirrors `LiveActivityController`).
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
