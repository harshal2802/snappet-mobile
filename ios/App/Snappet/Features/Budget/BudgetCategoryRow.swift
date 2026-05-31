import SwiftUI

/// One category row: name, spent-vs-limit text, and a progress bar that turns red when
/// spending meets or exceeds the limit.
struct BudgetCategoryRow: View {
    let name: String
    let spent: Double
    let limit: Double

    /// Fraction of the limit used, clamped to [0, 1] for the bar width.
    private var fraction: Double {
        guard limit > 0 else { return spent > 0 ? 1 : 0 }
        return min(max(spent / limit, 0), 1)
    }

    private var isOver: Bool { limit > 0 && spent > limit }

    private var barTint: Color {
        if isOver { return .red }
        if fraction >= 0.85 { return .orange }
        return .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text("\(spent.asCurrency) / \(limit.asCurrency)")
                    .font(.subheadline)
                    .foregroundStyle(isOver ? .red : .secondary)
            }

            ProgressView(value: fraction)
                .tint(barTint)

            if isOver {
                Label("Over by \((spent - limit).asCurrency)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), spent \(spent.asCurrency) of \(limit.asCurrency)")
    }
}
