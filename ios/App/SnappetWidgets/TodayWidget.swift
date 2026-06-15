import SwiftUI
import WidgetKit
import AppIntents

/// The home-screen **Today** widget (#81 Phase 2): the suite's day streak + habits remaining at a
/// glance (small), plus an interactive habit checklist and a Start-focus button (medium). Reads the
/// App-Group snapshot `WidgetSnapshotStore` publishes — never SwiftData — so it stays isolated from
/// the app's schema. Uses plain SwiftUI colours (the app's `SnappetColor` tokens aren't compiled into
/// this extension — only `Shared/` is, like the Live Activity widgets).
struct TodayWidget: Widget {
    static let kind = "TodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Your day streak, habits left, and focus — at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: SnappetWidgetSnapshot
}

/// Reads the App-Group snapshot. The app nudges `reloadAllTimelines()` on every change; we also
/// schedule a reload at the next start-of-day so the widget rolls over even with no app activity.
struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: .empty())
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let now = Date()
        // resolvedForDisplay neutralises a snapshot the app built before midnight, so the widget
        // never shows yesterday's completions/streak as today's (#81 Phase 2 review fix).
        let snapshot = (WidgetSnapshotStore.read() ?? .empty()).resolvedForDisplay(now: now)
        completion(TodayEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let snapshot = (WidgetSnapshotStore.read() ?? .empty()).resolvedForDisplay(now: now)
        let entry = TodayEntry(date: now, snapshot: snapshot)
        let cal = Calendar.current
        let nextMidnight = cal.nextDate(after: Date(),
                                        matching: DateComponents(hour: 0, minute: 0, second: 0),
                                        matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry
    private var snap: SnappetWidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .systemSmall: smallView
        default: mediumView
        }
    }

    // MARK: Small — streak + habits headline

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            streakBadge
            Spacer(minLength: 0)
            Text(habitsHeadline).font(.headline).lineLimit(2)
            if snap.focusMinutesToday > 0 {
                Label("\(snap.focusMinutesToday) focus min", systemImage: "timer")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Medium — summary + interactive habit checklist + Start focus

    private var mediumView: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                streakBadge
                Text(habitsHeadline).font(.subheadline.weight(.semibold)).lineLimit(2)
                if snap.focusMinutesToday > 0 {
                    Label("\(snap.focusMinutesToday) focus min", systemImage: "timer")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Link(destination: URL(string: "snappet://pomodoro/start")!) {
                    Label("Start focus", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if snap.habits.isEmpty {
                    Text("No habits yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(snap.habits.prefix(3)) { HabitCheckRow(habit: $0) }
                    if snap.habits.count > 3 {
                        Text("+\(snap.habits.count - 3) more")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: shared

    private var streakBadge: some View {
        Label("\(snap.dayStreak)", systemImage: "flame.fill")
            .font(.title2.weight(.bold))
            .foregroundStyle(snap.dayStreak > 0 ? .orange : .secondary)
            .accessibilityLabel(snap.dayStreak == 1 ? "1 day streak" : "\(snap.dayStreak) day streak")
    }

    private var habitsHeadline: String {
        if snap.habits.isEmpty { return "Build a habit" }
        if snap.allHabitsDone { return "All habits done" }
        return "\(snap.habitsRemaining) habit\(snap.habitsRemaining == 1 ? "" : "s") left"
    }
}

/// One checklist row — an interactive check-off (`ToggleHabitIntent`) + the habit name.
private struct HabitCheckRow: View {
    let habit: SnappetWidgetSnapshot.HabitItem

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: ToggleHabitIntent(habitID: habit.id.uuidString)) {
                Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(habit.doneToday ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(habit.doneToday ? "Uncheck \(habit.name)" : "Check off \(habit.name)")

            Text(habit.name)
                .font(.caption)
                .strikethrough(habit.doneToday, color: .secondary)
                .foregroundStyle(habit.doneToday ? .secondary : .primary)
                .lineLimit(1)
        }
    }
}
