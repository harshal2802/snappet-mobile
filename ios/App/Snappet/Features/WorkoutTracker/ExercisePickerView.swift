import SwiftUI
import SwiftData

/// Multi-select "Add exercises" picker for a live Quick Session. **It's the Library** (prompt 187): it opens on
/// **Yours · Most used** — anything you've done (a lift, a hold, a climb, a run…) with what you did last time — and
/// a Yours pick comes back set up the way you left it (`ActivityLauncher`, like Log it now). **Explore** is the
/// catalog with the browser's search/filters; a catalog pick starts blank. "Add" returns the entities to log, in
/// the order you ticked them. Presented as a sheet, so it carries its own NavigationStack.
struct ExercisePickerView: View {
    let resolver: ExerciseResolver
    var unit: WeightUnit = .kg
    let onAdd: ([SessionExercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var history: [WorkoutSession]
    @Query private var entries: [LibraryEntry]
    @State private var source = LibraryPickSource()
    @State private var loaded = false
    @State private var showYours = true
    @State private var query = ""
    @State private var filters = ExerciseFilters()
    @State private var showingFilters = false
    @State private var selected: [LibraryPick.Choice] = []   // ordered selection

    private var merged: [Exercise] { resolver.allMerged }
    private var results: [Exercise] { ExerciseSearch.apply(merged, query: query, filters: filters) }
    private var yourRows: [LibraryCatalog.Row] {
        LibraryPick.rows(source.rows, hidden: source.hidden, query: query, discipline: nil)
    }
    private var selectedSet: Set<LibraryPick.Choice> { Set(selected) }

    var body: some View {
        NavigationStack {
            List {
                LibraryPickModeBar(yours: $showYours)
                if !selected.isEmpty {
                    Section("Selected (\(selected.count))") {
                        ForEach(selected, id: \.self) { choice in
                            HStack {
                                Text(name(of: choice)).lineLimit(1)
                                Spacer()
                                Button { toggle(choice) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if showYours { yoursSection } else { exploreSection }
            }
            .listStyle(.plain)
            // The "Selected" section grows/shrinks as picks toggle — gentle list animation, gated.
            .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: selected)
            .searchable(text: $query, prompt: showYours ? "Search yours" : "Search exercises or muscles")
            .navigationTitle("Add Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !showYours {
                        Button { showingFilters = true } label: {
                            Image(systemName: filters.isEmpty
                                  ? "line.3.horizontal.decrease.circle"
                                  : "line.3.horizontal.decrease.circle.fill")
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add\(selected.isEmpty ? "" : " (\(selected.count))")") { commit() }
                        .disabled(selected.isEmpty)
                        .accessibilityIdentifier("picker.add")
                }
            }
            .sheet(isPresented: $showingFilters) {
                NavigationStack { ExercisePickerFilters(filters: $filters) }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                source = LibraryPickSource.build(history: history, entries: entries, resolver: resolver, unit: unit)
                showYours = LibraryPick.opensOnYours(LibraryPick.rows(source.rows, hidden: source.hidden,
                                                                      query: "", discipline: nil))
            }
        }
    }

    @ViewBuilder private var yoursSection: some View {
        Section {
            if yourRows.isEmpty {
                Text(query.isEmpty ? "Nothing logged yet — pick from Explore." : "No match in yours.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(yourRows) { row in
                Button { toggle(.yours(row.key)) } label: {
                    LibraryPickRow(row: row, selected: selectedSet.contains(.yours(row.key)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("picker.yours.row")
            }
        } header: {
            Text("Most used")
        }
    }

    @ViewBuilder private var exploreSection: some View {
        Section {
            ForEach(results) { ex in
                Button { toggle(.catalog(ex.id)) } label: {
                    HStack {
                        ExerciseRow(exercise: ex)
                        Image(systemName: selectedSet.contains(.catalog(ex.id)) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedSet.contains(.catalog(ex.id)) ? SnappetColor.workout : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("\(results.count) exercises")
        }
    }

    private func name(of choice: LibraryPick.Choice) -> String {
        switch choice {
        case .catalog(let id): return resolver.name(for: id)
        case .yours(let key): return source.row(key)?.title ?? key.nameKey
        }
    }

    private func toggle(_ choice: LibraryPick.Choice) {
        if let idx = selected.firstIndex(of: choice) { selected.remove(at: idx) }
        else { selected.append(choice) }
    }

    private func commit() {
        let entities: [SessionExercise] = selected.compactMap { choice in
            switch choice {
            case .catalog(let id):
                guard resolver.exercise(id: id) != nil else { return nil }
                return SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                       sets: [], displayName: nil, kindRaw: SetKind.repsWeight.rawValue)
            case .yours(let key):
                return source.sessionExercise(key)
            }
        }
        onAdd(entities)
        dismiss()
    }
}

/// Lightweight filter form reused by the picker (mirrors the browser's filters).
private struct ExercisePickerFilters: View {
    @Binding var filters: ExerciseFilters
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            picker("Category", ExerciseCategory.allCases, isOn: { filters.categories.contains($0) },
                   toggle: { toggle(\.categories, $0) }, label: \.display)
            picker("Level", ExerciseLevel.allCases, isOn: { filters.levels.contains($0) },
                   toggle: { toggle(\.levels, $0) }, label: \.display)
            picker("Equipment", ExerciseFilters.allEquipment, isOn: { filters.equipment.contains($0) },
                   toggle: { toggle(\.equipment, $0) }, label: \.display)
            picker("Muscle", ExerciseFilters.allMuscles, isOn: { filters.muscles.contains($0) },
                   toggle: { toggle(\.muscles, $0) }, label: \.display)
        }
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Clear") { filters.clear() }.disabled(filters.isEmpty)
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func toggle<T: Hashable>(_ keyPath: WritableKeyPath<ExerciseFilters, Set<T>>, _ value: T) {
        if filters[keyPath: keyPath].contains(value) { filters[keyPath: keyPath].remove(value) }
        else { filters[keyPath: keyPath].insert(value) }
    }

    @ViewBuilder
    private func picker<T: Identifiable & Hashable>(
        _ title: String, _ items: [T], isOn: @escaping (T) -> Bool,
        toggle: @escaping (T) -> Void, label: KeyPath<T, String>
    ) -> some View {
        Section(title) {
            ForEach(items) { item in
                Button { toggle(item) } label: {
                    HStack {
                        Text(item[keyPath: label]).foregroundStyle(.primary)
                        Spacer()
                        if isOn(item) { Image(systemName: "checkmark").foregroundStyle(SnappetColor.workout) }
                    }
                }
            }
        }
    }
}
