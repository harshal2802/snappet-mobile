import SwiftUI
import SwiftData

/// The Split Expenses root: a list of expense groups with create / delete, drilling
/// into each group's detail. Pushed into the suite's NavigationStack, so it adds no
/// stack of its own.
struct ExpenseRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExpenseGroup.createdAt, order: .reverse) private var groups: [ExpenseGroup]

    @State private var showingNewGroup = false

    var body: some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView("No groups yet", systemImage: "person.2",
                    description: Text("Tap + to create a group and start splitting expenses."))
            } else {
                groupList
            }
        }
        .navigationTitle("Split Expenses")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewGroup = true
                } label: {
                    Label("New Group", systemImage: "plus")
                }
            }
        }
        .navigationDestination(for: ExpenseGroup.self) { group in
            ExpenseGroupView(group: group)
        }
        .sheet(isPresented: $showingNewGroup) {
            NewGroupSheet()
        }
    }

    private var groupList: some View {
        List {
            ForEach(groups) { group in
                NavigationLink(value: group) {
                    GroupRow(group: group)
                }
            }
            .onDelete(perform: deleteGroups)
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(groups[index])
        }
        try? modelContext.save()
    }
}

/// A single group row: name plus a participant-count summary.
private struct GroupRow: View {
    let group: ExpenseGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.name)
                .font(.headline)
                .lineLimit(1)
            Text(participantSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var participantSummary: String {
        let count = group.participants.count
        let people = count == 1 ? "person" : "people"
        return "\(count) \(people) · \(group.participants.joined(separator: ", "))"
    }
}
