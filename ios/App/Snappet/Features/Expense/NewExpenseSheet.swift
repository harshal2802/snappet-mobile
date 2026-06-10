import SwiftUI
import SwiftData

/// Sheet to add — or edit — an `ExpenseRecord` in a group: title, amount, who paid, and
/// which participants share the cost (default all, equal split). When an existing
/// `record` is passed the form is pre-filled and saving updates it in place. Logs the
/// action to `SnappetCore` on save.
struct NewExpenseSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SnappetCore.self) private var core

    let group: ExpenseGroup
    /// The expense being edited, or `nil` when adding a new one.
    let record: ExpenseRecord?

    @State private var title = ""
    @State private var amount = 0.0
    @State private var payer: String
    /// Names included in the split; defaults to everyone.
    @State private var splitAmong: Set<String>

    init(group: ExpenseGroup, record: ExpenseRecord? = nil) {
        self.group = group
        self.record = record
        _title = State(initialValue: record?.title ?? "")
        _amount = State(initialValue: record?.amount ?? 0.0)
        _payer = State(initialValue: record?.payer ?? group.participants.first ?? "")
        _splitAmong = State(initialValue: Set(record?.participants ?? group.participants))
    }

    private var isEditing: Bool { record != nil }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Expense") {
                    TextField("Title (e.g. Dinner)", text: $title)
                        .accessibilityIdentifier("expense.expense.title")
                    TextField("Amount", value: $amount,
                              format: .currency(code: currencyCode))
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("expense.expense.amount")
                }

                Section("Paid by") {
                    Picker("Paid by", selection: $payer) {
                        ForEach(group.participants, id: \.self) { person in
                            Text(person).tag(person)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("expense.expense.payer")
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
                        .accessibilityIdentifier("expense.participant.\(person)")
                    }
                } header: {
                    Text("Split equally among")
                } footer: {
                    Text(splitSummary)
                }
            }
            .navigationTitle(isEditing ? "Edit Expense" : "New Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("expense.expense.save")
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
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve the group's participant order for the stored split list.
        let splitList = group.participants.filter { splitAmong.contains($0) }

        if let record {
            // Edit in place — balances recompute from the updated fields.
            record.title = trimmedTitle
            record.amount = amount
            record.payer = payer
            record.participants = splitList
        } else {
            let newRecord = ExpenseRecord(
                groupID: group.id,
                title: trimmedTitle,
                amount: amount,
                payer: payer,
                participants: splitList
            )
            modelContext.insert(newRecord)
        }
        try? modelContext.save()

        let verb = isEditing ? "Edited" : "Added"
        core.log(module: "expense", action: "expense",
                 summary: "\(verb) \(amount.formatted(.currency(code: currencyCode))) expense",
                 metric: amount)
        Haptics.success()
        dismiss()
    }
}
