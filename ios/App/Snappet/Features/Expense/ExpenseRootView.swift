import SwiftUI
import SwiftData

/// The Split Expenses root: a list of expense groups with create / delete, drilling
/// into each group's detail. Pushed into the suite's NavigationStack, so it adds no
/// stack of its own.
struct ExpenseRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SuiteRouter.self) private var router
    @Query(sort: \ExpenseGroup.createdAt, order: .reverse) private var groups: [ExpenseGroup]
    /// All expense rows, fetched here so group deletion can report and clean up the rows
    /// keyed to the group — `ExpenseRecord.groupID` is a flat reference (see
    /// `ExpenseModels.swift`), so nothing cascades on its own.
    @Query private var records: [ExpenseRecord]

    @State private var showingNewGroup = false
    /// The group staged by a context-menu Delete, awaiting the user's confirmation.
    @State private var pendingDelete: ExpenseGroup?

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
            "Delete \u{201C}\(pendingDelete?.name ?? "")\u{201D}?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let group = pendingDelete { delete(group) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(ExpenseGroupDeleteImpact.message(
                recordCount: pendingDelete.map(recordCount(in:)) ?? 0))
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func recordCount(in group: ExpenseGroup) -> Int {
        records.count { $0.groupID == group.id }
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
                        Button("Delete", role: .destructive) { pendingDelete = group }
                    }
                }
            }
            .padding()
        }
    }

    /// Deletes the group **and** every expense row keyed to it — without the explicit
    /// sweep the flat `groupID` reference would leave the rows orphaned and unreachable.
    private func delete(_ group: ExpenseGroup) {
        for record in records where record.groupID == group.id {
            modelContext.delete(record)
        }
        modelContext.delete(group)
        try? modelContext.save()
    }
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
