import SwiftUI
import SwiftData

/// Create or edit a custom exercise. New exercises are inserted as `CustomExercise`; editing
/// applies changes back onto the existing model. Logs a create event to Snappet Core.
struct ExerciseEditorView: View {
    /// nil → creating a new exercise; non-nil → editing this one.
    let existing: CustomExercise?

    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category: ExerciseCategory = .strength
    @State private var level: ExerciseLevel = .beginner
    @State private var equipment: Equipment?
    @State private var force: Force?
    @State private var mechanic: Mechanic?
    @State private var primary: Set<Muscle> = []
    @State private var secondary: Set<Muscle> = []
    @State private var instructionsText = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Name", text: $name)
                    Picker("Category", selection: $category) {
                        ForEach(ExerciseCategory.allCases) { Text($0.display).tag($0) }
                    }
                    Picker("Level", selection: $level) {
                        ForEach(ExerciseLevel.allCases) { Text($0.display).tag($0) }
                    }
                }

                Section("Equipment & mechanics") {
                    Picker("Equipment", selection: $equipment) {
                        Text("None").tag(Equipment?.none)
                        ForEach(Equipment.allCases) { Text($0.display).tag(Equipment?.some($0)) }
                    }
                    Picker("Force", selection: $force) {
                        Text("None").tag(Force?.none)
                        ForEach(Force.allCases, id: \.self) { Text($0.display).tag(Force?.some($0)) }
                    }
                    Picker("Mechanic", selection: $mechanic) {
                        Text("None").tag(Mechanic?.none)
                        ForEach(Mechanic.allCases, id: \.self) { Text($0.display).tag(Mechanic?.some($0)) }
                    }
                }

                muscleSection("Primary muscles", selection: $primary)
                muscleSection("Secondary muscles", selection: $secondary)

                Section("Instructions") {
                    TextField("One step per line", text: $instructionsText, axis: .vertical)
                        .lineLimit(4...10)
                }
            }
            .navigationTitle(isEditing ? "Edit Exercise" : "New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(trimmedName.isEmpty)
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    @ViewBuilder
    private func muscleSection(_ title: String, selection: Binding<Set<Muscle>>) -> some View {
        Section(title) {
            let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Muscle.allCases) { m in
                    let on = selection.wrappedValue.contains(m)
                    Button {
                        if on { selection.wrappedValue.remove(m) } else { selection.wrappedValue.insert(m) }
                    } label: {
                        Text(m.display)
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(on ? SnappetColor.workout.opacity(0.2) : Color(.secondarySystemFill), in: Capsule())
                            .foregroundStyle(on ? SnappetColor.workout : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .snappetAnimation(SnappetMotion.quick, value: on)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func loadExisting() {
        guard let existing, name.isEmpty else { return }
        let ex = existing.asExercise
        name = ex.name
        category = ex.category
        level = ex.level
        equipment = ex.equipment
        force = ex.force
        mechanic = ex.mechanic
        primary = Set(ex.primaryMuscles)
        secondary = Set(ex.secondaryMuscles)
        instructionsText = ex.instructions.joined(separator: "\n")
    }

    private func save() {
        let instructions = instructionsText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Keep secondary from double-counting a primary muscle.
        let secondaryClean = secondary.subtracting(primary)

        let value = Exercise(
            id: existing?.id ?? "custom-\(UUID().uuidString)", name: trimmedName,
            force: force, level: level, mechanic: mechanic, equipment: equipment,
            primaryMuscles: Array(primary).sorted { $0.display < $1.display },
            secondaryMuscles: Array(secondaryClean).sorted { $0.display < $1.display },
            instructions: instructions, category: category, isCustom: true
        )

        if let existing {
            existing.apply(value)
        } else {
            let model = CustomExercise(id: value.id, name: value.name, category: value.category,
                                       level: value.level, force: value.force, mechanic: value.mechanic,
                                       equipment: value.equipment, primaryMuscles: value.primaryMuscles,
                                       secondaryMuscles: value.secondaryMuscles, instructions: value.instructions)
            context.insert(model)
            core.log(module: WorkoutTrackerModule.id, action: "exercise",
                     summary: "Added exercise: \(value.name)")
        }
        try? context.save()
        dismiss()
    }
}
