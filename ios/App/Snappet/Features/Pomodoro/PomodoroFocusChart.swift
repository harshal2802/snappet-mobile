import SwiftUI
import Charts

/// Focus minutes for a single calendar day — the unit the 7-day chart plots.
struct DailyFocus: Identifiable {
    /// Start-of-day for the bucket; also the chart's x-value.
    let day: Date
    var minutes: Int
    var id: Date { day }
}

/// Aggregates `PomodoroSession` rows into the last 7 calendar days of focus minutes.
///
/// Kept out of the view body (conventions §SwiftUI): the view just renders the result.
/// Always returns 7 buckets (oldest → newest) so the chart has a stable x-axis even on
/// days with no sessions.
enum PomodoroStats {
    static func last7Days(_ sessions: [PomodoroSession], now: Date = .now,
                          calendar: Calendar = .current) -> [DailyFocus] {
        let today = calendar.startOfDay(for: now)
        // Pre-seed the 7 day buckets so empty days still render as a zero bar.
        var buckets: [Date: Int] = [:]
        var days: [Date] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            buckets[day] = 0
            days.append(day)
        }
        for session in sessions {
            let day = calendar.startOfDay(for: session.completedAt)
            if buckets[day] != nil { buckets[day, default: 0] += session.minutes }
        }
        return days.map { DailyFocus(day: $0, minutes: buckets[$0] ?? 0) }
    }
}

/// A compact 7-day focus-minutes bar chart. Shown on the Pomodoro root and atop History.
struct PomodoroFocusChart: View {
    let data: [DailyFocus]

    private var total: Int { data.reduce(0) { $0 + $1.minutes } }
    /// At least 0–25 min, so a stub (or a short day) stays short when the week is empty.
    private var top: Double { Double(max(data.map(\.minutes).max() ?? 0, 25)) }
    private var stub: Double { top * 0.04 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 7 days").snappetLabel()
            Chart(data) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    // An empty day draws a short stub so it still reads as a day.
                    y: .value("Minutes", point.minutes > 0 ? Double(point.minutes) : stub),
                    width: .ratio(0.5)
                )
                // Thin accent bars; empty days are a hairline stub (prompt 238; were red).
                .foregroundStyle(point.minutes > 0 ? SnappetColor.brand : SnappetColor.hairline)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartYScale(domain: 0...top)
            .frame(height: 160)
            .accessibilityIdentifier("pomodoro.chart")
            .accessibilityLabel("Focus minutes for the last 7 days, \(total) minutes total")
        }
        .snappetPanel()
    }
}
