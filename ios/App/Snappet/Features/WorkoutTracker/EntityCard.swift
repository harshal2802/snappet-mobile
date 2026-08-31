import SwiftUI

/// Shared view-layer building blocks for the freeform **entity cards** (Workout-Type Parity). Climbing's
/// expandable card (`climbSection`) is the template; strength/running/dance/timed reuse these primitives so
/// every discipline reads as the same expandable card with a rolled-up header. Kept here (not in the pure
/// `WorkoutDiscipline`) because they import SwiftUI / `SnappetColor`.
///
/// **A11y identifier convention** for the generalized cards (the climb card keeps its existing
/// `freeform.climb*` ids for back-compat): `freeform.entityName` (tap-to-expand name), `freeform.expand`
/// (chevron), `freeform.entityMenu` (⋯), `freeform.logSet` / `freeform.timeThisSet` (footer actions),
/// `freeform.logLeg` (running). The shared expand state is `FreeformPlayerView.expandedEntities`.
extension WorkoutDiscipline {
    /// The view-layer wayfinding accent for this discipline (kept out of the pure enum). Pulled onto the
    /// curated `SnappetColor` module ramp: strength→ember, climb→Kilter amber, run→azure, timed→tomato,
    /// dance→violet, other→teal.
    var accent: Color {
        switch self {
        case .strength: return SnappetColor.workout
        case .climb:    return SnappetColor.kilter
        case .run:      return SnappetColor.budget
        case .timed:    return SnappetColor.pomodoro
        case .dance:    return SnappetColor.journal
        case .other:    return SnappetColor.expenses
        }
    }
}

