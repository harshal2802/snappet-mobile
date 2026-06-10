import SwiftUI
import SwiftData
import Charts

/// The daily home (#60 §D): aggregates historical usage across every mini-app so the
/// suite reads as one app, not a bag of tools. Reactive via `@Query` — any mini-app
/// logging to `SnappetCore` updates this automatically.
struct HomeDashboardView: View {
    @Query(sort: \UsageRecord.timestamp, order: .reverse) private var records: [UsageRecord]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the 7-day chart's grow-up-from-baseline animation on appear.
    @State private var chartAppeared = false
    @State private var showingDataBackup = false

    var body: some View {
        NavigationStack {
            // Empty ↔ populated is a cross-fade (issue #30 §5.2) — and rendering one OR
            // the other (not an .overlay) fixes the empty-state-overlaps-content bug.
            ZStack {
                if records.isEmpty {
                    ContentUnavailableView("No activity yet",
                        systemImage: "square.grid.2x2",
                        description: Text("Open an app from the Apps tab — your activity shows up here."))
                        .transition(.opacity)
                } else {
                    feed.transition(.opacity)
                }
            }
            .snappetAnimation(SnappetMotion.standard, value: records.isEmpty)
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDataBackup = true
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityLabel("Data & Privacy")
                    .accessibilityIdentifier("openDataBackup")
                }
            }
            .sheet(isPresented: $showingDataBackup) {
                DataBackupView()
            }
        }
    }

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SnappetSpacing.xl) {
                todayRow
                weekChart
                activityFeed
            }
            .padding()
        }
        // Clear the suite's floating tab bar so the last card isn't covered.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: SnappetSpacing.xxl) }
    }

    // MARK: today

    private var todayStart: Date { Calendar.current.startOfDay(for: .now) }
    private var todayRecords: [UsageRecord] { records.filter { $0.timestamp >= todayStart } }

    private var todayRow: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("Today").font(.title3.bold())
            HStack(spacing: SnappetSpacing.md) {
                StatTile(value: "\(todayRecords.count)", label: "actions",
                         systemImage: "bolt.fill", tint: SnappetColor.brand)
                StatTile(value: "\(Set(todayRecords.map(\.module)).count)", label: "apps used",
                         systemImage: "square.grid.2x2.fill", tint: SnappetColor.journal)
                StatTile(value: streakText, label: "day streak",
                         systemImage: "flame.fill", tint: SnappetColor.workout)
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
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("Last 7 days").font(.headline)
            Chart(lastWeek) { d in
                BarMark(x: .value("Day", d.day, unit: .day),
                        // Bars grow up from the baseline on appear (issue #30 §5.2).
                        y: .value("Actions", chartAppeared || reduceMotion ? d.count : 0))
                .foregroundStyle(.tint)
                .cornerRadius(4)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .frame(height: 160)
            .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: chartAppeared)
            .onAppear { chartAppeared = true }
            .onDisappear { chartAppeared = false }
        }
    }

    // MARK: activity feed

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("Recent activity").font(.headline)
            ForEach(records.prefix(12)) { r in
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.summary).font(.subheadline)
                            Text(r.module.capitalized).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                        }
                        Spacer()
                        Text(r.timestamp, format: .relative(presentation: .numeric))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, SnappetSpacing.xs)
                    Divider()
                }
                // New rows slide + fade in (issue #30 §5.2).
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .snappetAnimation(SnappetMotion.standard, value: records.count)
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
    let systemImage: String
    let tint: Color
    var body: some View {
        VStack(spacing: SnappetSpacing.xs) {
            // Icon is a non-colour signal so the three tiles are distinguishable without
            // relying on hue alone (issue #30 accessibility).
            Image(systemName: systemImage).font(.subheadline).foregroundStyle(tint)
            Text(value).font(.title.bold()).foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .snappetTile()
        // Numbers count up rather than snapping (issue #30 §5.2).
        .animation(.snappy, value: value)
    }
}
