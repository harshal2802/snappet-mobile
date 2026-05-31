import SwiftUI
import SwiftData

/// Create or edit a routine: name, sport/level/description, default prescription, and an
/// ordered, editable list of exercises. Presented as a sheet with its own NavigationStack.
/// Changes are staged locally and only written to the model on Save (so Cancel is clean).
struct RoutineEditorView: View {
    /// nil → new routine; non-nil → edit this one.
    let routine: Routine?
    let resolver: ExerciseResolver
    let defaultUnit: WeightUnit

    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var sport: SportTag = .general
    @State private var level: RoutineLevel?
    @State private var detail = ""
    @State private var items: [RoutineExercise] = []

    // Defaults applied to newly added exercises.
    @State private var defaultSets = 3
    @State private var defaultReps = "10"
    @State private var defaultRest = 90

    @State private var showingPicker = false
    @State private var loaded = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine") {
                    TextField("Name", text: $name)
                    Picker("Sport", selection: $sport) {
                        ForEach(SportTag.allCases) { Text($0.display).tag($0) }
                    }
                    Picker("Level", selection: $level) {
                        Text("None").tag(RoutineLevel?.none)
                        ForEach(RoutineLevel.allCases) { Text($0.display).tag(RoutineLevel?.some($0)) }
                    }
                    TextField("Description (optional)", text: $detail, axis: .vertical).lineLimit(1...4)
                }

                Section("Defaults for new exercises") {
                    Stepper("Sets: \(defaultSets)", value: $defaultSets, in: 1...20)
                    LabeledContent("Reps") {
                        TextField("Reps", text: $defaultReps).multilineTextAlignment(.trailing)
                    }
                    Stepper("Rest: \(restText(defaultRest))", value: $defaultRest, in: 0...600, step: 15)
                }

                Section {
                    if items.isEmpty {
                        Text("No exercises yet — add some below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($items) { $item in
                        NavigationLink {
                            RoutineExerciseEditor(item: $item, resolver: resolver, defaultUnit: defaultUnit)
                        } label: {
                            RoutineExerciseRow(item: item, resolver: resolver, unit: item.weightUnit ?? defaultUnit)
                        }
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }

                    Button { showingPicker = true } label: {
                        Label("Add Exercise", systemImage: "plus.circle.fill")
                    }
                } header: {
                    HStack {
                        Text("Exercises (\(items.count))")
                        Spacer()
                        if items.count > 1 { EditButton().font(.caption) }
                    }
                }
            }
            .navigationTitle(routine == nil ? "New Routine" : "Edit Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(trimmedName.isEmpty || items.isEmpty)
                }
            }
            .sheet(isPresented: $showingPicker) {
                ExercisePickerView(resolver: resolver) { added in
                    for ex in added { items.append(makeItem(for: ex)) }
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func makeItem(for exercise: Exercise) -> RoutineExercise {
        RoutineExercise(exerciseId: exercise.id, sets: defaultSets, reps: defaultReps,
                        restSeconds: defaultRest, weightUnit: defaultUnit)
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        guard let routine else { return }
        name = routine.name
        sport = routine.sport ?? .general
        level = routine.level
        detail = routine.detail ?? ""
        items = routine.exercises
    }

    private func save() {
        let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let routine {
            routine.name = trimmedName
            routine.sport = sport
            routine.level = level
            routine.detail = cleanDetail.isEmpty ? nil : cleanDetail
            routine.exercises = items
            routine.updatedAt = .now
            // Editing a starter makes it a user routine (so re-seeding never overwrites edits).
            if routine.isStarter { routine.isStarter = false }
        } else {
            let new = Routine(name: trimmedName, exercises: items, isStarter: false,
                              sport: sport, level: level,
                              detail: cleanDetail.isEmpty ? nil : cleanDetail)
            context.insert(new)
            core.log(module: WorkoutTrackerModule.id, action: "routine",
                     summary: "Created routine: \(trimmedName)")
        }
        try? context.save()
        dismiss()
    }
}

/// Edit one exercise's prescription within a routine: sets, reps, rest, optional starting
/// weight + unit, notes, and a display-name override. Pushed within the editor's stack.
struct RoutineExerciseEditor: View {
    @Binding var item: RoutineExercise
    let resolver: ExerciseResolver
    let defaultUnit: WeightUnit

    @State private var weightText = ""

    private var exercise: Exercise? { resolver.exercise(id: item.exerciseId) }

    var body: some View {
        Form {
            Section {
                Stepper("Sets: \(item.sets)", value: $item.sets, in: 1...20)
                LabeledContent("Reps") {
                    TextField("e.g. 8-12, 30s, max", text: $item.reps).multilineTextAlignment(.trailing)
                }
                Stepper("Rest: \(restText(item.restSeconds))", value: $item.restSeconds, in: 0...600, step: 15)
            }

            Section("Starting weight (optional)") {
                LabeledContent("Weight") {
                    TextField("—", text: $weightText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Picker("Unit", selection: Binding(
                    get: { item.weightUnit ?? defaultUnit },
                    set: { item.weightUnit = $0 })) {
                    ForEach(WeightUnit.allCases) { Text($0.display).tag($0) }
                }
            }

            Section("Notes & name") {
                TextField("Notes (optional)", text: Binding(
                    get: { item.notes ?? "" }, set: { item.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    .lineLimit(1...4)
                TextField("Display name override", text: Binding(
                    get: { item.displayName ?? "" }, set: { item.displayName = $0.isEmpty ? nil : $0 }))
            }
        }
        .navigationTitle(exercise?.name ?? resolver.name(for: item.exerciseId, override: item.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { weightText = item.weight.map { Self.format($0) } ?? "" }
        .onChange(of: weightText) { _, newValue in
            let cleaned = newValue.replacingOccurrences(of: ",", with: ".")
            item.weight = Double(cleaned)
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
