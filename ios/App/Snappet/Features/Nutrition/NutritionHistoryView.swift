import SwiftUI
import SwiftData
import Charts

/// History tab — daily calorie intake over the past 14 days, 7-day average, and per-day list.
struct NutritionHistoryView: View {
    let goal: NutritionGoal

    @Environment(\.modelContext) private var context
    @State private var days: [DaySummary] = []

    var body: some View {
        ScrollView {
            VStack(spacing: SnappetSpacing.xl) {
                if days.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "chart.bar",
                        description: Text("Start logging food to see your history.")
                    )
                    .padding(.top, SnappetSpacing.xxl)
                } else {
                    IntakeTrendChart(days: days, goal: goal.dailyKcal)
                    AverageSummary(days: days, goal: goal.dailyKcal)
                    DayList(days: days)
                }
            }
            .padding(SnappetSpacing.lg)
        }
        .accessibilityIdentifier("nutrition.history")
        .task { loadHistory() }
    }

    private func loadHistory() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
        let d = FetchDescriptor<FoodLogEntry>(
            predicate: #Predicate { $0.loggedAt >= cutoff },
            sortBy: [SortDescriptor(\.loggedAt)]
        )
        let entries = (try? context.fetch(d)) ?? []
        days = DaySummary.build(from: entries)
    }
}

struct DaySummary: Identifiable {
    var id: Date { date }
    let date: Date
    let kcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    static func build(from entries: [FoodLogEntry]) -> [DaySummary] {
        let cal = Calendar.current
        var buckets: [Date: [FoodLogEntry]] = [:]
        for e in entries {
            let day = cal.startOfDay(for: e.loggedAt)
            buckets[day, default: []].append(e)
        }
        return buckets.map { date, es in
            DaySummary(
                date: date,
                kcal: es.reduce(0) { $0 + $1.kcal },
                proteinG: es.reduce(0) { $0 + $1.proteinG },
                carbsG: es.reduce(0) { $0 + $1.carbsG },
                fatG: es.reduce(0) { $0 + $1.fatG }
            )
        }.sorted { $0.date < $1.date }
    }
}

private struct IntakeTrendChart: View {
    let days: [DaySummary]
    let goal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("Daily Intake (14 days)").font(.headline)
            Chart {
                ForEach(days) { day in
                    BarMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("kcal", day.kcal)
                    )
                    .foregroundStyle(SnappetColor.moduleAccent("nutrition"))
                }
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Goal").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .frame(height: 160)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) {
                    AxisValueLabel(format: .dateTime.day())
                }
            }
        }
        .padding(SnappetSpacing.lg)
        .snappetCard()
        .accessibilityIdentifier("nutrition.trendsChart")
    }
}

private struct AverageSummary: View {
    let days: [DaySummary]
    let goal: Double

    private var last7: [DaySummary] {
        Array(days.suffix(7))
    }
    private var avg: Double {
        guard !last7.isEmpty else { return 0 }
        return last7.reduce(0) { $0 + $1.kcal } / Double(last7.count)
    }

    var body: some View {
        HStack(spacing: SnappetSpacing.xl) {
            StatTile(label: "7-day avg", value: "\(Int(avg)) kcal")
            StatTile(label: "Goal",      value: "\(Int(goal)) kcal")
            StatTile(label: "Avg vs goal",
                     value: avg <= goal ? "\(Int(goal - avg)) under" : "\(Int(avg - goal)) over",
                     accent: avg <= goal ? .green : .red)
        }
        .padding(SnappetSpacing.lg)
        .snappetCard()
    }
}

private struct StatTile: View {
    let label: String; let value: String; var accent: Color = .primary
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold()).foregroundStyle(accent)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DayList: View {
    let days: [DaySummary]

    var body: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("By day").font(.headline)
            ForEach(days.reversed()) { day in
                HStack {
                    Text(day.date, style: .date).font(.subheadline)
                    Spacer()
                    Text("\(Int(day.kcal)) kcal").font(.subheadline.bold())
                    Text("P \(Int(day.proteinG))g · C \(Int(day.carbsG))g · F \(Int(day.fatG))g")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
            }
        }
        .padding(SnappetSpacing.lg)
        .snappetCard()
    }
}
