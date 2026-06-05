import SwiftUI
import SwiftData

/// Read-only breakdown of a saved itemized receipt: the totals, the per-person split, and
/// the item list with who shares each line. An "Edit" toolbar action reopens it in
/// `NewReceiptSheet`. Pushed onto the suite's shared navigation stack from
/// `ExpenseGroupView`.
struct ReceiptDetailView: View {
    let group: ExpenseGroup
    let record: ExpenseRecord

    @State private var showingEdit = false

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }
    private func currency(_ value: Double) -> String { value.formatted(.currency(code: currencyCode)) }

    private var result: ReceiptSplit.Result {
        ReceiptSplit.compute(items: record.items, taxAmount: record.taxAmount,
                             discountAmount: record.discountAmount, order: group.participants)
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Paid by", value: record.payer)
                LabeledContent("Date", value: record.date.formatted(date: .abbreviated, time: .omitted))
            }

            ReceiptSummaryView(result: result, currency: currency)

            Section("Items (\(record.items.count))") {
                ForEach(record.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.name.isEmpty ? "Item" : item.name)
                                .lineLimit(1)
                            Spacer()
                            Text(currency(item.price)).monospacedDigit()
                        }
                        Text(AssigneeSummary.label(item.assignees, in: group.participants))
                            .font(.caption)
                            .foregroundStyle(item.assignees.isEmpty ? SnappetColor.pomodoro : .secondary)
                    }
                }
            }
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingEdit = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .accessibilityIdentifier("expense.receipt.edit")
            }
        }
        .sheet(isPresented: $showingEdit) {
            NewReceiptSheet(group: group, record: record)
        }
    }
}
