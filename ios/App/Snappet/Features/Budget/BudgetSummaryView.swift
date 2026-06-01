import SwiftUI

/// Top-of-screen month summary: total budget, total spent, and remaining (red when
/// overspent). Three equal tiles in a row.
struct BudgetSummaryView: View {
    let totalLimit: Double
    let totalSpent: Double
    let remaining: Double

    var body: some View {
        HStack(spacing: 12) {
            tile(value: totalLimit.asCurrency, label: "Budget", tint: .blue)
                .accessibilityIdentifier("budget.total")
            tile(value: totalSpent.asCurrency, label: "Spent", tint: .purple)
                .accessibilityIdentifier("budget.spent")
            tile(value: remaining.asCurrency, label: "Remaining",
                 tint: remaining < 0 ? .red : .green)
                .accessibilityIdentifier("budget.remaining")
        }
        .padding(.horizontal)
    }

    private func tile(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}
