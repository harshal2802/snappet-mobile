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
    /// Called with the fresh blocks to insert as a new routine, plus the schedule to adopt (nil = none)
    /// and how to tie it to Habits (prompt 138); the host owns the model context.
    let onImport: ([RoutineExercise], RoutineSchedule?, HabitLinkChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var addSchedule = true
    @State private var schedule: RoutineSchedule?
    /// Off by default for imports: a friend's code shouldn't add a habit unless you ask (wireframe frame 11).
    @State private var habitLink: HabitLinkChoice = .none
    @State private var editingSchedule = false

    init(shared: SharedRoutine, resolver: ExerciseResolver, unit: WeightUnit,
         onImport: @escaping ([RoutineExercise], RoutineSchedule?, HabitLinkChoice) -> Void) {
        self.shared = shared
        self.resolver = resolver
        self.unit = unit
        self.onImport = onImport
        _schedule = State(initialValue: shared.schedule)
    }

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

                if let schedule { scheduleSection(schedule) }

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
                    let adopted = addSchedule ? schedule : nil
                    onImport(blocks, adopted, adopted == nil ? .none : habitLink)
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
            .sheet(isPresented: $editingSchedule) {
                RoutineScheduleEditor(routineName: shared.name, schedule: schedule, habitLink: habitLink,
                                      defaultTrackInHabits: false) { saved, link in
                    if let saved { schedule = saved; habitLink = link } else { addSchedule = false }
                }
            }
        }
    }

    /// The shared schedule, adoptable as-is, tweakable, or declinable (prompt 138).
    private func scheduleSection(_ s: RoutineSchedule) -> some View {
        Section {
            Toggle(isOn: $addSchedule) {
                Label("Add this schedule", systemImage: "calendar")
            }
            .tint(SnappetColor.workout)
            .accessibilityIdentifier("routine.import.addSchedule")
            if addSchedule {
                Button { editingSchedule = true } label: {
                    LabeledContent {
                        Text("Edit").foregroundStyle(SnappetColor.workout)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.summary()).foregroundStyle(.primary)
                            Text(s.reminder.isOn
                                 ? (s.reminder.leadMinutes == 0 ? "Reminder at start" : "Reminder \(s.reminder.leadMinutes) min before")
                                 : "No reminder")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)   // keep the summary in body colours; only "Edit" is tinted
                .accessibilityIdentifier("routine.import.editSchedule")
                Toggle("Track in Habits", isOn: Binding(
                    get: { habitLink != .none }, set: { habitLink = $0 ? .newHabit : .none }))
                    .tint(SnappetColor.workout)
                    .accessibilityIdentifier("routine.import.trackHabit")
            }
        } header: {
            Text("Schedule")
        } footer: {
            if addSchedule, s.reminder.isOn || s.reminder.headsUp != nil {
                Text("Reminders need notification permission — Snappet asks once, when you add.")
            }
        }
    }
}
