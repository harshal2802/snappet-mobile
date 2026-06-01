import SwiftUI
import SwiftData

/// Full focus-session history, newest first, grouped into a `Section` per calendar day
/// (each header carrying that day's session count + total minutes), with the 7-day chart
/// on top. Pushed onto the suite's NavigationStack from `PomodoroRootView` — no nested stack.
struct PomodoroHistoryView: View {
    @Query(sort: \PomodoroSession.completedAt, order: .reverse)
    private var sessions: [PomodoroSession]

    /// A day bucket of sessions. `Identifiable` by its start-of-day so `ForEach` keeps stable
    /// identity across re-renders.
    private struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let sessions: [PomodoroSession]
        var count: Int { sessions.count }
        var minutes: Int { sessions.reduce(0) { $0 + $1.minutes } }
    }

    private var grouped: [DayGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.completedAt) }
        return groups.keys.sorted(by: >).map { day in
            DayGroup(id: day,
                     title: day.formatted(.dateTime.weekday(.wide).month().day()),
                     sessions: groups[day]!.sorted { $0.completedAt > $1.completedAt })
        }
    }

    private var chartData: [DailyFocus] { PomodoroStats.last7Days(sessions) }

    var body: some View {
        List {
            Section {
                PomodoroFocusChart(data: chartData)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ForEach(grouped) { group in
                Section {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session)
                            .accessibilityIdentifier("pomodoro.historyRow")
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        Text("\(group.count) · \(group.minutes) min")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView("No focus sessions yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Complete a focus block and it will appear here."))
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SessionRow: View {
    let session: PomodoroSession

    var body: some View {
        HStack {
            Image(systemName: "brain.head.profile").foregroundStyle(.red)
            Text(session.completedAt, format: .dateTime.hour().minute())
            Spacer()
            Text("\(session.minutes) min")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
