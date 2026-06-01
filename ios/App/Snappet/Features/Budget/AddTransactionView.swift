import SwiftUI

/// Sheet to log a spend against a category, or edit an existing one. When `transaction`
/// is non-nil the fields are pre-filled and the title/CTA switch to "Edit". Date defaults
/// to now for new spends; note is optional. Reports `(category, amount, note, date)` on save.
struct AddTransactionView: View {
    @Environment(\.dismiss) private var dismiss

    let categories: [BudgetCategory]
    /// When set, the sheet edits this transaction instead of creating a new one.
    let transaction: BudgetTransaction?
    let onSave: (BudgetCategory, Double, String, Date) -> Void

    @State private var selectedCategoryID: UUID?
    @State private var amount: Double?
    @State private var note: String
    @State private var date: Date

    init(categories: [BudgetCategory],
         transaction: BudgetTransaction? = nil,
         onSave: @escaping (BudgetCategory, Double, String, Date) -> Void) {
        self.categories = categories
        self.transaction = transaction
        self.onSave = onSave
        _selectedCategoryID = State(initialValue: transaction?.categoryID)
        _amount = State(initialValue: transaction?.amount)
        _note = State(initialValue: transaction?.note ?? "")
        _date = State(initialValue: transaction?.date ?? .now)
    }

    private var isEditing: Bool { transaction != nil }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    private var selectedCategory: BudgetCategory? {
        categories.first { $0.id == selectedCategoryID }
    }

    private var isValid: Bool {
        selectedCategory != nil && (amount ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    Picker("Category", selection: $selectedCategoryID) {
                        ForEach(categories) { category in
                            Text(category.name).tag(category.id as UUID?)
                        }
                    }
                }
                Section("Amount") {
                    TextField("Amount", value: $amount, format: .currency(code: currencyCode))
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("budget.txnAmount")
                }
                Section("Details") {
                    TextField("Note (optional)", text: $note)
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                }
            }
            .navigationTitle(isEditing ? "Edit Transaction" : "Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        if let category = selectedCategory, let value = amount {
                            onSave(category, value, note, date)
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier("budget.txnSave")
                    .disabled(!isValid)
                }
            }
            .onAppear {
                if selectedCategoryID == nil {
                    selectedCategoryID = categories.first?.id
                }
            }
        }
    }
}
