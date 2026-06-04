import SwiftUI

/// Reusable totals + per-person breakdown for an itemized receipt, rendered from a pure
/// `ReceiptSplit.Result`. Shared by the live preview in `NewReceiptSheet` and the
/// read-only `ReceiptDetailView` so the math is displayed identically in both places.
struct ReceiptSummaryView: View {
    let result: ReceiptSplit.Result
    let currency: (Double) -> String

    var body: some View {
        Section("Totals") {
            totalsRow("Items subtotal", result.itemsSubtotal)
            if result.discount > 0.005 {
                totalsRow("Discount", -result.discount, tint: SnappetColor.habits)
            }
            if result.tax > 0.005 {
                totalsRow("Tax", result.tax)
            }
            if result.unassignedSubtotal > 0.005 {
                totalsRow("Unassigned", result.unassignedSubtotal, tint: SnappetColor.pomodoro)
            }
            HStack {
                Text("Total").fontWeight(.semibold)
                Spacer()
                Text(currency(result.grandTotal))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: result.grandTotal)
            }
        }

        Section("Per person") {
            if result.perPerson.isEmpty {
                Text("Assign items to people to see the split.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.perPerson) { share in
                    PersonShareRow(share: share, currency: currency)
                }
            }
        }
    }

    private func totalsRow(_ label: String, _ value: Double, tint: Color? = nil) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(currency(value))
                .monospacedDigit()
                .foregroundStyle(tint ?? .secondary)
        }
        .font(.subheadline)
    }
}

/// One person's slice: their total, with the items/tax/discount breakdown beneath.
private struct PersonShareRow: View {
    let share: ReceiptSplit.PersonShare
    let currency: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(share.name).font(.headline)
                Spacer()
                Text(currency(share.total))
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: share.total)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("receipt.share.\(share.name)")
    }

    private var detail: String {
        var parts = ["\(currency(share.itemsSubtotal)) items"]
        if share.discount > 0.005 { parts.append("−\(currency(share.discount)) disc") }
        if share.tax > 0.005 { parts.append("+\(currency(share.tax)) tax") }
        return parts.joined(separator: "  ")
    }
}
