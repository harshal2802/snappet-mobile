import SwiftUI

/// The History section: completed sessions, newest first, grouped by month. Searchable by routine
/// name, with one-tap routine filter chips (issue #73). Tap for detail, swipe to delete.
struct HistorySectionView: View {
    let history: [WorkoutSession]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let deleteSession: (WorkoutSession) -> Void

    @State private var query = ""
    /// The routine name the chip row is filtering to; nil = all routines.
    @State private var routineFilter: String?

    /// A month bucket of sessions. `Identifiable` (by month) so the `ForEach` keeps stable view
    /// identity across re-renders — without it, pushing onto the shared nav path churns this
    /// subtree's identity and the row Button's tap/navigation doesn't "stick".
    private struct MonthGroup: Identifiable { let id: String; let sessions: [WorkoutSession] }

    private var filtered: [WorkoutSession] {
        HistorySearch.apply(history, query: query, routine: routineFilter)
    }
    private var routineNames: [String] { HistorySearch.routineNames(history) }

    private var grouped: [MonthGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { session -> Date in
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
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search by routine")
        .safeAreaInset(edge: .top, spacing: 0) {
            if routineNames.count > 1 { routineChips }
        }
        .overlay {
            if history.isEmpty {
                ContentUnavailableView {
                    Label("No workouts yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Finish a workout and it will appear here with your stats.")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty ? (routineFilter ?? "—") : query)
            }
        }
    }

    /// One chip per distinct routine name (most recent first); tap to filter, tap again to clear.
    /// Shown only when history spans more than one routine — a single name has nothing to filter.
    private var routineChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(routineNames, id: \.self) { name in
                    let on = routineFilter == name
                    Button { routineFilter = on ? nil : name } label: {
                        Text(name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(on ? SnappetColor.workout.opacity(0.2)
                                           : Color(.secondarySystemFill), in: Capsule())
                            .foregroundStyle(on ? SnappetColor.workout : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .snappetAnimation(SnappetMotion.quick, value: on)
                    .accessibilityIdentifier("historyFilterChip")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

/// PURE history search/filter (issue #73) — unit-tested in `SnappetTests` without a simulator.
enum HistorySearch {
    /// Routine-name chip filter (exact) first, then the search query (case-insensitive substring).
    static func apply(_ sessions: [WorkoutSession], query: String, routine: String?) -> [WorkoutSession] {
        var result = sessions
        if let routine { result = result.filter { $0.routineName == routine } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return result }
        return result.filter { $0.routineName.localizedCaseInsensitiveContains(q) }
    }

    /// Distinct routine names, most recently trained first (the order the chips render in).
    static func routineNames(_ sessions: [WorkoutSession]) -> [String] {
        var seen = Set<String>()
        return sessions.sorted { $0.startedAt > $1.startedAt }
            .compactMap { seen.insert($0.routineName).inserted ? $0.routineName : nil }
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
