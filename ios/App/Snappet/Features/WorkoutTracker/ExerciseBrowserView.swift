import SwiftUI

/// Browse / search the full exercise catalog (bundled + custom), with muscle / equipment /
/// category / level filters. Tapping a row pushes its detail. Reached as a section of the
/// workout app (lives inside the App Library's NavigationStack — no stack of its own).
struct ExerciseBrowserView: View {
    let resolver: ExerciseResolver

    @State private var query = ""
    @State private var filters = ExerciseFilters()
    @State private var showingFilters = false

    private var results: [Exercise] {
        ExerciseSearch.apply(resolver.allMerged, query: query, filters: filters)
    }

    var body: some View {
        List {
            if !filters.isEmpty {
                Section {
                    Button(role: .destructive) { filters.clear() } label: {
                        Label("Clear \(filters.activeCount) filter\(filters.activeCount == 1 ? "" : "s")",
                              systemImage: "xmark.circle")
                    }
                }
            }
            Section {
                ForEach(results) { ex in
                    NavigationLink(value: ex) { ExerciseRow(exercise: ex) }
                }
            } header: {
                Text("\(results.count) exercise\(results.count == 1 ? "" : "s")")
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search exercises or muscles")
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty ? "—" : query)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingFilters = true } label: {
                    Label("Filters", systemImage: filters.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            ExerciseFilterSheet(filters: $filters)
        }
    }
}

/// A single exercise list row: category glyph + name + subtitle, with a "Custom" badge for
/// user-created exercises.
struct ExerciseRow: View {
    let exercise: Exercise

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: exercise.category.symbol)
                .font(.title3)
                .foregroundStyle(.orange)
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
                    .background(.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Filter sheet

private struct ExerciseFilterSheet: View {
    @Binding var filters: ExerciseFilters
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                chipSection("Muscle", ExerciseFilters.allMuscles, label: \.display,
                            isOn: { filters.muscles.contains($0) },
                            toggle: { toggle(\.muscles, $0) })
                chipSection("Equipment", ExerciseFilters.allEquipment, label: \.display,
                            isOn: { filters.equipment.contains($0) },
                            toggle: { toggle(\.equipment, $0) })
                chipSection("Category", ExerciseCategory.allCases, label: \.display,
                            isOn: { filters.categories.contains($0) },
                            toggle: { toggle(\.categories, $0) })
                chipSection("Level", ExerciseLevel.allCases, label: \.display,
                            isOn: { filters.levels.contains($0) },
                            toggle: { toggle(\.levels, $0) })
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { filters.clear() }.disabled(filters.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle<T: Hashable>(_ keyPath: WritableKeyPath<ExerciseFilters, Set<T>>, _ value: T) {
        if filters[keyPath: keyPath].contains(value) { filters[keyPath: keyPath].remove(value) }
        else { filters[keyPath: keyPath].insert(value) }
    }

    @ViewBuilder
    private func chipSection<T: Identifiable & Hashable>(
        _ title: String, _ items: [T], label: KeyPath<T, String>,
        isOn: @escaping (T) -> Bool, toggle: @escaping (T) -> Void
    ) -> some View {
        Section(title) {
            FlowChips(items: items, label: label, isOn: isOn, toggle: toggle)
        }
    }
}

/// A simple wrapping row of selectable chips.
private struct FlowChips<T: Identifiable & Hashable>: View {
    let items: [T]
    let label: KeyPath<T, String>
    let isOn: (T) -> Bool
    let toggle: (T) -> Void

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                let on = isOn(item)
                Button { toggle(item) } label: {
                    Text(item[keyPath: label])
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? Color.orange.opacity(0.2) : Color(.secondarySystemFill),
                                    in: Capsule())
                        .foregroundStyle(on ? .orange : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

extension ExerciseFilters {
    /// Muscles and equipment, ordered for the filter UI.
    static let allMuscles = Muscle.allCases.sorted { $0.display < $1.display }
    static let allEquipment = Equipment.allCases.sorted { $0.display < $1.display }
}
