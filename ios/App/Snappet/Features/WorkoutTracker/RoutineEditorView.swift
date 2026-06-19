import SwiftUI
import SwiftData

/// Create or edit a routine: name, sport/level/description, default prescription, and an ordered, editable
/// list of **type-tagged blocks** (workout-redesign E4). Where the editor was reps×weight-locked, it now
/// builds a discipline-mixed routine — a strength block beside a timed circuit beside a climb beside a run —
/// each row tinted by its `WorkoutDiscipline.accent` and showing adaptive columns derived from the measure.
/// The exercise picker is the E3 **library** (`LibraryPickerView`), so a climb/timed/run template can seed a
/// typed block via `RoutineSessionBuilder.block(from:)`. Presented as a sheet with its own NavigationStack;
/// changes are staged locally and only written on Save (Cancel is clean). The reorder (`.onMove`) keeps the
/// hard-won lazy-List pattern (#158).
///
/// **Save-as-routine (workout-redesign E5).** A third entry mode: an optional `prefill` `RoutineDraft`
/// (`routine == nil` + `prefill != nil`) seeds the editor's local state from a finished Quick Session that
/// `SessionToRoutine` converted (actuals → prescription), so the user **reviews** it — trims warm-ups,
/// renames it, adjusts targets — before it's inserted. The `prefill` is NOT inserted; Save takes the same
/// new-routine INSERT path (a brand-new `Routine` with a fresh UUID), so the loop never silently writes a
/// routine and the saved routine round-trips through E4's `makeSession`.
struct RoutineEditorView: View {
    /// nil → new routine; non-nil → edit this one.
    let routine: Routine?
    /// A pre-filled draft (save-as-routine, E5). Used only when `routine == nil`: seeds the local state for
    /// review, then Save INSERTS a new routine from the (reviewed) state.
    var prefill: RoutineDraft? = nil
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

    // Defaults applied to newly added strength exercises.
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

                Section("Defaults for new strength exercises") {
                    Stepper("Sets: \(defaultSets)", value: $defaultSets, in: 1...20)
                    LabeledContent("Reps") {
                        TextField("Reps", text: $defaultReps).multilineTextAlignment(.trailing)
                    }
                    Stepper("Rest: \(restText(defaultRest))", value: $defaultRest, in: 0...600, step: 15)
                }

                Section {
                    if items.isEmpty {
                        Text("No blocks yet — add exercises, climbs, timed circuits or a run below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($items) { $item in
                        NavigationLink {
                            RoutineBlockEditor(item: $item, resolver: resolver, defaultUnit: defaultUnit)
                        } label: {
                            RoutineBlockRow(item: item, resolver: resolver, unit: item.weightUnit ?? defaultUnit)
                        }
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }

                    Button { showingPicker = true } label: {
                        Label("Add Block", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("routineEditor.addBlock")
                } header: {
                    HStack {
                        Text("Blocks (\(items.count))")
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
                LibraryPickerView(resolver: resolver) { picked in
                    for item in picked { items.append(makeBlock(for: item)) }
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    /// Seed a typed block from a picked library item (the E3 → E4 pipeline). Strength uses the editor's
    /// `defaultSets/Reps/Rest`; climb/timed/run carry the template's prescription (via the pure builder).
    private func makeBlock(for item: LibraryItem) -> RoutineExercise {
        RoutineSessionBuilder.block(from: item, defaultUnit: defaultUnit,
                                    defaultSets: defaultSets, defaultReps: defaultReps, defaultRest: defaultRest)
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        if let routine {
            name = routine.name
            sport = routine.sport ?? .general
            level = routine.level
            detail = routine.detail ?? ""
            items = routine.exercises
        } else if let prefill {
            // Save-as-routine (E5): seed the editor for REVIEW from the converted draft. Nothing is
            // inserted here — Save takes the new-routine path below (a fresh UUID), so the user trims /
            // renames / adjusts first.
            name = prefill.name
            sport = prefill.sport ?? .general
            level = prefill.level
            detail = prefill.detail ?? ""
            items = prefill.exercises
        }
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

/// Edit one **block**'s prescription — discipline-aware (workout-redesign E4). The fields shown derive from
/// the block's `discipline`: strength = sets × reps × weight; timed = sets × hold seconds; climb = type +
/// scale + grade + attempts; run = distance + duration target. Targets stay OPTIONAL (the fast-entry ethos —
/// a routine can prescribe just "3 boulders" with no grade). Pushed within the editor's stack.
struct RoutineBlockEditor: View {
    @Binding var item: RoutineExercise
    let resolver: ExerciseResolver
    let defaultUnit: WeightUnit

    @State private var weightText = ""
    @State private var holdText = ""
    @State private var distanceText = ""
    @FocusState private var keypadFocused: Bool

    private var exercise: Exercise? { resolver.exercise(id: item.exerciseId) }
    private var distanceUnit: DistanceUnit { defaultUnit == .lb ? .mi : .km }

    var body: some View {
        Form {
            // A type-tinted header so the editor reads as "you're editing a CLIMB block".
            Section {
                disciplineHeader
            }

            switch item.discipline {
            case .strength: strengthFields
            case .climb:    climbFields
            case .timed:    timedFields
            case .run:      runFields
            case .dance, .other: timedFields
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
        .keypadDoneToolbar($keypadFocused)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            weightText = item.weight.map { Self.format($0) } ?? ""
            holdText = item.targetDurationSec.map { String(Int($0)) } ?? ""
            distanceText = item.targetDistanceMeters.map {
                Self.format(distanceUnit == .km ? $0 / 1000 : $0 / 1609.344)
            } ?? ""
        }
        .onChange(of: weightText) { _, v in item.weight = Double(v.replacingOccurrences(of: ",", with: ".")) }
        .onChange(of: holdText) { _, v in
            let secs = Double(v); item.targetDurationSec = (secs ?? 0) > 0 ? secs : nil
        }
        .onChange(of: distanceText) { _, v in
            let entered = Double(v.replacingOccurrences(of: ",", with: "."))
            item.targetDistanceMeters = entered.map { distanceUnit == .km ? $0 * 1000 : $0 * 1609.344 }
                .flatMap { $0 > 0 ? $0 : nil }
        }
    }

    private var disciplineHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: item.discipline.symbol)
                .font(.title3).foregroundStyle(item.discipline.accent).frame(width: 26)
            Text(item.discipline.label.uppercased())
                .font(.caption.weight(.bold)).foregroundStyle(item.discipline.accent)
            Spacer()
        }
        .accessibilityIdentifier("routineBlock.header.\(item.discipline.rawValue)")
    }

    private var strengthFields: some View {
        Group {
            Section {
                Stepper("Sets: \(item.sets)", value: $item.sets, in: 1...20)
                LabeledContent("Reps") {
                    TextField("e.g. 8-12, max", text: $item.reps).multilineTextAlignment(.trailing)
                }
                Stepper("Rest: \(restText(item.restSeconds))", value: $item.restSeconds, in: 0...600, step: 15)
            }
            Section("Starting weight (optional)") {
                LabeledContent("Weight") {
                    TextField("—", text: $weightText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($keypadFocused)
                }
                Picker("Unit", selection: Binding(
                    get: { item.weightUnit ?? defaultUnit }, set: { item.weightUnit = $0 })) {
                    ForEach(WeightUnit.allCases) { Text($0.display).tag($0) }
                }
            }
        }
    }

    private var climbFields: some View {
        Group {
            Section("Climb") {
                Picker("Type", selection: Binding(
                    get: { item.climbType },
                    set: { newType in
                        item.climbTypeRaw = newType.rawValue
                        // Snap the scale + grade to the new type's default so a route never carries a V grade.
                        item.climbGradeScaleRaw = newType.defaultScale.rawValue
                        item.climbGradeLabel = newType.defaultScale.defaultGrade
                    })) {
                    ForEach(ClimbType.allCases) { Text($0.label).tag($0) }
                }
                Stepper("Attempts: \(item.sets)", value: $item.sets, in: 1...20)
                Stepper("Rest: \(restText(item.restSeconds))", value: $item.restSeconds, in: 0...600, step: 15)
            }
            Section("Target grade (optional) · \(item.climbGradeScale.label)") {
                let scale = item.climbGradeScale
                Picker("Grade", selection: Binding(
                    get: { item.climbGradeLabel ?? scale.defaultGrade },
                    set: { item.climbGradeLabel = $0 })) {
                    ForEach(scale.rungs, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.wheel)
                .accessibilityIdentifier("routineBlock.climbGrade")
            }
        }
    }

    private var timedFields: some View {
        Section("Timed") {
            Stepper("Sets: \(item.sets)", value: $item.sets, in: 1...20)
            LabeledContent("Hold (sec, optional)") {
                TextField("—", text: $holdText)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($keypadFocused)
                    .accessibilityIdentifier("routineBlock.hold")
            }
            Stepper("Rest: \(restText(item.restSeconds))", value: $item.restSeconds, in: 0...600, step: 15)
        }
    }

    private var runFields: some View {
        Section("Run target (optional)") {
            LabeledContent("Distance (\(distanceUnit.display))") {
                TextField("—", text: $distanceText)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($keypadFocused)
                    .accessibilityIdentifier("routineBlock.distance")
            }
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
