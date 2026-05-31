import SwiftUI

/// Sheet to log a spend against a category. Date defaults to now; note is optional.
/// Reports `(category, amount, note, date)` on save.
struct AddTransactionView: View {
    @Environment(\.dismiss) private var dismiss

    let categories: [BudgetCategory]
    let onAdd: (BudgetCategory, Double, String, Date) -> Void

    @State private var selectedCategoryID: UUID?
    @State private var amount: Double?
    @State private var note = ""
    @State private var date = Date.now

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
                }
                Section("Details") {
                    TextField("Note (optional)", text: $note)
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                }
            }
            .navigationTitle("Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let category = selectedCategory, let value = amount {
                            onAdd(category, value, note, date)
                        }
                        dismiss()
                    }
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
