import SwiftUI

/// The History section: completed sessions, newest first, grouped by month. Tap for detail,
/// swipe to delete.
struct HistorySectionView: View {
    let history: [WorkoutSession]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let deleteSession: (WorkoutSession) -> Void

    /// A month bucket of sessions. `Identifiable` (by month) so the `ForEach` keeps stable view
    /// identity across re-renders — without it, pushing onto the shared nav path churns this
    /// subtree's identity and the row Button's tap/navigation doesn't "stick".
    private struct MonthGroup: Identifiable { let id: String; let sessions: [WorkoutSession] }

    private var grouped: [MonthGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: history) { session -> Date in
            cal.date(from: cal.dateComponents([.year, .month], from: session.startedAt)) ?? session.startedAt
        }
        return groups.keys.sorted(by: >).map { key in
            MonthGroup(id: key.formatted(.dateTime.month(.wide).year()),
                       sessions: groups[key]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    var body: some View {
        // Bare List + .overlay for the empty state (matching ExerciseBrowserView) — the previous
        // `Group { if empty … else List }` branch swap left the row Buttons' tap gestures dead.
        List {
            ForEach(grouped) { group in
                Section(group.id) {
                    ForEach(group.sessions) { session in
                        // NOTE: kept as a value-based NavigationLink (unlike the rest of the suite,
                        // which uses router Buttons). A Button here provably never fired its action
                        // on tap — a narrow SwiftUI/List quirk specific to this view — so we keep the
                        // known-good NavigationLink. Trade-off: this one row isn't XCUITest-tappable.
                        NavigationLink(value: SessionRoute(id: session.id)) {
                            HistoryRow(session: session, unit: unit)
                        }
                        .accessibilityIdentifier("historyRow")
                        .swipeActions {
                            Button(role: .destructive) { deleteSession(session) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if history.isEmpty {
                ContentUnavailableView {
                    Label("No workouts yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Finish a workout and it will appear here with your stats.")
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
