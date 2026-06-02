import Foundation

/// The pure, platform-free description of what the live workout UI (in-player overall timer)
/// and the Live Activity should currently show. Kept free of ActivityKit so it is unit-testable
/// in `SnappetTests` without a device: the `LiveActivityController` maps this onto the shared
/// `WorkoutActivityAttributes.ContentState`, and the player renders the elapsed-time string
/// from the same source of truth (live-workout-studio A2).
struct WorkoutLiveSnapshot: Equatable, Sendable {
    /// Wall-clock session start (drives the self-updating `Text(timerInterval:)` overall timer).
    var startedAt: Date
    /// Latest heart rate (bpm), rounded; `nil` when no sample / no source.
    var hrBpm: Int?
    /// The current exercise name (or a phase label like "Resting" / "Workout complete").
    var exerciseName: String
    /// Short set/exercise progress, e.g. "Set 2 of 4" — empty when not applicable.
    var setProgress: String
    /// Whether the workout is paused (drives the "Paused" state across the player, the Live
    /// Activity, and the in-app banner). Defaulted so existing call sites are untouched.
    var paused: Bool = false

    /// Format an elapsed interval as the overall-timer string `H:MM:SS` (hours dropped under an
    /// hour → `M:SS`). Pure + deterministic so it is unit-testable; the in-player header prefers
    /// the self-updating `Text(timerInterval:)`, but this drives the accessibility value and tests.
    static func elapsedString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Decide whether `next` warrants pushing to ActivityKit given the last pushed snapshot.
    /// **Structural** changes (exercise / set-progress text) always push immediately; an
    /// **HR-only** change is rate-limited to `minHRInterval` so a ~1 Hz HR stream can't exceed
    /// ActivityKit's update budget (which would make the Lock Screen lag). Identical snapshots
    /// never push. Pure + deterministic so the throttle is unit-tested without a device.
    static func shouldPush(_ next: WorkoutLiveSnapshot, after last: WorkoutLiveSnapshot?,
                           lastPushedAt: Date?, now: Date, minHRInterval: TimeInterval = 2) -> Bool {
        guard let last else { return true }   // first push always goes
        // Structural changes (exercise / set-progress / pause state) push immediately.
        if next.exerciseName != last.exerciseName || next.setProgress != last.setProgress
            || next.paused != last.paused { return true }
        if next.hrBpm == last.hrBpm { return false }   // nothing changed at all
        guard let lastPushedAt else { return true }
        return now.timeIntervalSince(lastPushedAt) >= minHRInterval   // HR-only → rate-limit
    }
}
