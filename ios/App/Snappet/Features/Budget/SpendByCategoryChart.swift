import SwiftUI
import Charts

/// One category's spend for the current month — the unit the chart plots.
struct CategorySpend: Identifiable {
    let id = UUID()
    let name: String
    let amount: Double
}

/// A sector (pie/donut) chart of this month's spend broken down by category.
struct SpendByCategoryChart: View {
    let slices: [CategorySpend]

    private var total: Double { slices.reduce(0) { $0 + $1.amount } }

    var body: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Spent", slice.amount),
                innerRadius: .ratio(0.6),
                angularInset: 1.5
            )
            .cornerRadius(4)
            .foregroundStyle(by: .value("Category", slice.name))
        }
        .chartLegend(position: .bottom, alignment: .center, spacing: 8)
        .chartBackground { proxy in
            GeometryReader { geo in
                if let frame = proxy.plotFrame {
                    let rect = geo[frame]
                    VStack(spacing: 2) {
                        Text(total.asCurrency)
                            .font(.headline.bold())
                        Text("this month")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .frame(height: 220)
        .accessibilityLabel("Spending by category, total \(total.asCurrency) this month")
    }
}
