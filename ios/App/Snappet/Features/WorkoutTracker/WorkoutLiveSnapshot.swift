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
}
