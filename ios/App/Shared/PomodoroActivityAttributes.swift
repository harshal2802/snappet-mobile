#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity contract for a **Pomodoro focus session**, shared by the **app**
/// (`PomodoroLiveActivityController` starts/updates/ends it) and the **widget extension**
/// (`SnappetWidgets`, which renders the Lock Screen + Dynamic Island). Compiled into *both*
/// targets via `project.yml` so the shape can't drift between producer and renderer — the
/// same one-source-of-truth pattern as `WorkoutActivityAttributes` / `KilterActivityAttributes`.
///
/// A separate type from the workout contracts: a Pomodoro session's live state is a
/// phase-end countdown + a "Focus / Break" label — no HR, no exercise, no climb count.
struct PomodoroActivityAttributes: ActivityAttributes {

    /// Per-update dynamic state. Small on purpose — ActivityKit budgets updates.
    struct ContentState: Codable, Hashable, Sendable {
        /// Wall-clock end of the current phase. The widget renders the **countdown** with
        /// `Text(timerInterval: Date.distantPast...endDate, countsDown: true)` so the OS
        /// ticks it live with zero background CPU and it stays correct across backgrounding.
        var endDate: Date
        /// "Focus" or "Break" — drives the Lock Screen / Dynamic Island label and icon.
        var phase: String
        /// True when the timer is paused; the Lock Screen shows a "Paused" badge and the
        /// countdown display is replaced with a static "Paused" label.
        var paused: Bool = false
    }

    // No session-level static attributes: a Pomodoro timer has no routine name, no max HR,
    // and no board name — the ContentState carries everything the widget needs to render.
}
#endif
