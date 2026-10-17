import SwiftUI
import SwiftData

/// Multi-select **library** picker for the block-based routine builder (workout-redesign E4). Where the old
/// routine editor could only pick strength `Exercise`s (so a routine was reps×weight-locked), this picks any
/// E3 `LibraryItem` — a strength move, a timed protocol, a climb style, a run template — and hands the
/// chosen items back so the editor can seed a **typed block** (`RoutineSessionBuilder.block(from:)`). It
/// reuses the library's discipline chip bar + faceted filter + `LibraryItemRow` so picking-for-a-routine
/// reads exactly like browsing the library. Presented as a sheet (its own `NavigationStack`).
///
/// **It's the Library** (prompt 187): it opens on **Yours · Most used** — a pick there becomes a block prescribing
/// what you did last time (`ActivityLauncher.routineBlock`, like the Activity page's Add to routine) — with the
/// catalog under **Explore**.
struct LibraryPickerView: View {
    /// A pick: a catalog item (the editor seeds its block) or one of yours, already a block.
    enum Pick {
        case item(LibraryItem)
        case block(RoutineExercise)
    }

    let resolver: ExerciseResolver
    var defaultUnit: WeightUnit = .kg
    let onAdd: ([Pick]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \TimedExerciseCatalog.lastUsedAt, order: .reverse) private var timed: [TimedExerciseCatalog]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var history: [WorkoutSession]
    @Query private var entries: [LibraryEntry]
    @State private var source = LibraryPickSource()
    @State private var loaded = false
    @State private var showYours = true

    @State private var query = ""
    @State private var discipline: WorkoutDiscipline?
    @State private var facets = LibraryFacets()
    @State private var showingFilters = false
    @State private var selected: [LibraryPick.Choice] = []   // ordered selection

    private var allItems: [LibraryItem] { resolver.library(timed: timed) }
    private var disciplines: [WorkoutDiscipline] { LibraryBuilder.disciplines(in: allItems) }
    private var results: [LibraryItem] {
        LibraryBuilder.apply(allItems, query: query, discipline: discipline, facets: facets)
    }
    private var yourRows: [LibraryCatalog.Row] {
        LibraryPick.rows(source.rows, hidden: source.hidden, query: query, discipline: discipline)
    }
    private var selectedSet: Set<LibraryPick.Choice> { Set(selected) }

    var body: some View {
        NavigationStack {
            List {
                LibraryPickModeBar(yours: $showYours)
                disciplineChipBar

                if !selected.isEmpty {
                    Section("Selected (\(selected.count))") {
                        ForEach(selected, id: \.self) { choice in
                            HStack {
                                Image(systemName: symbol(of: choice).0).foregroundStyle(symbol(of: choice).1)
                                    .frame(width: 24)
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
            .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: selected)
            .searchable(text: $query, prompt: "Search the library")
            .navigationTitle("Add to routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingFilters = true } label: {
                        Image(systemName: facets.isEmpty
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .disabled(discipline == nil || showYours)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add\(selected.isEmpty ? "" : " (\(selected.count))")") { commit() }
                        .disabled(selected.isEmpty)
                        .accessibilityIdentifier("libraryPicker.add")
                }
            }
            .sheet(isPresented: $showingFilters) {
                LibraryPickerFilterSheet(discipline: discipline ?? .strength, facets: $facets)
            }
            .task {
                guard !loaded else { return }
                loaded = true
                source = LibraryPickSource.build(history: history, entries: entries, resolver: resolver,
                                                 unit: defaultUnit)
                showYours = LibraryPick.opensOnYours(LibraryPick.rows(source.rows, hidden: source.hidden,
                                                                      query: "", discipline: nil))
            }
        }
    }

    @ViewBuilder private var yoursSection: some View {
        Section {
            if yourRows.isEmpty {
                Text(query.isEmpty && discipline == nil ? "Nothing logged yet — pick from Explore." : "No match in yours.")
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
            ForEach(results) { item in
                let on = selectedSet.contains(.catalog(item.id))
                Button { toggle(.catalog(item.id)) } label: {
                    HStack {
                        LibraryItemRow(item: item)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? item.discipline.accent : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("libraryPicker.row")
            }
        } header: {
            Text("\(results.count) \(discipline?.label.lowercased() ?? "item")\(results.count == 1 ? "" : "s")")
        }
    }

    private func item(_ id: String) -> LibraryItem? { allItems.first { $0.id == id } }

    private func name(of choice: LibraryPick.Choice) -> String {
        switch choice {
        case .catalog(let id): return item(id)?.title ?? id
        case .yours(let key): return source.row(key)?.title ?? key.nameKey
        }
    }

    private func symbol(of choice: LibraryPick.Choice) -> (String, Color) {
        switch choice {
        case .catalog(let id):
            return item(id).map { ($0.symbol, $0.discipline.accent) } ?? ("circle", .secondary)
        case .yours(let key):
            return source.row(key).map { ($0.discipline.symbol, $0.discipline.accent) } ?? ("circle", .secondary)
        }
    }

    private var disciplineChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, label: "All", symbol: "square.grid.2x2", accent: SnappetColor.workout)
                ForEach(disciplines) { d in
                    chip(d, label: d.label, symbol: d.symbol, accent: d.accent)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
    }

    private func chip(_ d: WorkoutDiscipline?, label: String, symbol: String, accent: Color) -> some View {
        let on = discipline == d
        return Button {
            withAnimation(SnappetMotion.quick) {
                discipline = d
                facets.keepOnly(d)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption.weight(.semibold))
                Text(label).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? accent : SnappetColor.textSecondary)
            .background(on ? accent.opacity(0.15) : SnappetColor.surfaceMuted, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? accent.opacity(0.4) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("libraryPicker.chip.\(d?.rawValue ?? "all")")
    }

    private func toggle(_ choice: LibraryPick.Choice) {
        if let idx = selected.firstIndex(of: choice) { selected.remove(at: idx) }
        else { selected.append(choice) }
    }

    private func commit() {
        onAdd(selected.compactMap { choice in
            switch choice {
            case .catalog(let id): return item(id).map(Pick.item)
            case .yours(let key): return source.routineBlock(key, defaultUnit: defaultUnit).map(Pick.block)
            }
        })
        dismiss()
    }
}

/// The block-builder's faceted filter — the same discipline-swapping sheet the library browse uses, reused
/// verbatim so a routine pick filters by muscle/equipment (strength) · style (climb) · protocol (timed) ·
/// terrain (run).
private struct LibraryPickerFilterSheet: View {
    let discipline: WorkoutDiscipline
    @Binding var facets: LibraryFacets
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch discipline {
                case .strength:
                    Section { Toggle("No equipment", isOn: $facets.noEquipment) }
                    chipSection("Muscle", ExerciseFilters.allMuscles, label: \.display,
                                isOn: { facets.muscles.contains($0) }, toggle: { toggle(\.muscles, $0) })
                    chipSection("Equipment", ExerciseFilters.allEquipment, label: \.display,
                                isOn: { facets.equipment.contains($0) }, toggle: { toggle(\.equipment, $0) })
                case .climb:
                    chipSection("Style", ClimbType.allCases, label: \.label,
                                isOn: { facets.climbTypes.contains($0) }, toggle: { toggle(\.climbTypes, $0) })
                case .timed:
                    chipSection("Protocol", TimedExerciseCategory.allCases, label: \.display,
                                isOn: { facets.timedCategories.contains($0) },
                                toggle: { toggle(\.timedCategories, $0) })
                case .run:
                    chipSection("Terrain", RunTerrain.allCases, label: \.display,
                                isOn: { facets.runTerrains.contains($0) }, toggle: { toggle(\.runTerrains, $0) })
                case .dance, .other:
                    Section { Text("No filters for this type yet.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("\(discipline.label) filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { facets.clear() }.disabled(facets.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle<T: Hashable>(_ keyPath: WritableKeyPath<LibraryFacets, Set<T>>, _ value: T) {
        if facets[keyPath: keyPath].contains(value) { facets[keyPath: keyPath].remove(value) }
        else { facets[keyPath: keyPath].insert(value) }
    }

    @ViewBuilder
    private func chipSection<T: Identifiable & Hashable>(
        _ title: String, _ items: [T], label: KeyPath<T, String>,
        isOn: @escaping (T) -> Bool, toggle: @escaping (T) -> Void
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
