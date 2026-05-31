import SwiftUI
import SwiftData

/// Sheet to create a new `ExpenseGroup`: a name plus an editable list of participant
/// names. At least two non-empty participants are required to save.
struct NewGroupSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// Start with two empty slots; users add more rows as needed.
    @State private var participants: [String] = ["", ""]

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    TextField("Name (e.g. Trip, Roommates)", text: $name)
                }

                Section {
                    ForEach(participants.indices, id: \.self) { index in
                        TextField("Participant \(index + 1)", text: $participants[index])
                            .textInputAutocapitalization(.words)
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
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
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
        let group = ExpenseGroup(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            participants: cleanedParticipants
        )
        modelContext.insert(group)
        try? modelContext.save()
        dismiss()
    }
}
