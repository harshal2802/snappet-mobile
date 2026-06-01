import SwiftUI
import SwiftData

/// Detail screen for one group: its expenses, per-participant balances, and a greedy
/// settle-up summary. Expenses are fetched for this group only, via a `groupID`
/// predicate captured at init.
struct ExpenseGroupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core

    let group: ExpenseGroup
    @Query private var expenses: [ExpenseRecord]

    @State private var showingNewExpense = false
    @State private var showingSettlement = false
    @State private var showingEditGroup = false
    /// The expense currently being edited via `NewExpenseSheet`, if any.
    @State private var editingExpense: ExpenseRecord?

    init(group: ExpenseGroup) {
        self.group = group
        let groupID = group.id
        _expenses = Query(
            filter: #Predicate<ExpenseRecord> { $0.groupID == groupID },
            sort: \ExpenseRecord.date, order: .reverse
        )
    }

    var body: some View {
        List {
            if expenses.isEmpty {
                emptySection
            } else {
                balanceSection
                settleUpSection
                expenseSection
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingNewExpense = true
                    } label: {
                        Label("Add Expense", systemImage: "plus")
                    }
                    .accessibilityIdentifier("expense.newExpense")

                    Button {
                        showingSettlement = true
                    } label: {
                        Label("Record Settlement", systemImage: "arrow.left.arrow.right")
                    }
                    .accessibilityIdentifier("expense.settle")

                    Button {
                        showingEditGroup = true
                    } label: {
                        Label("Edit Group", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("expense.editGroup")
                } label: {
                    Label("Group Actions", systemImage: "plus")
                }
                .accessibilityIdentifier("expense.groupActions")
            }
        }
        .sheet(isPresented: $showingNewExpense) {
            NewExpenseSheet(group: group)
        }
        .sheet(item: $editingExpense) { expense in
            NewExpenseSheet(group: group, record: expense)
        }
        .sheet(isPresented: $showingSettlement) {
            RecordSettlementSheet(group: group)
        }
        .sheet(isPresented: $showingEditGroup) {
            NewGroupSheet(group: group, usedNames: usedNames)
        }
    }

    /// Participant names referenced as payer or splitter on any record — used to warn
    /// before dropping them when editing the group.
    private var usedNames: Set<String> {
        var names = Set<String>()
        for expense in expenses {
            names.insert(expense.payer)
            names.formUnion(expense.participants)
        }
        return names
    }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: currencyCode))
    }

    // MARK: - Sections

    private var emptySection: some View {
        Section {
            ContentUnavailableView("No expenses yet", systemImage: "creditcard",
                description: Text("Tap + to add the group's first expense."))
                .listRowBackground(Color.clear)
        }
    }

    private var balances: [SettleUp.Balance] {
        SettleUp.balances(participants: group.participants, expenses: expenses)
    }

    private var balanceSection: some View {
        Section("Balances") {
            ForEach(balances) { balance in
                HStack {
                    Text(balance.name)
                    Spacer()
                    Text(currency(balance.net))
                        .foregroundStyle(color(for: balance.net))
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var settleUpSection: some View {
        let transfers = SettleUp.transfers(from: balances)
        Section("Settle Up") {
            if transfers.isEmpty {
                Label("All settled up", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                ForEach(transfers) { transfer in
                    HStack {
                        Text("\(transfer.debtor) owes \(transfer.creditor)")
                        Spacer()
                        Text(currency(transfer.amount))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var expenseSection: some View {
        Section("Expenses") {
            ForEach(expenses) { expense in
                ExpenseRow(expense: expense, currency: currency)
                    .contentShape(Rectangle())
                    .onTapGesture { editingExpense = expense }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingExpense = expense
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                        .accessibilityIdentifier("expense.editExpense")
                    }
            }
            .onDelete(perform: deleteExpenses)
        }
    }

    // MARK: - Helpers

    private func color(for net: Double) -> Color {
        if net > 0.005 { return .green }
        if net < -0.005 { return .red }
        return .secondary
    }

    private func deleteExpenses(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(expenses[index])
        }
        try? modelContext.save()
    }
}

/// A single expense row: title + amount, with payer and split summary beneath.
private struct ExpenseRow: View {
    let expense: ExpenseRecord
    let currency: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if expense.isSettlement {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                Text(expense.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(currency(expense.amount))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(expense.isSettlement ? .green : .primary)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var detail: String {
        if expense.isSettlement {
            let recipient = expense.participants.first ?? "someone"
            return "Settlement · \(expense.payer) paid \(recipient)"
        }
        return "\(expense.payer) paid · split \(expense.participants.count) ways"
    }
}
