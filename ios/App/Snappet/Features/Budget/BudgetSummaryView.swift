import SwiftUI

/// Top-of-screen month summary: total budget, total spent, and remaining (red when
/// overspent). Three equal tiles in a row.
struct BudgetSummaryView: View {
    let totalLimit: Double
    let totalSpent: Double
    let remaining: Double

    var body: some View {
        // One panel, three light numbers (prompt 241; were three coloured bold tiles). Remaining turns red with a
        // warning glyph only when over.
        HStack(alignment: .top, spacing: SnappetSpacing.md) {
            metric(value: totalLimit.asCurrency, label: "Budget")
                .accessibilityIdentifier("budget.total")
            metric(value: totalSpent.asCurrency, label: "Spent")
                .accessibilityIdentifier("budget.spent")
            metric(value: remaining.asCurrency, label: "Remaining",
                   systemImage: remaining < 0 ? "exclamationmark.triangle.fill" : nil,
                   tint: remaining < 0 ? SnappetColor.perfHard : SnappetColor.ink)
                .accessibilityIdentifier("budget.remaining")
        }
        .snappetPanel()   // the list row has zero insets, so the panel lines up with the rows below
    }

    private func metric(value: String, label: String, systemImage: String? = nil,
                        tint: Color = SnappetColor.ink) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.caption2).foregroundStyle(tint) }
                Text(label).snappetLabel()
            }
            Text(value)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        // Balances move toward their new value rather than snapping (issue #30 §5.8).
        .animation(.snappy, value: value)
    }
}
