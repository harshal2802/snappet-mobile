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
    /// The group staged by a context-menu Delete, awaiting the user's confirmation. The
    /// impact message is snapshotted at staging time (a one-off fetch count, not a standing
    /// query over every record) so the dialog copy stays stable through dismissal.
    @State private var pendingDelete: StagedGroupDelete?

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
        // Static title + `presenting:` keeps the dialog copy stable through the dismiss
        // animation (no nil-fallback flash); the group's name rides on the delete button.
        .confirmationDialog(
            "Delete this group?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { staged in
            Button("Delete \u{201C}\(staged.group.name)\u{201D}", role: .destructive) {
                ExpenseGroupDeletion.delete(staged.group, from: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: { staged in
            Text(staged.message)
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func stageDelete(_ group: ExpenseGroup) {
        let count = ExpenseGroupDeletion.recordCount(for: group.id, in: modelContext)
        pendingDelete = StagedGroupDelete(
            group: group,
            message: ExpenseGroupDeleteImpact.message(recordCount: count))
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
                        Button("Delete", role: .destructive) { stageDelete(group) }
                    }
                }
            }
            .padding()
        }
    }

}

/// A group-delete awaiting confirmation: the group plus its impact message, snapshotted
/// when the user asks to delete so the dialog can't drift or flash fallbacks.
private struct StagedGroupDelete {
    let group: ExpenseGroup
    let message: String
}

/// Pure message builder for the group-delete confirmation, kept off the view so the
/// pluralization is unit-testable without a simulator.
enum ExpenseGroupDeleteImpact {
    static func message(recordCount: Int) -> String {
        switch recordCount {
        case 0:
            return "This group has no expenses yet. This can't be undone."
        case 1:
            return "This also permanently deletes its 1 expense, receipt, or settlement. This can't be undone."
        default:
            return "This also permanently deletes its \(recordCount) expenses, receipts, and settlements. This can't be undone."
        }
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
