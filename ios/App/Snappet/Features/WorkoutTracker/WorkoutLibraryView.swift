import SwiftUI
import SwiftData

/// **The workout Library** (workout-redesign E3) — replaces the flat, strength-only "Exercises" browser
/// with a library organized by workout **TYPE** (the top spine). A row of discipline chips picks the active
/// facet; the faceted filter **swaps its facets by the active discipline**; a "Recent across all types"
/// band surfaces the cross-discipline win (a climb beside a bench press); and each row deep-links to the
/// discipline-adaptive detail. Reached as a section of the workout app (lives inside the App Library's
/// `NavigationStack` — no stack of its own), mirroring the old `ExerciseBrowserView`.
struct WorkoutLibraryView: View {
    let resolver: ExerciseResolver
    let history: [WorkoutSession]
    let unit: WeightUnit
    let open: (LibraryItem) -> Void
    let openSession: (UUID) -> Void
    /// Bound to `WorkoutHomeView.showingLibraryImport` so the banner can open the sheet.
    @Binding var showingLibraryImport: Bool

    /// Saved timed exercises, newest-used first — folded into the timed discipline + recents ordering.
    @Query(sort: \TimedExerciseCatalog.lastUsedAt, order: .reverse) private var timed: [TimedExerciseCatalog]

    @State private var query = ""
    /// `nil` ⇒ the "All types" facet.
    @State private var discipline: WorkoutDiscipline?
    @State private var facets = LibraryFacets()
    @State private var showingFilters = false

    private var allItems: [LibraryItem] { resolver.library(timed: timed) }
    private var disciplines: [WorkoutDiscipline] { LibraryBuilder.disciplines(in: allItems) }
    private var results: [LibraryItem] {
        LibraryBuilder.apply(allItems, query: query, discipline: discipline, facets: facets)
    }
    /// Cross-discipline recents — the same pure selector the dashboard's feed uses.
    private var recents: [RecentSessions.Row] { RecentSessions.rows(history: history, unit: unit, limit: 4) }

    var body: some View {
        List {
            disciplineChipBar

            // "Recent across all types" — only on the default (no search, no facet) view so it doesn't
            // fight the filtered results the user is actively narrowing.
            if query.isEmpty && facets.isEmpty && !recents.isEmpty {
                Section("Recent across all types") {
                    ForEach(recents) { row in
                        Button { openSession(row.id) } label: { LibraryRecentRow(row: row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.recent")
                    }
                }
            }

            if !facets.isEmpty {
                Section {
                    Button(role: .destructive) { facets.clear() } label: {
                        Label("Clear \(facets.activeCount) filter\(facets.activeCount == 1 ? "" : "s")",
                              systemImage: "xmark.circle")
                    }
                }
            }

            Section {
                ForEach(results) { item in
                    Button { open(item) } label: { LibraryItemRow(item: item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("exerciseRow")
                }
            } header: {
                Text("\(results.count) \(discipline?.label.lowercased() ?? "item")\(results.count == 1 ? "" : "s")")
            }

            // Download banner — shown only when the opt-in library is not yet installed and
            // the user hasn't filtered/searched (so it doesn't interrupt an active search).
            if query.isEmpty && facets.isEmpty && !ExerciseLibraryStore.shared.isInstalled {
                Section {
                    ExerciseLibraryDownloadBanner(showingImport: $showingLibraryImport)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt)
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty ? "—" : query)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingFilters = true } label: {
                    Label("Filters", systemImage: facets.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                // No facets apply to "All types" → the sheet would be empty; hide the entry.
                .disabled(discipline == nil)
                .accessibilityIdentifier("library.filters")
            }
        }
        .sheet(isPresented: $showingFilters) {
            LibraryFilterSheet(discipline: discipline ?? .strength, facets: $facets)
        }
    }

    private var searchPrompt: String {
        switch discipline {
        case .strength?: return "Search exercises or muscles"
        case .climb?:    return "Search climbs"
        case .run?:      return "Search runs"
        case .timed?:    return "Search timed exercises"
        default:         return "Search the library"
        }
    }

    // MARK: - Discipline chip bar (the top facet)

    private var disciplineChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                disciplineChip(nil, label: "All", symbol: "square.grid.2x2",
                               accent: SnappetColor.workout)
                ForEach(disciplines) { d in
                    disciplineChip(d, label: d.label, symbol: d.symbol, accent: d.accent)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
    }

    private func disciplineChip(_ d: WorkoutDiscipline?, label: String, symbol: String,
                                accent: Color) -> some View {
        let on = discipline == d
        return Button {
            withAnimation(SnappetMotion.quick) {
                discipline = d
                facets.keepOnly(d)   // drop now-irrelevant facets so a stale filter never hides everything
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
        .accessibilityIdentifier("library.chip.\(d?.rawValue ?? "all")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A single library row: discipline glyph (in its accent) + title + subtitle, with a "Custom" badge for
/// user-created exercises. The accent makes the discipline legible at a glance (the wayfinding axis).
struct LibraryItemRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.title3)
                .foregroundStyle(item.discipline.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if item.isCustom {
                Text("Custom")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(item.discipline.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(item.discipline.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A cross-discipline recents row: a discipline accent edge-bar + glyph + the type-adaptive ≤3 facts + an
/// optional PR pill. Mirrors the dashboard's recent-session card (`RecentSessions.Row`), compacted for a List.
private struct LibraryRecentRow: View {
    let row: RecentSessions.Row

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(row.discipline.accent).frame(width: 4, height: 38)
            Image(systemName: row.discipline.symbol)
                .font(.title3).foregroundStyle(row.discipline.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if row.isPR {
                        Text("PR").font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(SnappetColor.brand.opacity(0.16), in: Capsule())
                            .foregroundStyle(SnappetColor.brand)
                    }
                }
                Text(row.facts.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Discipline-adaptive filter sheet (the facet swap)

/// The faceted filter whose facets SWAP by active discipline: strength → muscle + equipment + "no
/// equipment"; climb → style; timed → protocol category; run → terrain. One sheet, one `LibraryFacets`
/// value — the discipline decides which sections render.
private struct LibraryFilterSheet: View {
    let discipline: WorkoutDiscipline
    @Binding var facets: LibraryFacets
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch discipline {
                case .strength:
                    Section { Toggle("No equipment", isOn: $facets.noEquipment)
                        .accessibilityIdentifier("library.facet.noEquipment") }
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
            LibraryFlowChips(items: items, label: label, isOn: isOn, toggle: toggle)
        }
    }
}

/// A wrapping row of selectable chips (the generalized `FlowChips`, now discipline-tint-agnostic — it uses
/// the gym ember as the on-tint since the sheet is already scoped to one discipline).
private struct LibraryFlowChips<T: Identifiable & Hashable>: View {
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
                        .background(on ? SnappetColor.workout.opacity(0.2) : Color(.secondarySystemFill),
                                    in: Capsule())
                        .foregroundStyle(on ? SnappetColor.workout : Color.primary)
                }
                .buttonStyle(.plain)
                .snappetAnimation(SnappetMotion.quick, value: on)
            }
        }
        .padding(.vertical, 4)
    }
}
