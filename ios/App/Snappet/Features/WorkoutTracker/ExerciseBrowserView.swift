import SwiftUI

/// Shared exercise-browse primitives. The flat, strength-only `ExerciseBrowserView` that used to be the
/// "Exercises" tab is **superseded by the discipline-spined `WorkoutLibraryView`** (workout-redesign E3);
/// what remains here is the reusable `ExerciseRow` (still used by the routine builder / picker / settings)
/// and the `ExerciseFilters` chip-source extension (used by the routine picker + the library filter sheet).

/// A single exercise list row: category glyph + name + subtitle, with a "Custom" badge for
/// user-created exercises. Reused by the routine picker, the routine editor, and settings.
struct ExerciseRow: View {
    let exercise: Exercise

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: exercise.category.symbol)
                .font(.title3)
                .foregroundStyle(SnappetColor.workout)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name).font(.headline).lineLimit(1)
                Text(exercise.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if exercise.isCustom {
                Text("Custom")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(SnappetColor.workout.opacity(0.15), in: Capsule())
                    .foregroundStyle(SnappetColor.workout)
            }
        }
        .padding(.vertical, 2)
    }
}

extension ExerciseFilters {
    /// Muscles and equipment, ordered for the filter UI.
    static let allMuscles = Muscle.allCases.sorted { $0.display < $1.display }
    static let allEquipment = Equipment.allCases.sorted { $0.display < $1.display }
}
