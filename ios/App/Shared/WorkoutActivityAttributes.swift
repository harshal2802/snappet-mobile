#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity contract shared by the **app** (which starts/updates/ends the
/// activity via `LiveActivityController`) and the **widget extension** (`SnappetWidgets`,
/// which renders the Lock Screen + Dynamic Island). Compiled into *both* targets via
/// `project.yml` so the attribute/state shape can't drift between producer and renderer —
/// the same one-source-of-truth pattern as `LiveWorkoutMessage` (decisions.md 2026-06-01).
///
/// Static `attributes` are fixed for the life of the activity (the routine name).
/// The `ContentState` is everything that changes during the workout and is pushed with
/// each `update(...)`.
struct WorkoutActivityAttributes: ActivityAttributes {

    /// Per-update dynamic state. Small on purpose — ActivityKit budgets updates, so we
    /// only carry what the Lock Screen / Dynamic Island actually render.
    struct ContentState: Codable, Hashable, Sendable {
        /// The session's wall-clock start. The Live Activity renders the **overall timer**
        /// with `Text(timerInterval: startedAt...distantFuture)`, so the OS ticks it on the
        /// wall clock with **zero background CPU** — we never push a per-second update just to
        /// move the clock; the timer stays correct across backgrounding by construction.
        var startedAt: Date
        /// Latest heart rate (bpm), or `nil` before the first sample / when no source is connected.
        var hrBpm: Int?
        /// The exercise currently being performed (or "Resting" / "Done").
        var exerciseName: String
        /// A short set-progress string, e.g. "Set 2 of 4" or "Exercise 3 of 6".
        var setProgress: String
    }

    /// The routine being performed — fixed for the activity's lifetime.
    var routineName: String
}
#endif
