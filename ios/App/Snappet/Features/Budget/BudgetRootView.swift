import SwiftUI
import SwiftData

/// Root screen for the Budget mini-app. Pushed into the App Library's NavigationStack
/// (so it adds no stack of its own). A prev/next month header drives a selected
/// `MonthScope`; the summary tiles, spend-by-category donut, and per-category progress all
/// reflect that month (so backdated transactions show up when you step back). Categories
/// are managed via a sheet; per-category transactions (with edit) are a pushed screen; a
/// 6-month trend chart is reachable from the toolbar.
struct BudgetRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core

    @Query(sort: \BudgetCategory.createdAt, order: .forward) private var categories: [BudgetCategory]
    @Query private var transactions: [BudgetTransaction]

    @State private var showingAddCategory = false
    @State private var showingAddTransaction = false
    @State private var editingCategory: BudgetCategory?
    /// The month the whole screen is scoped to. Defaults to the current month.
    @State private var month = MonthScope()

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
                    .accessibilityIdentifier("budget.addTxn")

                    Button {
                        showingAddCategory = true
                    } label: {
                        Label("Add Category", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("budget.addCategory")
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
        .navigationDestination(for: BudgetCategory.self) { category in
            BudgetCategoryTransactionsView(
                category: category,
                categories: categories,
                transactions: transactions,
                scope: month,
                onEdit: editTransaction,
                onDelete: deleteTransaction
            )
        }
        .navigationDestination(for: BudgetTrendsRoute.self) { _ in
            BudgetTrendsView(transactions: transactions)
        }
    }

    // MARK: - States

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No categories yet", systemImage: "chart.pie")
        } description: {
            Text("Add a budget category to start tracking your spending.")
        } actions: {
            Button("Add Category") { showingAddCategory = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("budget.addCategory")
        }
    }

    private var content: some View {
        List {
            Section {
                monthHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                BudgetSummaryView(totalLimit: totalLimit,
                                  totalSpent: totalSpent,
                                  remaining: remaining)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink(value: BudgetTrendsRoute()) {
                    Label("6-month trends", systemImage: "chart.bar.xaxis")
                }
                .accessibilityIdentifier("budget.trends")
            }

            if totalSpent > 0 {
                Section("Spending in \(month.label)") {
                    SpendByCategoryChart(slices: chartSlices, periodLabel: month.label)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section("Categories") {
                ForEach(categories) { category in
                    NavigationLink(value: category) {
                        BudgetCategoryRow(name: category.name,
                                          spent: spent(for: category),
                                          limit: category.monthlyLimit)
                    }
                    .accessibilityIdentifier("budget.category.\(category.name)")
                    .swipeActions(edge: .leading) {
                        Button {
                            editingCategory = category
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onDelete(perform: deleteCategories)
            }
        }
    }

    /// Prev/next month stepper with the month label. "Next" is dimmed at the current month;
    /// `MonthScope.next()` itself clamps, so tapping it there is a harmless no-op. The chevrons
    /// use a near-transparent background so the full 44×44 is both the hit region and the
    /// reported accessibility frame — without it the frame collapses to the ~9×15 glyph and a
    /// synthetic tap lands in the glyph's notch and misses. Buttons are inline (no shared helper)
    /// so each has its own stable SwiftUI identity and a fresh action each render.
    private var monthHeader: some View {
        HStack {
            Button {
                month = month.previous()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("budget.prevMonth")

            Spacer()

            Text(month.label)
                .font(.headline)
                .accessibilityIdentifier("budget.monthLabel")

            Spacer()

            Button {
                month = month.next()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .disabled(month.isCurrent)
            .accessibilityIdentifier("budget.nextMonth")
        }
        .padding(.horizontal)
    }

    // MARK: - Month-scoped math

    /// Transactions that fall within the selected month.
    private var monthTransactions: [BudgetTransaction] {
        transactions.filter { month.contains($0.date) }
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

    private func editTransaction(_ transaction: BudgetTransaction,
                                 category: BudgetCategory,
                                 amount: Double,
                                 note: String,
                                 date: Date) {
        guard amount > 0 else { return }
        transaction.categoryID = category.id
        transaction.amount = amount
        transaction.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        transaction.date = date
        try? context.save()
        core.log(module: "budget", action: "edit",
                 summary: "Edited \(amount.asCurrency) on \(category.name)",
                 metric: amount)
    }

    private func deleteTransaction(_ transaction: BudgetTransaction) {
        context.delete(transaction)
        try? context.save()
    }

    private func deleteCategories(at offsets: IndexSet) {
        for index in offsets {
            let category = categories[index]
            // Remove the category and all of its transactions (cascade by foreign key).
            for transaction in transactions where transaction.categoryID == category.id {
                context.delete(transaction)
            }
            context.delete(category)
        }
        try? context.save()
    }
}

/// Value-type route for the pushed trends screen (so the destination is type-keyed and the
/// row stays a plain `NavigationLink(value:)`).
struct BudgetTrendsRoute: Hashable {}
