import SwiftUI
import SwiftData
import Charts

/// A day's calorie total (Swift key paths can't index tuple labels, so the chart/list data is a
/// small `Identifiable` value rather than a tuple).
private struct DayTotal: Identifiable {
    let day: Date
    let kcal: Double
    var id: Date { day }
}

/// History: daily calorie totals over time with a 7-day average vs. the target. Pushed onto
/// the App Library's stack via `NutritionHistoryRoute` (mirrors the Tip/Workout history screens).
struct NutritionHistoryView: View {
    @AppStorage("nutrition.targetKcal") private var targetKcal: Double = 2000
    @Query(sort: \FoodLogEntry.loggedAt, order: .reverse) private var entries: [FoodLogEntry]

    /// Daily totals newest-first, one row per day that has entries.
    private var dailyTotals: [DayTotal] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) { cal.startOfDay(for: $0.loggedAt) }
        return grouped
            .map { DayTotal(day: $0.key, kcal: $0.value.reduce(0) { $0 + $1.total.kcal }) }
            .sorted { $0.day > $1.day }
    }

    /// Mean of the most recent 7 logged days (not calendar-padded), or 0.
    private var sevenDayAverage: Double {
        let recent = dailyTotals.prefix(7).map(\.kcal)
        guard !recent.isEmpty else { return 0 }
        return recent.reduce(0, +) / Double(recent.count)
    }

    var body: some View {
        List {
            if dailyTotals.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "fork.knife",
                                       description: Text("Log a food to start your diary."))
            } else {
                Section {
                    Chart(Array(dailyTotals.prefix(14).reversed())) { row in
                        BarMark(x: .value("Day", row.day, unit: .day),
                                y: .value("kcal", row.kcal))
                        RuleMark(y: .value("Target", targetKcal))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .frame(height: 160)
                    .accessibilityIdentifier("nutrition.historyChart")
                    LabeledContent("7-day average",
                                   value: "\(Int(sevenDayAverage)) kcal")
                        .monospacedDigit()
                } header: {
                    Text("Daily calories")
                }

                Section("By day") {
                    ForEach(dailyTotals) { row in
                        HStack {
                            Text(row.day, format: .dateTime.weekday().month().day())
                            Spacer()
                            Text("\(Int(row.kcal)) kcal")
                                .foregroundStyle(row.kcal > targetKcal ? .red : .secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
    }
}
</content>
