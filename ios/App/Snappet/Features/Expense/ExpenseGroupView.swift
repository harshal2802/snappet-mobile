import SwiftUI
import SwiftData

/// Detail screen for one group: its expenses, per-participant balances, and a greedy
/// settle-up summary. Expenses are fetched for this group only, via a `groupID`
/// predicate captured at init.
struct ExpenseGroupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Environment(SuiteRouter.self) private var router

    let group: ExpenseGroup
    @Query private var expenses: [ExpenseRecord]

    @State private var showingNewExpense = false
    @State private var showingNewReceipt = false
    @State private var showingSettlement = false
    @State private var showingEditGroup = false
    /// The expense currently being edited via `NewExpenseSheet`, if any.
    @State private var editingExpense: ExpenseRecord?
    /// A settle-up transfer the user tapped — opens `RecordSettlementSheet` prefilled
    /// with payer/recipient/amount so recording it is two taps (issue #82).
    @State private var prefilledSettlement: SettleUp.Transfer?
    /// Who the user is, remembered across groups — balances and settle-up rows read in
    /// the second person ("You owe Bob") when set. Stored by `NewGroupSheet` on save.
    @AppStorage("expense.myName") private var myName = ""

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
            // The dominant action gets its own one-tap button (issue #82); the rarer
            // actions live behind the ellipsis menu.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewExpense = true
                } label: {
                    Label("Add Expense", systemImage: "plus")
                }
                .accessibilityIdentifier("expense.newExpense")
            }
            // .topBarTrailing, NOT .secondaryAction — secondary items collapse behind a
            // system "More" button, hiding this menu (and its identifier) from the bar.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingNewReceipt = true
                    } label: {
                        Label("Add Receipt", systemImage: "doc.text.viewfinder")
                    }
                    .accessibilityIdentifier("expense.newReceipt")

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
                    Label("Group Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("expense.groupActions")
            }
        }
        .navigationDestination(for: ExpenseRecord.self) { record in
            ReceiptDetailView(group: group, record: record)
        }
        .sheet(isPresented: $showingNewExpense) {
            NewExpenseSheet(group: group)
        }
        .sheet(isPresented: $showingNewReceipt) {
            NewReceiptSheet(group: group)
        }
        .sheet(item: $editingExpense) { expense in
            NewExpenseSheet(group: group, record: expense)
        }
        .sheet(isPresented: $showingSettlement) {
            RecordSettlementSheet(group: group)
        }
        .sheet(item: $prefilledSettlement) { transfer in
            RecordSettlementSheet(group: group, payer: transfer.debtor,
                                  recipient: transfer.creditor, amount: transfer.amount)
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
                    // The user's own row says the direction in words ("You are owed") —
                    // the issue's headline ask; others keep the signed, colored amount.
                    Text(SettleUp.balanceRowLabel(name: balance.name, net: balance.net,
                                                  me: myName.isEmpty ? nil : myName))
                    Spacer()
                    Text(currency(balance.net))
                        .foregroundStyle(color(for: balance.net))
                        .monospacedDigit()
                        // Balances animate toward their new value (and toward zero on
                        // settle-up) rather than snapping (issue #30 §5.8).
                        .contentTransition(.numericText())
                        .animation(.snappy, value: balance.net)
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
                    .foregroundStyle(SnappetColor.habits)
            } else {
                ForEach(transfers) { transfer in
                    // Tapping a computed transfer records it with the exact amount
                    // prefilled — it used to mean re-typing the number on screen.
                    Button {
                        prefilledSettlement = transfer
                    } label: {
                        HStack {
                            Text(SettleUp.transferLabel(debtor: transfer.debtor,
                                                        creditor: transfer.creditor,
                                                        me: myName.isEmpty ? nil : myName))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(currency(transfer.amount))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("expense.transfer.\(transfer.debtor).\(transfer.creditor)")
                }
            }
        }
    }

    private var expenseSection: some View {
        Section("Expenses") {
            ForEach(expenses) { expense in
                ExpenseRow(expense: expense, currency: currency)
                    .contentShape(Rectangle())
                    .onTapGesture { open(expense) }
                    .swipeActions(edge: .leading) {
                        // Settlements have no detail/editor (open() is a no-op for them), so don't
                        // offer a swipe action that would do nothing.
                        if !expense.isSettlement {
                            Button {
                                open(expense)
                            } label: {
                                Label(expense.isReceipt ? "View" : "Edit",
                                      systemImage: expense.isReceipt ? "list.bullet.rectangle" : "pencil")
                            }
                            .tint(.blue)
                            .accessibilityIdentifier("expense.editExpense")
                        }
                    }
            }
            .onDelete(perform: deleteExpenses)
        }
    }

    /// Tapping a receipt opens its per-person breakdown; an even-split expense opens the
    /// edit sheet directly. (Settlements have no editor — tap is a no-op for them.)
    private func open(_ expense: ExpenseRecord) {
        if expense.isReceipt {
            router.push(expense)
        } else if !expense.isSettlement {
            editingExpense = expense
        }
    }

    // MARK: - Helpers

    private func color(for net: Double) -> Color {
        if net > 0.005 { return SnappetColor.habits }
        if net < -0.005 { return SnappetColor.pomodoro }
        return Color.secondary
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
                if let glyph {
                    Image(systemName: glyph)
                        .font(.subheadline)
                        .foregroundStyle(expense.isSettlement ? .green : .secondary)
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

    private var glyph: String? {
        if expense.isSettlement { return "arrow.left.arrow.right" }
        if expense.isReceipt { return "doc.text" }
        return nil
    }

    private var detail: String {
        if expense.isSettlement {
            let recipient = expense.participants.first ?? "someone"
            return "Settlement · \(expense.payer) paid \(recipient)"
        }
        if expense.isReceipt {
            var bits = ["\(expense.payer) paid", "\(expense.items.count) items"]
            if expense.discountAmount > 0.005 {
                bits.append("−\(currency(expense.discountAmount))")
            }
            if expense.taxAmount > 0.005 {
                bits.append("+\(currency(expense.taxAmount)) tax")
            }
            return bits.joined(separator: " · ")
        }
        return "\(expense.payer) paid · split \(expense.participants.count) ways"
    }
}
