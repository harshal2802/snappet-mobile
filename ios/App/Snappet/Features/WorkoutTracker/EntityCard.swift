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

/// A rolled-up stat pill for an entity-card header — the strength/run/timed/dance analogue of the climb
/// grade pill + status badge (matches the wireframe `.spill` chips). Renders a short stat ("top 100 × 5",
/// "5.2 km", "9 sets") on a tinted capsule; a `nil` tint is the muted/secondary variant (e.g. "3 sets").
struct EntityRollupChip: View {
    let text: String
    var tint: Color?
    var systemImage: String?

    init(_ text: String, tint: Color? = nil, systemImage: String? = nil) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(tint ?? SnappetColor.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((tint?.opacity(0.15)) ?? SnappetColor.surfaceMuted, in: Capsule())
    }
}
