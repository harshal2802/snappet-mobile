import SwiftUI

/// Top-of-screen month summary: total budget, total spent, and remaining (red when
/// overspent). Three equal tiles in a row.
struct BudgetSummaryView: View {
    let totalLimit: Double
    let totalSpent: Double
    let remaining: Double

    var body: some View {
        HStack(spacing: SnappetSpacing.md) {
            tile(value: totalLimit.asCurrency, label: "Budget",
                 systemImage: "banknote.fill", tint: SnappetColor.budget)
                .accessibilityIdentifier("budget.total")
            tile(value: totalSpent.asCurrency, label: "Spent",
                 systemImage: "cart.fill", tint: SnappetColor.journal)
                .accessibilityIdentifier("budget.spent")
            tile(value: remaining.asCurrency, label: "Remaining",
                 systemImage: remaining < 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                 tint: remaining < 0 ? SnappetColor.pomodoro : SnappetColor.habits)
                .accessibilityIdentifier("budget.remaining")
        }
        .padding(.horizontal)
    }

    private func tile(value: String, label: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: SnappetSpacing.xs) {
            // Icon is a non-colour signal in addition to the tint (issue #30 accessibility).
            Image(systemName: systemImage).font(.caption).foregroundStyle(tint)
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .snappetTile()
        // Balances move toward their new value rather than snapping (issue #30 §5.8).
        .animation(.snappy, value: value)
    }
}
