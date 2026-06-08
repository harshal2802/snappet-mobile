#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity contract for a **Kilter climbing session**, shared by the **app**
/// (`KilterLiveActivityController` starts/updates/ends it) and the **widget extension**
/// (`SnappetWidgets`, which renders the Lock Screen + Dynamic Island). Compiled into *both*
/// targets via `project.yml` so the shape can't drift between producer and renderer — the same
/// one-source-of-truth pattern as `WorkoutActivityAttributes` / `LiveWorkoutMessage`.
///
/// A separate type from `WorkoutActivityAttributes` on purpose: a climbing session's live state
/// is current-climb / grade / climb-count / angle, not exercise / set-progress, so overloading the
/// workout contract would muddy both (decisions.md 2026-06-06).
struct KilterActivityAttributes: ActivityAttributes {

    /// Per-update dynamic state. Small on purpose — ActivityKit budgets updates, so we only
    /// carry what the Lock Screen / Dynamic Island actually render.
    struct ContentState: Codable, Hashable, Sendable {
        /// The session's wall-clock start. The Live Activity renders the **overall timer** with
        /// `Text(timerInterval: startedAt...distantFuture)`, so the OS ticks it on the wall clock
        /// with **zero background CPU** — correct across backgrounding by construction.
        var startedAt: Date
        /// Latest heart rate (bpm), or `nil` before the first sample / when no source is connected.
        var hrBpm: Int?
        /// The climb currently being worked (or "Resting" between climbs).
        var currentClimbName: String
        /// The current climb's grade label, e.g. "6c/V5"; empty when resting / unknown.
        var currentGrade: String
        /// Climbs logged so far this session (the running count shown on the wrist + lock screen).
        var climbCount: Int
        /// The board angle in degrees, for the lock-screen context line.
        var angle: Int
        /// Whether the session is paused — freezes the timer + shows a "Paused" badge. Defaulted so
        /// callers that don't care construct it without churn.
        var paused: Bool = false
        /// Whether the user is recovered enough for the next climb (Phase 4); the Lock Screen / Dynamic
        /// Island show a "Recovered" badge. Defaulted so producer + renderer can't drift mid-session.
        var recoveryReady: Bool = false
    }

    /// The board being climbed — fixed for the activity's lifetime (e.g. "Kilter Board").
    var boardName: String
    /// The user's resolved max HR (Phase 2), so the widget tints the HR zone off the same
    /// personalized ceiling as the phone; `nil` → `HeartRateZone.defaultMaxHR`, back-compatible.
    var maxHR: Double?
}
#endif
