import SwiftUI
import SwiftData

/// The Split Expenses root: a list of expense groups with create / delete, drilling
/// into each group's detail. Pushed into the suite's NavigationStack, so it adds no
/// stack of its own.
struct ExpenseRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SuiteRouter.self) private var router
    @Query(sort: \ExpenseGroup.createdAt, order: .reverse) private var groups: [ExpenseGroup]
    @Query private var allRecords: [ExpenseRecord]

    @State private var showingNewGroup = false
    @State private var pendingDeleteGroup: ExpenseGroup?

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
                .accessibilityIdentifier("expense.newGroup")
            }
        }
        .navigationDestination(for: ExpenseGroup.self) { group in
            ExpenseGroupView(group: group)
        }
        .sheet(isPresented: $showingNewGroup) {
            NewGroupSheet()
        }
        .confirmationDialog(
            "Delete this group?",
            isPresented: Binding(
                get: { pendingDeleteGroup != nil },
                set: { if !$0 { pendingDeleteGroup = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let group = pendingDeleteGroup { delete(group) }
                pendingDeleteGroup = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteGroup = nil }
        } message: {
            if let group = pendingDeleteGroup {
                let count = allRecords.filter { $0.groupID == group.id }.count
                Text("This removes the group and \(count) expense\(count == 1 ? "" : "s") inside it.")
            }
        }
    }

    // A ScrollView + VStack of Buttons (not a List) — the suite's proven XCUITest-tappable
    // navigation pattern (matches AppLibraryView). A Button inside a `List` row does not reliably
    // fire its action under XCUITest in this app (see decisions.md). Delete moves to a context menu.
    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(groups) { group in
                    Button { router.push(group) } label: {
                        GroupRow(group: group)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("expenseGroupRow")
                    .contextMenu {
                        Button("Delete", role: .destructive) { pendingDeleteGroup = group }
                    }
                }
            }
            .padding()
        }
    }

    private func delete(_ group: ExpenseGroup) {
        for record in allRecords where record.groupID == group.id {
            modelContext.delete(record)
        }
        modelContext.delete(group)
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
