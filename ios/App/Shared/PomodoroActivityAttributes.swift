#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity contract for a **Pomodoro focus session**, shared by the **app**
/// (`PomodoroLiveActivityController` starts/updates/ends it) and the **widget extension**
/// (`SnappetWidgets`, which renders the Lock Screen + Dynamic Island). Compiled into both
/// targets via `project.yml` — the same one-source-of-truth pattern as `WorkoutActivityAttributes`
/// and `KilterActivityAttributes`.
///
/// A separate type from the other activity attributes because Pomodoro's live state is
/// phase label + countdown to the next phase end (no HR, no exercise, no routine name).
struct PomodoroActivityAttributes: ActivityAttributes {

    /// Per-update dynamic state. Small on purpose — ActivityKit budgets updates.
    struct ContentState: Codable, Hashable, Sendable {
        /// Wall-clock end of the current phase. The Live Activity renders a **countdown** via
        /// `Text(timerInterval: now...phaseEndDate, countsDown: true)`, so the OS ticks it on
        /// the wall clock with zero background CPU — correct across backgrounding by construction.
        var phaseEndDate: Date
        /// Display label for the current phase: "Focus" or "Break".
        var phaseLabel: String
        /// Whether the timer is paused — freezes the countdown display and shows a "Paused" badge.
        var paused: Bool = false
    }

    // No static attributes: Pomodoro sessions have no session-static metadata
    // (unlike routine name in WorkoutActivityAttributes or board name in KilterActivityAttributes).
    // The phase label changes with each phase transition and is carried in ContentState.
}
#endif
