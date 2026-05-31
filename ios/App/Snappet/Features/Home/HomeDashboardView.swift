import SwiftUI
import SwiftData
import Charts

/// The daily home (#60 §D): aggregates historical usage across every mini-app so the
/// suite reads as one app, not a bag of tools. Reactive via `@Query` — any mini-app
/// logging to `SnappetCore` updates this automatically.
struct HomeDashboardView: View {
    @Query(sort: \UsageRecord.timestamp, order: .reverse) private var records: [UsageRecord]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    todayRow
                    weekChart
                    activityFeed
                }
                .padding()
            }
            .navigationTitle("Today")
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView("No activity yet",
                        systemImage: "square.grid.2x2",
                        description: Text("Open an app from the Apps tab — your activity shows up here."))
                }
            }
        }
    }

    // MARK: today

    private var todayStart: Date { Calendar.current.startOfDay(for: .now) }
    private var todayRecords: [UsageRecord] { records.filter { $0.timestamp >= todayStart } }

    private var todayRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today").font(.title3.bold())
            HStack(spacing: 12) {
                StatTile(value: "\(todayRecords.count)", label: "actions", tint: .blue)
                StatTile(value: "\(Set(todayRecords.map(\.module)).count)", label: "apps used", tint: .purple)
                StatTile(value: streakText, label: "day streak", tint: .orange)
            }
        }
    }

    // MARK: 7-day chart

    private struct DayCount: Identifiable { let id = UUID(); let day: Date; let count: Int }

    private var lastWeek: [DayCount] {
        let cal = Calendar.current
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: todayStart)!
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            let count = records.filter { $0.timestamp >= day && $0.timestamp < next }.count
            return DayCount(day: day, count: count)
        }
    }

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 7 days").font(.headline)
            Chart(lastWeek) { d in
                BarMark(x: .value("Day", d.day, unit: .day),
                        y: .value("Actions", d.count))
                .foregroundStyle(.tint)
                .cornerRadius(4)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .frame(height: 160)
        }
    }

    // MARK: activity feed

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent activity").font(.headline)
            ForEach(records.prefix(12)) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.summary).font(.subheadline)
                        Text(r.module.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(r.timestamp, format: .relative(presentation: .numeric))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    /// Consecutive days (ending today) with at least one logged action.
    private var streakText: String {
        let cal = Calendar.current
        let days = Set(records.map { cal.startOfDay(for: $0.timestamp) })
        var streak = 0
        var cursor = todayStart
        while days.contains(cursor) {
            streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return "\(streak)"
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let tint: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title.bold()).foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}
