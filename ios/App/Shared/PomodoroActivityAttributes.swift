#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity contract for the **Pomodoro focus timer**, shared by the **app**
/// (`PomodoroLiveActivityController` starts/updates/ends it) and the **widget extension**
/// (`SnappetWidgets`, which renders the Lock Screen + Dynamic Island). Compiled into *both*
/// targets via `project.yml` so the attribute/state shape can't drift between producer and
/// renderer — the same one-source-of-truth pattern as `WorkoutActivityAttributes` /
/// `KilterActivityAttributes` (decisions.md 2026-06-10).
///
/// A separate type from the workout/Kilter contracts: a focus-timer's live state is a
/// phase label + countdown, not exercise/set-progress or climb/grade.
struct PomodoroActivityAttributes: ActivityAttributes {

    /// Per-update dynamic state. Small on purpose — ActivityKit budgets updates.
    struct ContentState: Codable, Hashable, Sendable {
        /// Wall-clock end of the current phase. The Live Activity renders the countdown with
        /// `Text(timerInterval: Date.now...endDate, countsDown: true)`, so the OS ticks it on
        /// the wall clock with zero background CPU — stays correct across backgrounding.
        var endDate: Date
        /// "Focus" or "Break" — shown on the Lock Screen and in the Dynamic Island.
        var phaseLabel: String
        /// True when in a focus phase; drives tint color (tomato vs leaf-green) in the widget.
        var isFocus: Bool
        /// Total seconds in this phase — used to render a progress arc in the Lock Screen view.
        var phaseDurationSeconds: Int
        /// Whether the timer is paused. Freezes the countdown; shows `remainingSeconds` instead.
        var paused: Bool = false
        /// Remaining seconds captured at pause time — shown as static text when `paused`.
        var remainingSeconds: Int = 0
    }
}
#endif
