import SwiftUI
import SwiftData

/// A pushed list of the transactions logged against one category for the selected month.
/// Tapping a row opens the editor (reusing `AddTransactionView` in edit mode); swipe to
/// delete. Mutations go through the parent so totals recompute consistently.
struct BudgetCategoryTransactionsView: View {
    let category: BudgetCategory
    let categories: [BudgetCategory]
    let transactions: [BudgetTransaction]
    let scope: MonthScope
    let onEdit: (BudgetTransaction, BudgetCategory, Double, String, Date) -> Void
    let onDelete: (BudgetTransaction) -> Void

    @State private var editingTransaction: BudgetTransaction?

    /// This category's transactions for the selected month, newest first.
    private var rows: [BudgetTransaction] {
        transactions
            .filter { $0.categoryID == category.id && scope.contains($0.date) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView("No transactions",
                                       systemImage: "creditcard",
                                       description: Text("No spending logged for \(category.name) in \(scope.label)."))
            } else {
                list
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionView(categories: categories, transaction: transaction) { category, amount, note, date in
                onEdit(transaction, category, amount, note, date)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(rows) { transaction in
                Button {
                    editingTransaction = transaction
                } label: {
                    row(transaction)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("budget.editTxn")
            }
            .onDelete { offsets in
                for index in offsets { onDelete(rows[index]) }
            }
        }
    }

    private func row(_ transaction: BudgetTransaction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.note.isEmpty ? category.name : transaction.note)
                    .font(.headline)
                Text(transaction.date.formatted(.dateTime.month().day().year()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(transaction.amount.asCurrency)
                .font(.subheadline.bold())
        }
        .contentShape(Rectangle())
    }
}
