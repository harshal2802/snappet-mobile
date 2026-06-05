import Foundation

/// The pure, platform-free description of what a live **Kilter climbing session** should currently
/// show in the in-app HUD and the Live Activity. Kept free of ActivityKit so it is unit-testable in
/// `SnappetTests` without a device: `KilterLiveActivityController` maps it onto the shared
/// `KilterActivityAttributes.ContentState`. Mirrors `WorkoutLiveSnapshot` (live-workout-studio A2).
struct KilterLiveSnapshot: Equatable, Sendable {
    /// Wall-clock session start (drives the self-updating `Text(timerInterval:)` overall timer).
    var startedAt: Date
    /// Latest heart rate (bpm), rounded; `nil` when no sample / no source.
    var hrBpm: Int?
    /// The climb currently being worked (or "Resting" between climbs).
    var currentClimbName: String
    /// The current climb's grade label, e.g. "6c/V5"; empty when resting / unknown.
    var currentGrade: String
    /// Climbs logged so far this session.
    var climbCount: Int
    /// Whether the session is paused. Defaulted so existing call sites are untouched.
    var paused: Bool = false

    /// Decide whether `next` warrants pushing to ActivityKit given the last pushed snapshot.
    /// **Structural** changes (current climb / grade / climb count / pause) always push immediately;
    /// an **HR-only** change is rate-limited to `minHRInterval` so a ~1 Hz HR stream can't exceed
    /// ActivityKit's update budget (which would make the Lock Screen lag). Identical snapshots never
    /// push. Pure + deterministic so the throttle is unit-tested without a device — same contract as
    /// `WorkoutLiveSnapshot.shouldPush`.
    static func shouldPush(_ next: KilterLiveSnapshot, after last: KilterLiveSnapshot?,
                           lastPushedAt: Date?, now: Date, minHRInterval: TimeInterval = 2) -> Bool {
        guard let last else { return true }   // first push always goes
        if next.currentClimbName != last.currentClimbName
            || next.currentGrade != last.currentGrade
            || next.climbCount != last.climbCount
            || next.paused != last.paused { return true }
        if next.hrBpm == last.hrBpm { return false }   // nothing changed at all
        guard let lastPushedAt else { return true }
        return now.timeIntervalSince(lastPushedAt) >= minHRInterval   // HR-only → rate-limit
    }
}
