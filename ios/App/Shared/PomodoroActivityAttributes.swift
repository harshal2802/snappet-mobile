#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity contract for a **Pomodoro focus session**, shared by the **app**
/// (`PomodoroLiveActivityController` starts/updates/ends it) and the **widget extension**
/// (`SnappetWidgets`, which renders the Lock Screen + Dynamic Island). Compiled into *both*
/// targets via `project.yml` so the shape can't drift between producer and renderer — the
/// same one-source-of-truth pattern as `WorkoutActivityAttributes` / `KilterActivityAttributes`.
///
/// A separate type from `WorkoutActivityAttributes` on purpose: a focus session's live state
/// is phase label + countdown deadline, not exercise + set-progress.
struct PomodoroActivityAttributes: ActivityAttributes {

    /// Per-update dynamic state. Small on purpose — ActivityKit budgets updates, so we only
    /// carry what the Lock Screen / Dynamic Island actually render.
    struct ContentState: Codable, Hashable, Sendable {
        /// Wall-clock deadline for the current phase. The Live Activity renders the countdown
        /// with `Text(timerInterval: now...phaseEndDate, countsDown: true)`, so the OS ticks
        /// it on the wall clock with **zero background CPU** — correct across backgrounding.
        var phaseEndDate: Date
        /// "Focus" or "Break" — the phase currently running.
        var phaseLabel: String
        /// Whether the timer is paused — freeze the countdown + show a "Paused" badge.
        /// Defaulted so callers that don't care about pause don't churn; producer + renderer
        /// are the same app version so the shape can't drift mid-session.
        var paused: Bool = false
    }

    /// The configured focus-block length in minutes — shown as context in the Dynamic Island
    /// expanded region. Fixed for the activity's lifetime.
    var focusMinutes: Int
}
#endif
