import SwiftUI

/// A routine's detail: its prescription (exercises × sets/reps/rest), metadata and source,
/// with a prominent Start button and an Edit action. Pushed onto the App Library's stack.
struct RoutineDetailView: View {
    let routine: Routine
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let start: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    var body: some View {
        List {
            if let detail = routine.detail, !detail.isEmpty {
                Section { Text(detail).font(.callout) }
            }

            Section {
                ForEach(routine.exercises) { re in
                    RoutineExerciseRow(item: re, resolver: resolver, unit: unit)
                }
            } header: {
                Text("\(routine.exercises.count) exercises · \(routine.totalSets) sets")
            }

            if routine.sport != nil || routine.level != nil || !routine.tags.isEmpty || routine.sourceLabel != nil {
                Section("About") {
                    if let sport = routine.sport {
                        LabeledContent("Sport") {
                            Label(sport.display, systemImage: sport.symbol)
                        }
                    }
                    if let level = routine.level { LabeledContent("Level", value: level.display) }
                    if !routine.tags.isEmpty {
                        LabeledContent("Tags", value: routine.tags.joined(separator: ", "))
                    }
                    if let label = routine.sourceLabel {
                        if let urlString = routine.sourceURL, let url = URL(string: urlString) {
                            Link(destination: url) { LabeledContent("Source", value: label) }
                        } else {
                            LabeledContent("Source", value: label)
                        }
                    }
                }
            }
        }
        .navigationTitle(routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            Button { dismiss(); start() } label: {
                Label("Start Workout", systemImage: "play.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .padding()
            .background(.bar)
            .disabled(routine.exercises.isEmpty)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing) {
            RoutineEditorView(routine: routine, resolver: resolver, defaultUnit: unit)
        }
    }
}

/// One exercise prescription inside a routine detail / editor preview.
struct RoutineExerciseRow: View {
    let item: RoutineExercise
    let resolver: ExerciseResolver
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(resolver.name(for: item.exerciseId, override: item.displayName))
                .font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                Text("\(item.sets) × \(item.reps)")
                if item.restSeconds > 0 {
                    Label(restText(item.restSeconds), systemImage: "timer").labelStyle(.titleAndIcon)
                }
                if let weight = item.weight {
                    Label("\(WorkoutMath.formatWeight(kg: WorkoutMath.toKg(weight, item.weightUnit), unit: unit)) \(unit.display)",
                          systemImage: "scalemass")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let notes = item.notes, !notes.isEmpty {
                Text(notes).font(.caption2).foregroundStyle(.tertiary).italic()
            }
        }
        .padding(.vertical, 2)
    }
}

/// "90s" or "1m 30s" for a rest duration.
func restText(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60, s = seconds % 60
    return s == 0 ? "\(m)m" : "\(m)m \(s)s"
}
