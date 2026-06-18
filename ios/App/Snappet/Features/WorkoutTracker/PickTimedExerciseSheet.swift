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

/// The **create-new** sub-form (`timed.create.*`): NAME + category + STRUCTURE (segmented modes) with
/// protocol-preset chips that PRE-FILL, a live "Total …" readout, and a "Save to my exercises" toggle.
private struct CreateTimedExerciseForm: View {
    let onCreate: (AddTimedParams) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name: String
    @State private var category: TimedExerciseCategory = .hangboard
    @State private var mode: TimedExerciseSpec.Mode = .countDown
    @State private var workSec = 30
    @State private var restSec = 0
    @State private var reps = 1
    @State private var sets = 1
    @State private var saveToCatalog = true

    init(initialName: String, onCreate: @escaping (AddTimedParams) -> Void) {
        self.onCreate = onCreate
        _name = State(initialValue: initialName)
    }

    /// The structure being authored — built from the current fields. Open count-up has no parameters.
    private var spec: TimedExerciseSpec {
        if mode == .openCountUp { return TimedExerciseSpec(mode: .openCountUp) }
        return TimedExerciseSpec(mode: mode, workSec: workSec, restSec: restSec,
                                 reps: reps, sets: sets,
                                 restBetweenSetsSec: mode.isStructured ? 180 : 0)
    }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? mode.label : trimmed
    }

    var body: some View {
        Form {
            nameSection
            categorySection
            structureSection
            presetSection
            totalSection
            saveSection
            ctaSection
        }
        .navigationTitle("New timed exercise")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var nameSection: some View {
        Section("Name") {
            TextField(mode.label, text: $name)
                .submitLabel(.done)
                .accessibilityIdentifier("timed.create.name")
        }
    }

    private var categorySection: some View {
        Section("Category") {
            Picker("Category", selection: $category) {
                ForEach(TimedExerciseCategory.allCases) { Text($0.display).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("timed.create.category")
        }
    }

    private var structureSection: some View {
        Section("Structure") {
            Picker("Structure", selection: $mode) {
                ForEach(TimedExerciseSpec.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("timed.create.mode")

            // Per-mode parameters: a single hold for count-down/max-hang, work/rest/reps/sets for the
            // structured protocols, nothing for open count-up. Custom +/- steppers so each control has its
            // own queryable id (the leaf-only a11y rule), mirroring the freeform QuickAddRow steppers.
            switch mode {
            case .openCountUp:
                Text("Times an open-ended hold — no target.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .maxHang, .countDown:
                stepperRow("Hold", id: "timed.create.work",
                           value: "\(workSec)s",
                           dec: { workSec = max(1, workSec - 5) }, inc: { workSec = min(600, workSec + 5) })
            case .repeaters, .tabata:
                stepperRow("Work", id: "timed.create.work", value: "\(workSec)s",
                           dec: { workSec = max(1, workSec - 1) }, inc: { workSec = min(600, workSec + 1) })
                stepperRow("Rest", id: "timed.create.rest", value: "\(restSec)s",
                           dec: { restSec = max(0, restSec - 1) }, inc: { restSec = min(600, restSec + 1) })
                stepperRow("Reps", id: "timed.create.reps", value: "\(reps)",
                           dec: { reps = max(1, reps - 1) }, inc: { reps = min(50, reps + 1) })
                stepperRow("Sets", id: "timed.create.sets", value: "\(sets)",
                           dec: { sets = max(1, sets - 1) }, inc: { sets = min(20, sets + 1) })
            case .emom:
                stepperRow("Rounds", id: "timed.create.reps", value: "\(reps) min",
                           dec: { reps = max(1, reps - 1) }, inc: { reps = min(60, reps + 1) })
            }
        }
    }

    /// Protocol-preset chips that PRE-FILL the structure (mode + all parameters). They NEVER lock the
    /// spec — a value the user then edits is kept; presets are a convenience starting point only.
    private var presetSection: some View {
        Section("Presets") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetChip("7:3 × 6", key: "repeaters") { apply(.repeaters7x3x6) }
                    presetChip("10s hang", key: "maxhang") { apply(.maxHang10) }
                    presetChip("Tabata", key: "tabata") { apply(.tabata) }
                    presetChip("EMOM", key: "emom") { apply(.emom) }
                    presetChip("Plank 60s", key: "plank") { apply(.hold(60)) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var totalSection: some View {
        Section {
            HStack {
                Text("Total").font(.subheadline.weight(.medium))
                Spacer()
                Text(totalLabel)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SnappetColor.workout)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("timed.create.total")
            }
        }
    }

    private var saveSection: some View {
        Section {
            Toggle("Save to my exercises", isOn: $saveToCatalog)
                .accessibilityIdentifier("timed.create.save")
        }
    }

    private var ctaSection: some View {
        Section {
            Button {
                commit()
            } label: {
                Text("Add to session").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .accessibilityIdentifier("timed.create.add")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Pieces

    private var totalLabel: String {
        if let total = spec.totalSeconds { return SetMeasure.formatDuration(Double(total)) }
        return "Open count up"
    }

    private func presetChip(_ text: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(SnappetColor.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timed.create.preset.\(key)")
    }

    private func stepperRow(_ label: String, id: String, value: String,
                            dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: dec) { Image(systemName: "minus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(id).minus")
                .accessibilityLabel("Decrease \(label.lowercased())")
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 70)
                .accessibilityIdentifier(id)
            Button(action: inc) { Image(systemName: "plus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(id).plus")
                .accessibilityLabel("Increase \(label.lowercased())")
        }
    }

    /// Pre-fill the form from a preset (mode + all parameters). The user can edit any of it afterwards.
    private func apply(_ preset: TimedExerciseSpec) {
        mode = preset.mode
        workSec = max(1, preset.workSec)
        restSec = preset.restSec
        reps = preset.reps
        sets = preset.sets
    }

    private func commit() {
        let resolved = spec
        var catalogID: UUID?
        if saveToCatalog {
            let item = TimedExerciseCatalog(name: resolvedName, category: category,
                                            spec: resolved, lastUsedAt: .now)
            context.insert(item)
            try? context.save()
            catalogID = item.id
        }
        onCreate(AddTimedParams(name: resolvedName, category: category, spec: resolved, catalogID: catalogID))
        dismiss()
    }
}
