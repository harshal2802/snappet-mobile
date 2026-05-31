import SwiftUI

/// Add/edit sheet for a budget category. `category == nil` means "add new"; otherwise the
/// fields are pre-filled for editing. Reports `(name, monthlyLimit)` on save.
struct BudgetCategoryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let category: BudgetCategory?
    let onSave: (String, Double) -> Void

    @State private var name: String
    @State private var limit: Double?

    init(category: BudgetCategory?, onSave: @escaping (String, Double) -> Void) {
        self.category = category
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
        _limit = State(initialValue: category?.monthlyLimit)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && (limit ?? 0) > 0
    }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    TextField("Name", text: $name)
                }
                Section("Monthly limit") {
                    TextField("Amount", value: $limit, format: .currency(code: currencyCode))
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmedName, limit ?? 0)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
