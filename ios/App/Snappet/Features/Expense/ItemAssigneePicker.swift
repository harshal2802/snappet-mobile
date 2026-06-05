import SwiftUI

/// Pushed picker for choosing which participants share one receipt item. Edits the item's
/// `assignees` in place via a binding; offers quick "Everyone" / "No one" actions. Order
/// follows the group's participant order so the stored list stays stable.
struct ItemAssigneePicker: View {
    let itemName: String
    let participants: [String]
    @Binding var assignees: [String]

    private var chosen: Set<String> { Set(assignees) }

    var body: some View {
        Form {
            Section {
                Button("Everyone") { assignees = participants }
                    .accessibilityIdentifier("receipt.assign.everyone")
                Button("No one") { assignees = [] }
                    .accessibilityIdentifier("receipt.assign.none")
            }

            Section("Shared by") {
                ForEach(participants, id: \.self) { person in
                    Button {
                        toggle(person)
                    } label: {
                        HStack {
                            Text(person).foregroundStyle(.primary)
                            Spacer()
                            if chosen.contains(person) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityIdentifier("receipt.assign.\(person)")
                }
            }
        }
        .navigationTitle(itemName.isEmpty ? "Split item" : itemName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ person: String) {
        var set = chosen
        if set.contains(person) { set.remove(person) } else { set.insert(person) }
        // Preserve group order for a stable stored list.
        assignees = participants.filter { set.contains($0) }
    }
}

/// Short, human label for an item's assignees relative to the group.
enum AssigneeSummary {
    static func label(_ assignees: [String], in participants: [String]) -> String {
        if assignees.isEmpty { return "Unassigned" }
        if assignees.count == participants.count { return "Everyone" }
        if assignees.count <= 2 { return assignees.joined(separator: " & ") }
        return "\(assignees.count) people"
    }
}
