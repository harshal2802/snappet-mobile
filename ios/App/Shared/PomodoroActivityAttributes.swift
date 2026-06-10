#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity contract for a **Pomodoro phase**, shared by the app
/// (`PomodoroLiveActivityController`) and the widget extension (`SnappetWidgets`) —
/// the same one-source-of-truth pattern as `WorkoutActivityAttributes` /
/// `KilterActivityAttributes`, and a separate type for the same reason: a focus
/// countdown's state (phase + absolute end) has nothing in common with a workout's or a
/// climbing session's, so overloading either contract would muddy both.
struct PomodoroActivityAttributes: ActivityAttributes {

    /// Per-update dynamic state — only what the Lock Screen / Dynamic Island render.
    /// Updates happen on phase edges only (start, focus↔break advance), well inside
    /// ActivityKit's budget.
    struct ContentState: Codable, Hashable, Sendable {
        /// Whether the running phase is focus (tomato) or break (leaf-green).
        var isFocus: Bool
        /// When the running phase began — anchors `ProgressView(timerInterval:)` so the
        /// OS animates progress on the wall clock with zero background CPU.
        var phaseStartedAt: Date
        /// The phase's absolute wall-clock end — `Text(timerInterval:)` counts down to
        /// it the same way.
        var endDate: Date
    }
}
#endif
