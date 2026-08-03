import SwiftUI
import SwiftData

// The ONE dropdown used by every field that has one (wardrobe prompt 05) — "allow a way to add
// custom value in all the fields which have dropdown and also update same value in related
// dropdown for future". Built once so brand, size, material, colour, category, pattern and style
// can't drift apart in behavior.

/// A field's picker: the user's own values (most used first), the built-ins, and "Add new…".
struct WardrobeValuePicker: View {
    let field: WardrobeVocabularyRules.Field
    /// The current value as stored: a built-in raw ("yellow") or a custom display string ("Mustard").
    @Binding var value: String
    /// The built-in this value scores as; empty when `value` is itself a built-in. Unused for
    /// free-text fields.
    @Binding var mapsToRaw: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var showAddNew = false

    private var choices: [WardrobeVocabularyRules.Choice] {
        let all = WardrobeVocabularyStore.choices(for: field, in: modelContext)
        let query = WardrobeVocabularyRules.normalize(search)
        guard !query.isEmpty else { return all }
        return all.filter { $0.value.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choices) { choice in
                        Button {
                            select(choice)
                        } label: {
                            HStack {
                                Text(choice.value)
                                    .foregroundStyle(SnappetColor.ink)
                                if !choice.isBuiltIn, choice.useCount > 0 {
                                    Text("\(choice.useCount)")
                                        .font(.caption2)
                                        .foregroundStyle(SnappetColor.textSecondary)
                                }
                                Spacer()
                                if isSelected(choice) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(SnappetColor.wardrobe)
                                }
                            }
                        }
                        .accessibilityIdentifier("wardrobe.picker.row")
                    }
                } header: {
                    Text(choices.isEmpty ? "No matches" : "Yours, most used first")
                }

                Section {
                    Button {
                        showAddNew = true
                    } label: {
                        Label("Add a new \(field.title.lowercased())…", systemImage: "plus")
                            .foregroundStyle(SnappetColor.wardrobe)
                    }
                    .accessibilityIdentifier("wardrobe.picker.addNew")
                } footer: {
                    Text("New values are remembered and appear here next time.")
                }
            }
            .searchable(text: $search, prompt: "Search \(field.title.lowercased())")
            .navigationTitle(field.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .sheet(isPresented: $showAddNew) {
            WardrobeAddValueSheet(field: field) { newValue, newMap in
                WardrobeVocabularyStore.remember(newValue, field: field,
                                                 mapsToRaw: newMap, in: modelContext)
                value = newValue
                mapsToRaw = newMap
                showAddNew = false
                dismiss()
            }
        }
    }

    private func isSelected(_ choice: WardrobeVocabularyRules.Choice) -> Bool {
        // A built-in row is selected when the stored raw matches it; a custom row when the
        // display strings match.
        choice.isBuiltIn ? value == choice.mapsToRaw
                         : WardrobeVocabularyRules.isSameValue(value, choice.value)
    }

    private func select(_ choice: WardrobeVocabularyRules.Choice) {
        if choice.isBuiltIn {
            value = choice.mapsToRaw     // built-ins store their raw
            mapsToRaw = ""               // and never carry a map
        } else {
            value = choice.value
            mapsToRaw = choice.mapsToRaw
            WardrobeVocabularyStore.remember(choice.value, field: field,
                                             mapsToRaw: choice.mapsToRaw, in: modelContext)
        }
        dismiss()
    }
}

/// Naming a new value — and, for a scored field, saying what it behaves like.
struct WardrobeAddValueSheet: View {
    let field: WardrobeVocabularyRules.Field
    var onAdd: (String, String) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var mapsToRaw = ""

    private var rejection: String? {
        WardrobeVocabularyRules.rejectionReason(
            for: text, field: field,
            existing: WardrobeVocabularyStore.existingValues(for: field, in: modelContext))
    }

    private var canAdd: Bool {
        rejection == nil && (!field.needsMapping || !mapsToRaw.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New \(field.title.lowercased())") {
                    TextField(field.title, text: $text)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("wardrobe.addValue.name")
                    if let rejection, !text.isEmpty {
                        Text(rejection).font(.caption).foregroundStyle(.red)
                    }
                }

                if field.needsMapping {
                    Section {
                        behavesLikeChips
                    } header: {
                        Text("Behaves like")
                    } footer: {
                        // The honest reason this question exists at all.
                        Text("Outfit suggestions score \(field.title.lowercased())s against each "
                             + "other. Pick the closest built-in once and your new value works "
                             + "everywhere that one does.")
                    }
                }

                Section {
                    Button {
                        onAdd(WardrobeVocabularyRules.normalize(text), mapsToRaw)
                    } label: {
                        Text("Add \(field.title.lowercased())")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SnappetColor.brand)
                    .disabled(!canAdd)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("wardrobe.addValue.confirm")
                }
            }
            .navigationTitle("Add \(field.title.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private var behavesLikeChips: some View {
        let options = WardrobeVocabularyStore.builtInTitles(for: field)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 7)], spacing: 7) {
            ForEach(options, id: \.raw) { option in
                Button {
                    mapsToRaw = option.raw
                } label: {
                    Text(option.title)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(mapsToRaw == option.raw ? SnappetColor.wardrobe
                                                            : SnappetColor.surfaceMuted,
                                    in: Capsule())
                        .foregroundStyle(mapsToRaw == option.raw ? .white
                                                                 : SnappetColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The row a form shows for a picker-backed field: label, current value, chevron.
struct WardrobeValueRow: View {
    let field: WardrobeVocabularyRules.Field
    @Binding var value: String
    @Binding var mapsToRaw: String
    /// What to show when `value` is a built-in raw (so the row reads "Yellow", not "yellow").
    var display: String?

    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Text(field.title).foregroundStyle(SnappetColor.ink)
                Spacer()
                Text(shown.isEmpty ? "Add" : shown)
                    .foregroundStyle(shown.isEmpty ? SnappetColor.textSecondary
                                                   : SnappetColor.wardrobe)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            WardrobeValuePicker(field: field, value: $value, mapsToRaw: $mapsToRaw)
        }
    }

    private var shown: String {
        if let display, !display.isEmpty { return display }
        return value
    }
}
