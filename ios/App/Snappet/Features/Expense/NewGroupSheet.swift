import SwiftUI
import SwiftData

/// Sheet to create — or edit — an `ExpenseGroup`: a name plus an editable list of
/// participant names. At least two non-empty participants are required to save. When an
/// existing `group` is passed the form is pre-filled and saving updates it in place;
/// dropping a participant who still appears on a record warns before committing.
struct NewGroupSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The group being edited, or `nil` when creating a new one.
    let group: ExpenseGroup?
    /// Names referenced by existing records (payer/split); dropping one warns first.
    private let usedNames: Set<String>

    @State private var name: String
    @State private var participants: [String]
    @State private var showingDropWarning = false

    init(group: ExpenseGroup? = nil, usedNames: Set<String> = []) {
        self.group = group
        self.usedNames = usedNames
        _name = State(initialValue: group?.name ?? "")
        // Editing: pre-fill existing names. Creating: two empty slots to fill in.
        _participants = State(initialValue: group?.participants ?? ["", ""])
    }

    private var isEditing: Bool { group != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    TextField("Name (e.g. Trip, Roommates)", text: $name)
                        .accessibilityIdentifier("expense.group.name")
                }

                Section {
                    ForEach(participants.indices, id: \.self) { index in
                        TextField("Participant \(index + 1)", text: $participants[index])
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier("expense.group.participant.\(index)")
                    }
                    .onDelete(perform: deleteParticipant)

                    Button {
                        participants.append("")
                    } label: {
                        Label("Add Participant", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Participants")
                } footer: {
                    Text("Add at least two people to split expenses between.")
                }
            }
            .navigationTitle(isEditing ? "Edit Group" : "New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("expense.group.save")
                }
            }
            .alert("Remove participants?", isPresented: $showingDropWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Remove anyway", role: .destructive) { save() }
            } message: {
                Text(droppedWarningMessage)
            }
        }
    }

    /// Names that exist on records but are no longer in the edited participant list.
    private var droppedUsedNames: [String] {
        let kept = Set(cleanedParticipants)
        return usedNames.filter { !kept.contains($0) }.sorted()
    }

    private var droppedWarningMessage: String {
        let names = droppedUsedNames.joined(separator: ", ")
        return "\(names) still appear on existing expenses. Their past entries stay, but they won't be selectable for new ones."
    }

    private func attemptSave() {
        guard canSave else { return }
        if isEditing && !droppedUsedNames.isEmpty {
            showingDropWarning = true
        } else {
            save()
        }
    }

    /// Trimmed, de-duplicated, non-empty participant names.
    private var cleanedParticipants: [String] {
        var seen = Set<String>()
        return participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cleanedParticipants.count >= 2
    }

    private func deleteParticipant(at offsets: IndexSet) {
        participants.remove(atOffsets: offsets)
    }

    private func save() {
        guard canSave else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let group {
            group.name = trimmedName
            group.participants = cleanedParticipants
        } else {
            let newGroup = ExpenseGroup(
                name: trimmedName,
                participants: cleanedParticipants
            )
            modelContext.insert(newGroup)
        }
        try? modelContext.save()
        dismiss()
    }
}
