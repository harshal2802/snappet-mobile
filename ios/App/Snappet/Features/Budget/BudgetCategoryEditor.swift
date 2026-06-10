import SwiftUI

/// Add/edit sheet for a budget category. `category == nil` means "add new"; otherwise the
/// fields are pre-filled for editing. Reports `(name, monthlyLimit)` on save.
struct BudgetCategoryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let category: BudgetCategory?
    let onSave: (String, Double) -> Void

    @State private var name: String
    @State private var limit: Double?
    @FocusState private var limitFocused: Bool

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
                        .focused($limitFocused)
                }
            }
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commitAndSave() }
                    .disabled(!isValid)
                }
            }
            .keypadDoneToolbar($limitFocused)
        }
    }

    /// Resign-then-save so a mid-edit Save can't read the stale, uncommitted limit
    /// (the value-formatted field commits on focus loss — issue #82).
    private func commitAndSave() {
        guard !limitFocused else {
            limitFocused = false
            Task { @MainActor in performSave() }
            return
        }
        performSave()
    }

    private func performSave() {
        guard isValid else { return dismiss() }
        onSave(trimmedName, limit ?? 0)
        dismiss()
    }
}
