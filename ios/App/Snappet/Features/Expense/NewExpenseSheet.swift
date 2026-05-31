import SwiftUI
import SwiftData

/// Sheet to add an `ExpenseRecord` to a group: title, amount, who paid, and which
/// participants share the cost (default all, equal split). Logs the action to
/// `SnappetCore` on save.
struct NewExpenseSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SnappetCore.self) private var core

    let group: ExpenseGroup

    @State private var title = ""
    @State private var amount = 0.0
    @State private var payer: String
    /// Names included in the split; defaults to everyone.
    @State private var splitAmong: Set<String>

    init(group: ExpenseGroup) {
        self.group = group
        _payer = State(initialValue: group.participants.first ?? "")
        _splitAmong = State(initialValue: Set(group.participants))
    }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Expense") {
                    TextField("Title (e.g. Dinner)", text: $title)
                    TextField("Amount", value: $amount,
                              format: .currency(code: currencyCode))
                        .keyboardType(.decimalPad)
                }

                Section("Paid by") {
                    Picker("Paid by", selection: $payer) {
                        ForEach(group.participants, id: \.self) { person in
                            Text(person).tag(person)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    ForEach(group.participants, id: \.self) { person in
                        Button {
                            toggle(person)
                        } label: {
                            HStack {
                                Text(person).foregroundStyle(.primary)
                                Spacer()
                                if splitAmong.contains(person) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Split equally among")
                } footer: {
                    Text(splitSummary)
                }
            }
            .navigationTitle("New Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && amount > 0
            && !payer.isEmpty
            && !splitAmong.isEmpty
    }

    private var splitSummary: String {
        guard !splitAmong.isEmpty, amount > 0 else {
            return "Select who shares this expense."
        }
        let share = amount / Double(splitAmong.count)
        return "\(share.formatted(.currency(code: currencyCode))) each (\(splitAmong.count) people)."
    }

    private func toggle(_ person: String) {
        if splitAmong.contains(person) {
            splitAmong.remove(person)
        } else {
            splitAmong.insert(person)
        }
    }

    private func save() {
        guard canSave else { return }
        // Preserve the group's participant order for the stored split list.
        let splitList = group.participants.filter { splitAmong.contains($0) }
        let record = ExpenseRecord(
            groupID: group.id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount,
            payer: payer,
            participants: splitList
        )
        modelContext.insert(record)
        try? modelContext.save()

        core.log(module: "expense", action: "expense",
                 summary: "Added \(amount.formatted(.currency(code: currencyCode))) expense",
                 metric: amount)
        dismiss()
    }
}
