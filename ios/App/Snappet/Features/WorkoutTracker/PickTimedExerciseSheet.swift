import SwiftUI
import SwiftData

/// The timed exercise the sheet hands back, used to build a named `.duration` `SessionExercise`.
struct AddTimedParams {
    let name: String
    let category: TimedExerciseCategory
    let spec: TimedExerciseSpec
    /// The persisted catalog row, when the pick came from (or was saved to) "my exercises" — so the
    /// player can stamp its `lastUsedAt` for the recents ordering. `nil` for an unsaved one-off / suggestion.
    let catalogID: UUID?
}

/// The **"Pick or create a timed exercise"** sheet (Quick Session redesign Phase 5): the timed analogue of
/// `AddClimbSheet`'s climb-first entry point. Tapping **Timed** opens this instead of dropping a bare,
/// unnamed `.duration` row — a searchable catalog with **"Create new"** pinned top, the user's saved
/// exercises as **recents** + **category groups**, then seeded **suggestions** (7 s max hang, dead hang,
/// plank, wall sit, repeaters, tabata). Selecting a row drops a NAMED timed card whose sets log underneath.
///
/// **Create-new** (`timed.create.*`) captures NAME + category + STRUCTURE (segmented modes) with
/// protocol-preset chips that PRE-FILL (never snap an edited value back — the Tindeq antipattern), a live
/// "Total …" readout, and a "Save to my exercises" toggle that persists a `TimedExerciseCatalog`. A search
/// that finds nothing offers an inline "Create '<query>'".
///
/// iOS-26 / XCUITest discipline (mirrors `AddClimbSheet`): one `accessibilityIdentifier` per interactive
/// leaf — the search field, each pick/suggestion row, the create-new button, the structure picker, each
/// preset chip, the name/category fields, the save toggle, and both CTAs carry their own id.
struct PickTimedExerciseSheet: View {
    /// Hand back the chosen timed exercise; the player builds the named `.duration` card.
    let onPick: (AddTimedParams) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// The user's saved timed exercises, newest-used first — drives recents + the category groups.
    @Query(sort: \TimedExerciseCatalog.lastUsedAt, order: .reverse) private var saved: [TimedExerciseCatalog]

    @State private var search = ""
    @State private var creating = false
    /// Routines, to find copies of a preset being edited (prompt 140).
    @Query private var routines: [Routine]
    @State private var editingPreset: TimedExerciseCatalog?
    /// Set when a saved preset edit has routine copies to offer — promoted to the dialog on sheet dismiss.
    @State private var pendingCopies: PresetCopyUpdate?
    @State private var copiesPrompt: PresetCopyUpdate?

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Saved exercises matching the search (name contains, case-insensitive).
    private var matchingSaved: [TimedExerciseCatalog] {
        guard !trimmedSearch.isEmpty else { return saved }
        return saved.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    /// Seeded suggestions matching the search, with any that duplicate a saved name dropped.
    private var matchingSuggestions: [TimedExerciseCatalog.Suggestion] {
        let savedNames = Set(saved.map { $0.name.lowercased() })
        return TimedExerciseCatalog.suggestions.filter { s in
            !savedNames.contains(s.name.lowercased())
                && (trimmedSearch.isEmpty || s.name.localizedCaseInsensitiveContains(trimmedSearch))
        }
    }

    /// The most-recently-used saved exercises (those with a `lastUsedAt`), capped — the warm path.
    private var recents: [TimedExerciseCatalog] {
        Array(matchingSaved.filter { $0.lastUsedAt != nil }.prefix(5))
    }

    var body: some View {
        NavigationStack {
            if creating {
                CreateTimedExerciseForm(initialName: trimmedSearch) { params in
                    onPick(params)
                    dismiss()
                }
            } else {
                pickList
            }
        }
    }

    private var pickList: some View {
        List {
            Section {
                Button {
                    creating = true
                } label: {
                    Label("Create new timed exercise", systemImage: "plus.circle.fill")
                        .foregroundStyle(SnappetColor.workout)
                }
                .accessibilityIdentifier("timed.createNew")
            }

            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents) { item in savedRow(item) }
                }
            }

            // Category groups of the rest of the saved exercises (recents excluded so they don't repeat).
            let recentIDs = Set(recents.map(\.id))
            ForEach(TimedExerciseCategory.allCases) { category in
                let inCat = matchingSaved.filter { $0.category == category && !recentIDs.contains($0.id) }
                if !inCat.isEmpty {
                    Section(category.display) {
                        ForEach(inCat) { item in savedRow(item) }
                    }
                }
            }

            if !matchingSuggestions.isEmpty {
                Section("Suggestions") {
                    ForEach(matchingSuggestions) { suggestion in suggestionRow(suggestion) }
                }
            }

            // No saved match AND a query typed → offer to create it by that name inline.
            if matchingSaved.isEmpty && !trimmedSearch.isEmpty {
                Section {
                    Button {
                        creating = true
                    } label: {
                        Label("Create \"\(trimmedSearch)\"", systemImage: "plus")
                    }
                    .accessibilityIdentifier("timed.createFromSearch")
                }
            }
        }
        .sheet(item: $editingPreset, onDismiss: {
            if let p = pendingCopies { pendingCopies = nil; copiesPrompt = p }
        }) { item in
            ProtocolEditorSheet(title: "Edit preset",
                                initial: ProtocolDraft(name: item.name, category: item.category,
                                                       spec: item.spec ?? TimedExerciseSpec(mode: .openCountUp))) { draft in
                savePreset(item, draft)
            }
        }
        .confirmationDialog("Update routines too?",
                            isPresented: Binding(get: { copiesPrompt != nil }, set: { if !$0 { copiesPrompt = nil } }),
                            titleVisibility: .visible, presenting: copiesPrompt) { update in
            Button("Update \(update.routineNames.count == 1 ? "the routine" : "\(update.routineNames.count) routines")") {
                applyCopies(update)
            }
            .accessibilityIdentifier("preset.updateRoutines")
            Button("Only the preset", role: .cancel) {}
        } message: { update in
            Text("\(update.routineNames.joined(separator: ", ")) \(update.routineNames.count == 1 ? "uses" : "use") a copy of it. Routines you've changed since are left alone.")
        }
        .searchable(text: $search, prompt: "Search timed exercises")
        .navigationTitle("Timed exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func savedRow(_ item: TimedExerciseCatalog) -> some View {
        Button {
            item.lastUsedAt = .now
            try? context.save()
            onPick(AddTimedParams(name: item.name, category: item.category,
                                  spec: item.spec ?? TimedExerciseSpec(mode: .openCountUp),
                                  catalogID: item.id))
            dismiss()
        } label: {
            timedRowLabel(name: item.name, category: item.category, spec: item.spec)
        }
        .accessibilityIdentifier("timed.pick.\(item.id.uuidString)")
        .swipeActions(edge: .trailing) {
            Button { editingPreset = item } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                .tint(SnappetColor.workout)
        }
        .contextMenu {
            Button { editingPreset = item } label: { Label("Edit preset", systemImage: "slider.horizontal.3") }
        }
    }

    /// Save an edited preset; if routines hold unchanged copies of the old version, offer to update them.
    private func savePreset(_ item: TimedExerciseCatalog, _ draft: ProtocolDraft) {
        let oldSpec = item.spec ?? TimedExerciseSpec(mode: .openCountUp)
        item.name = draft.resolvedName
        item.category = draft.category
        item.spec = draft.spec
        try? context.save()
        guard draft.spec != oldSpec else { return }
        let hits = routines.compactMap { r -> (Routine, [Int])? in
            let idx = ProtocolCopies.matchingBlockIndices(in: r.exercises, presetID: item.id, oldSpec: oldSpec)
            return idx.isEmpty ? nil : (r, idx)
        }
        guard !hits.isEmpty else { return }
        pendingCopies = PresetCopyUpdate(routineIDs: hits.map { $0.0.id }, routineNames: hits.map { $0.0.name },
                                         presetID: item.id, oldSpec: oldSpec, newSpec: draft.spec)
    }

    private func applyCopies(_ update: PresetCopyUpdate) {
        for routine in routines where update.routineIDs.contains(routine.id) {
            var blocks = routine.exercises
            for i in ProtocolCopies.matchingBlockIndices(in: blocks, presetID: update.presetID, oldSpec: update.oldSpec) {
                blocks[i].timedSpec = update.newSpec
                blocks[i].sets = 1
            }
            routine.exercises = blocks
            routine.updatedAt = .now
        }
        try? context.save()
    }

    private func suggestionRow(_ suggestion: TimedExerciseCatalog.Suggestion) -> some View {
        Button {
            // A picked suggestion drops a named card but is NOT persisted (the user didn't ask to save
            // it); "Save to my exercises" in the create flow is how a suggestion graduates into a row.
            onPick(AddTimedParams(name: suggestion.name, category: suggestion.category,
                                  spec: suggestion.spec, catalogID: nil))
            dismiss()
        } label: {
            timedRowLabel(name: suggestion.name, category: suggestion.category, spec: suggestion.spec)
        }
        .accessibilityIdentifier("timed.suggested.\(suggestion.key)")
    }

    /// A pick row: category glyph · name · the spec's one-line structure summary.
    private func timedRowLabel(name: String, category: TimedExerciseCategory,
                               spec: TimedExerciseSpec?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol)
                .foregroundStyle(SnappetColor.workout)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text((spec ?? TimedExerciseSpec(mode: .openCountUp)).summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// The **create-new** sub-form (`timed.create.*`): the shared protocol editor (prompt 140 — presets incl.
/// the hangboard protocols, every field editable incl. rest between sets and the get-ready countdown, a
/// plain-English summary) + a "Save to my exercises" toggle and the Add CTA.
private struct CreateTimedExerciseForm: View {
    let onCreate: (AddTimedParams) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var draft: ProtocolDraft
    @State private var saveToCatalog = true

    init(initialName: String, onCreate: @escaping (AddTimedParams) -> Void) {
        self.onCreate = onCreate
        var initial = ProtocolDraft(name: initialName, category: .hangboard, spec: .hold(30))
        initial.restBetweenSetsSec = 180   // the old fixed value, now just the starting point
        _draft = State(initialValue: initial)
    }

    var body: some View {
        Form {
            ProtocolEditorSections(draft: $draft)
            Section {
                Toggle("Save to my exercises", isOn: $saveToCatalog)
                    .accessibilityIdentifier("timed.create.save")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ProtocolSummaryBar(spec: draft.spec) }
        // Pinned, so the primary action stays visible above the (now longer) editor — the AddClimbSheet rule.
        .safeAreaInset(edge: .bottom) {
            Button {
                commit()
            } label: {
                Text("Add to session").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
            .accessibilityIdentifier("timed.create.add")
        }
        .navigationTitle("New timed exercise")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func commit() {
        let resolved = draft.spec
        var catalogID: UUID?
        if saveToCatalog {
            let item = TimedExerciseCatalog(name: draft.resolvedName, category: draft.category,
                                            spec: resolved, lastUsedAt: .now)
            context.insert(item)
            try? context.save()
            catalogID = item.id
        }
        onCreate(AddTimedParams(name: draft.resolvedName, category: draft.category, spec: resolved,
                                catalogID: catalogID))
        dismiss()
    }
}

/// A pending "Update routines too?" offer after a preset edit (prompt 140).
struct PresetCopyUpdate: Identifiable {
    let id = UUID()
    let routineIDs: [UUID]
    let routineNames: [String]
    let presetID: UUID
    let oldSpec: TimedExerciseSpec
    let newSpec: TimedExerciseSpec
}
