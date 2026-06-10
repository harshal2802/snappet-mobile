import SwiftUI
import SwiftData

/// Sheet to record a manual settlement: `payer` paid `recipient` a given `amount` to
/// pay down what they owe. Saving inserts a settlement `ExpenseRecord`
/// (`isSettlement: true`, `participants: [recipient]`) which the balance math treats as
/// a direct transfer — recording a settlement equal to a suggested transfer clears that
/// pair. Logs the action to `SnappetCore` on save.
struct RecordSettlementSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SnappetCore.self) private var core

    let group: ExpenseGroup

    @State private var payer: String
    @State private var recipient: String
    @State private var amount = 0.0

    init(group: ExpenseGroup) {
        self.group = group
        _payer = State(initialValue: group.participants.first ?? "")
        // Default the recipient to a different person when possible.
        _recipient = State(initialValue: group.participants.dropFirst().first
            ?? group.participants.first ?? "")
    }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Who paid") {
                    Picker("From", selection: $payer) {
                        ForEach(group.participants, id: \.self) { person in
                            Text(person).tag(person)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("expense.settle.payer")
                }

                Section("Who received") {
                    Picker("To", selection: $recipient) {
                        ForEach(group.participants, id: \.self) { person in
                            Text(person).tag(person)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("expense.settle.recipient")
                }

                Section {
                    TextField("Amount", value: $amount,
                              format: .currency(code: currencyCode))
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("expense.settle.amount")
                } header: {
                    Text("Amount")
                } footer: {
                    Text(summary)
                }
            }
            .navigationTitle("Record Settlement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("expense.settle.save")
                }
            }
        }
    }

    private var canSave: Bool {
        amount > 0 && !payer.isEmpty && !recipient.isEmpty && payer != recipient
    }

    private var summary: String {
        guard payer != recipient else {
            return "Pick two different people."
        }
        guard amount > 0 else {
            return "Records that \(payer) paid \(recipient) back."
        }
        return "\(payer) paid \(recipient) \(amount.formatted(.currency(code: currencyCode)))."
    }

    private func save() {
        guard canSave else { return }
        let record = ExpenseRecord(
            groupID: group.id,
            title: "\(payer) → \(recipient)",
            amount: amount,
            payer: payer,
            participants: [recipient],
            isSettlement: true
        )
        modelContext.insert(record)
        try? modelContext.save()

        core.log(module: "expense", action: "settle",
                 summary: "\(payer) paid \(recipient) \(amount.formatted(.currency(code: currencyCode)))",
                 metric: amount)
        Haptics.success()
        dismiss()
    }
}
