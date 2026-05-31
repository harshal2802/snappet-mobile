import SwiftUI
import SwiftData

/// Root screen for the Budget mini-app. Pushed into the App Library's NavigationStack
/// (so it adds no stack of its own). Shows a month summary, a spend-by-category chart,
/// and a list of categories with spent-vs-limit progress. Categories are managed via a
/// sheet; transactions are added via a sheet. All sums scope to the current month.
struct BudgetRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core

    @Query(sort: \BudgetCategory.createdAt, order: .forward) private var categories: [BudgetCategory]
    @Query private var transactions: [BudgetTransaction]

    @State private var showingAddCategory = false
    @State private var showingAddTransaction = false
    @State private var editingCategory: BudgetCategory?

    var body: some View {
        Group {
            if categories.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle("Budget")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingAddTransaction = true
                    } label: {
                        Label("Add Transaction", systemImage: "creditcard")
                    }
                    .disabled(categories.isEmpty)

                    Button {
                        showingAddCategory = true
                    } label: {
                        Label("Add Category", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddCategory) {
            BudgetCategoryEditor(category: nil) { name, limit in
                addCategory(name: name, limit: limit)
            }
        }
        .sheet(item: $editingCategory) { category in
            BudgetCategoryEditor(category: category) { name, limit in
                updateCategory(category, name: name, limit: limit)
            }
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView(categories: categories) { category, amount, note, date in
                addTransaction(category: category, amount: amount, note: note, date: date)
            }
        }
    }

    // MARK: - States

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No categories yet", systemImage: "chart.pie")
        } description: {
            Text("Add a budget category to start tracking this month's spending.")
        } actions: {
            Button("Add Category") { showingAddCategory = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var content: some View {
        List {
            Section {
                BudgetSummaryView(totalLimit: totalLimit,
                                  totalSpent: totalSpent,
                                  remaining: remaining)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if totalSpent > 0 {
                Section("Spending this month") {
                    SpendByCategoryChart(slices: chartSlices)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section("Categories") {
                ForEach(categories) { category in
                    BudgetCategoryRow(name: category.name,
                                      spent: spent(for: category),
                                      limit: category.monthlyLimit)
                        .contentShape(Rectangle())
                        .onTapGesture { editingCategory = category }
                }
                .onDelete(perform: deleteCategories)
            }
        }
    }

    // MARK: - Month-scoped math

    /// Transactions that fall within the current calendar month.
    private var monthTransactions: [BudgetTransaction] {
        transactions.filter { MonthScope.contains($0.date) }
    }

    private func spent(for category: BudgetCategory) -> Double {
        monthTransactions
            .filter { $0.categoryID == category.id }
            .reduce(0) { $0 + $1.amount }
    }

    private var totalLimit: Double {
        categories.reduce(0) { $0 + $1.monthlyLimit }
    }

    private var totalSpent: Double {
        monthTransactions.reduce(0) { $0 + $1.amount }
    }

    private var remaining: Double { totalLimit - totalSpent }

    private var chartSlices: [CategorySpend] {
        categories.compactMap { category in
            let amount = spent(for: category)
            guard amount > 0 else { return nil }
            return CategorySpend(name: category.name, amount: amount)
        }
    }

    // MARK: - Mutations

    private func addCategory(name: String, limit: Double) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        context.insert(BudgetCategory(name: trimmed, monthlyLimit: limit))
        try? context.save()
        core.log(module: "budget", action: "category",
                 summary: "Added category: \(trimmed) (\(limit.asCurrency)/mo)")
    }

    private func updateCategory(_ category: BudgetCategory, name: String, limit: Double) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        category.name = trimmed
        category.monthlyLimit = limit
        try? context.save()
    }

    private func addTransaction(category: BudgetCategory, amount: Double, note: String, date: Date) {
        guard amount > 0 else { return }
        context.insert(BudgetTransaction(categoryID: category.id,
                                         amount: amount,
                                         note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                         date: date))
        try? context.save()
        core.log(module: "budget", action: "spend",
                 summary: "Spent \(amount.asCurrency) on \(category.name)",
                 metric: amount)
    }

    private func deleteCategories(at offsets: IndexSet) {
        for index in offsets {
            let category = categories[index]
            // Remove the category and all of its transactions.
            for transaction in transactions where transaction.categoryID == category.id {
                context.delete(transaction)
            }
            context.delete(category)
        }
        try? context.save()
    }
}
