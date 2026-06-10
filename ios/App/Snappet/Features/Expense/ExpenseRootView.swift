import SwiftUI
import SwiftData

/// The Split Expenses root: a list of expense groups with create / delete, drilling
/// into each group's detail. Pushed into the suite's NavigationStack, so it adds no
/// stack of its own.
struct ExpenseRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SuiteRouter.self) private var router
    @Query(sort: \ExpenseGroup.createdAt, order: .reverse) private var groups: [ExpenseGroup]

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
            "Delete \"\(pendingDeleteGroup?.name ?? "\")\"?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                if let g = pendingDeleteGroup { delete(g) }
                pendingDeleteGroup = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteGroup = nil }
        } message: {
            Text("This removes all expenses, itemized receipts, and settlements in the group.")
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

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteGroup != nil },
            set: { if !$0 { pendingDeleteGroup = nil } }
        )
    }

    private func delete(_ group: ExpenseGroup) {
        // Also remove all ExpenseRecords that reference this group by foreign key;
        // the model uses a flat groupID reference rather than a SwiftData relationship,
        // so orphan cleanup is manual.
        let groupID = group.id
        let descriptor = FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { $0.groupID == groupID }
        )
        if let records = try? modelContext.fetch(descriptor) {
            for record in records { modelContext.delete(record) }
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
