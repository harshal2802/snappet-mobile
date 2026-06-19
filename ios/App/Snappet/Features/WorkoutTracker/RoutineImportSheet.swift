import SwiftUI

/// The **import-confirm preview** for a routine arriving over QR / a `snappet://routine/v1/…` link
/// (workout-redesign E6). NEVER silent-imports: it shows the routine's name + its blocks (the same
/// discipline-rhythm `RoutineBlockRow`s the detail uses) and a graceful *"these N exercises aren't in
/// your library"* line (the `KilterDeepLinkRouting.explainMissing` analog), then on **Add to routines**
/// inserts a brand-new local `Routine` (new UUID — it never overwrites an existing one).
struct RoutineImportSheet: View {
    let shared: SharedRoutine
    let resolver: ExerciseResolver
    let unit: WeightUnit
    /// Called with the fresh blocks to insert as a new routine; the host owns the model context.
    let onImport: ([RoutineExercise]) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Block exercise-ids that don't resolve in this device's library (custom exercises authored on the
    /// sharer's phone, or a trimmed catalog). The import still proceeds — the block keeps its inline name.
    private var unresolvable: [String] {
        shared.unresolvableExerciseIds { resolver.exercise(id: $0) != nil }
    }

    /// The blocks as fresh `RoutineExercise`s (new ids), for both the preview rows and the insert.
    private var blocks: [RoutineExercise] { shared.routineExercises() }

    /// The disciplines present, in canonical order — the discipline-rhythm dots (mirrors RoutineDetailView).
    private var disciplines: [WorkoutDiscipline] {
        let present = Set(blocks.map(\.discipline))
        return WorkoutDiscipline.allCases.filter { present.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(shared.name).font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            Text("\(blocks.count) block\(blocks.count == 1 ? "" : "s") · \(blocks.reduce(0) { $0 + $1.sets }) sets")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            ForEach(disciplines) { d in
                                Image(systemName: d.symbol).font(.caption2).foregroundStyle(d.accent)
                            }
                        }
                    }
                    if let detail = shared.detail, !detail.isEmpty {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }

                if !unresolvable.isEmpty {
                    Section {
                        Label {
                            Text("\(unresolvable.count) exercise\(unresolvable.count == 1 ? "" : "s") aren't in your library — they'll import with the shared name, but won't link to a catalog entry.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }

                Section("Blocks") {
                    ForEach(blocks) { re in
                        RoutineBlockRow(item: re, resolver: resolver, unit: unit)
                    }
                }
            }
            .navigationTitle("Import routine")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    onImport(blocks)
                    dismiss()
                } label: {
                    Label("Add to my routines", systemImage: "plus.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.workout)
                .padding()
                .background(.bar)
                .accessibilityIdentifier("routine.import.confirm")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
