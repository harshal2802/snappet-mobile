import SwiftUI

/// The History section: completed sessions, newest first, grouped by month. Tap for detail,
/// swipe to delete.
struct HistorySectionView: View {
    let history: [WorkoutSession]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let deleteSession: (WorkoutSession) -> Void

    private var grouped: [(month: String, sessions: [WorkoutSession])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: history) { session -> Date in
            cal.date(from: cal.dateComponents([.year, .month], from: session.startedAt)) ?? session.startedAt
        }
        return groups.keys.sorted(by: >).map { key in
            (key.formatted(.dateTime.month(.wide).year()), groups[key]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    var body: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView {
                    Label("No workouts yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Finish a workout and it will appear here with your stats.")
                }
            } else {
                List {
                    ForEach(grouped, id: \.month) { group in
                        Section(group.month) {
                            ForEach(group.sessions) { session in
                                NavigationLink(value: session) {
                                    HistoryRow(session: session, unit: unit)
                                }
                                .swipeActions {
                                    Button(role: .destructive) { deleteSession(session) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let session: WorkoutSession
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.routineName).font(.headline).lineLimit(1)
            Text(session.startedAt, format: .dateTime.weekday().month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label("\(max(1, Int(session.duration / 60)))m", systemImage: "clock")
                Label("\(session.completedSetCount) sets", systemImage: "checkmark.circle")
                let vol = WorkoutMath.sessionVolumeKg(session)
                if vol > 0 {
                    Label(WorkoutMath.formatVolume(kg: vol, unit: unit), systemImage: "scalemass")
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
