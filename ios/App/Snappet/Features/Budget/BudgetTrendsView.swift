import SwiftUI
import Charts

/// Total spend for one calendar month — the unit the trend chart plots.
struct MonthlySpend: Identifiable {
    /// First day of the month (00:00), used both as identity and the chart's x-value.
    let monthStart: Date
    let total: Double

    var id: Date { monthStart }

    /// A short axis label, e.g. "May".
    var shortLabel: String {
        monthStart.formatted(.dateTime.month(.abbreviated))
    }
}

/// Pure aggregation for the trend chart: total spend per month for the last `count` months
/// up to and including the month containing `now`. Kept out of the view body so it stays
/// testable and the body stays declarative.
enum SpendTrend {
    static func monthlyTotals(transactions: [BudgetTransaction],
                              count: Int = 6,
                              now: Date = .now,
                              calendar: Calendar = .current) -> [MonthlySpend] {
        let thisMonth = MonthScope(anchor: now, calendar: calendar)
        // Build the window oldest → newest so the chart reads left-to-right.
        let months: [MonthScope] = (0..<count)
            .reversed()
            .map { offset in
                var scope = thisMonth
                for _ in 0..<offset { scope = scope.previous() }
                return scope
            }
        return months.map { scope in
            let total = transactions
                .filter { scope.contains($0.date) }
                .reduce(0) { $0 + $1.amount }
            return MonthlySpend(monthStart: scope.start, total: total)
        }
    }
}

/// A 6-month spending-trend bar chart. Pushed onto the App Library's navigation stack
/// (no stack of its own). Aggregation happens in `SpendTrend`, not here.
struct BudgetTrendsView: View {
    let transactions: [BudgetTransaction]

    private var totals: [MonthlySpend] { SpendTrend.monthlyTotals(transactions: transactions) }

    private var hasSpend: Bool { totals.contains { $0.total > 0 } }

    var body: some View {
        Group {
            if hasSpend {
                chart
            } else {
                ContentUnavailableView("No spending yet",
                                       systemImage: "chart.bar",
                                       description: Text("Log some transactions to see your 6-month trend."))
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("budget.trendsChart")
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spending — last 6 months")
                .font(.headline)
                .padding(.horizontal)

            Chart(totals) { month in
                BarMark(
                    x: .value("Month", month.shortLabel),
                    y: .value("Spent", month.total)
                )
                .foregroundStyle(Color.blue.gradient)
                .cornerRadius(6)
            }
            .chartYAxis {
                AxisMarks(format: .currency(code: Locale.current.currency?.identifier ?? "USD")
                    .precision(.fractionLength(0)))
            }
            .frame(height: 280)
            .padding(.horizontal)
            .accessibilityLabel("Monthly spending bar chart for the last six months")
        }
        .padding(.vertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
