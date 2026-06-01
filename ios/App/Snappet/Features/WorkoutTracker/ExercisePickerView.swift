import SwiftUI

/// Multi-select exercise picker used when building a routine. Same search/filter as the
/// browser, but rows toggle a selection; "Add" returns the chosen exercises. Presented as a
/// sheet, so it carries its own NavigationStack.
struct ExercisePickerView: View {
    let resolver: ExerciseResolver
    let onAdd: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var filters = ExerciseFilters()
    @State private var showingFilters = false
    @State private var selected: [String] = []   // ordered selection

    private var merged: [Exercise] { resolver.allMerged }
    private var results: [Exercise] { ExerciseSearch.apply(merged, query: query, filters: filters) }
    private var selectedSet: Set<String> { Set(selected) }

    var body: some View {
        NavigationStack {
            List {
                if !selected.isEmpty {
                    Section("Selected (\(selected.count))") {
                        ForEach(selected, id: \.self) { id in
                            HStack {
                                Text(resolver.name(for: id)).lineLimit(1)
                                Spacer()
                                Button { toggle(id) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section {
                    ForEach(results) { ex in
                        Button { toggle(ex.id) } label: {
                            HStack {
                                ExerciseRow(exercise: ex)
                                Image(systemName: selectedSet.contains(ex.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedSet.contains(ex.id) ? SnappetColor.workout : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(results.count) exercises")
                }
            }
            .listStyle(.plain)
            // The "Selected" section grows/shrinks as picks toggle — gentle list animation, gated.
            .animation(snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: selected)
            .searchable(text: $query, prompt: "Search exercises or muscles")
            .navigationTitle("Add Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingFilters = true } label: {
                        Image(systemName: filters.isEmpty
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add\(selected.isEmpty ? "" : " (\(selected.count))")") { commit() }
                        .disabled(selected.isEmpty)
                }
            }
            .sheet(isPresented: $showingFilters) {
                NavigationStack { ExercisePickerFilters(filters: $filters) }
            }
        }
    }

    private func toggle(_ id: String) {
        if let idx = selected.firstIndex(of: id) { selected.remove(at: idx) }
        else { selected.append(id) }
    }

    private func commit() {
        let chosen = selected.compactMap { resolver.exercise(id: $0) }
        onAdd(chosen)
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
