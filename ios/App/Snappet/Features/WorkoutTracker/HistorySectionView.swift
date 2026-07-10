import SwiftUI

/// The History section: completed sessions, newest first, grouped by month. Searchable by routine
/// name, with one-tap routine filter chips (issue #73) and a tracking-type facet (workout-with-timer
/// PR 6) that keeps sessions tracking any selected `SetKind`. Tap for detail, swipe right to delete;
/// media-bearing rows show a Studio badge and swipe left to open the Video Studio directly (#74).
struct HistorySectionView: View {
    let history: [WorkoutSession]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    /// Session ids with ≥ 1 tagged video (#74) — those rows get the Studio badge + swipe shortcut.
    let videoSessionIDs: Set<UUID>
    let deleteSession: (WorkoutSession) -> Void
    /// Open the Video Studio over a session (#74) — presented by `WorkoutHomeView`.
    let openStudio: (WorkoutSession) -> Void
    /// Completed **Apple Watch** workouts imported into Clips (watch-workouts-clips P3), newest first.
    /// Shown in their own "From Apple Watch" section — kept OUT of `history` (no exercises/sets) so they
    /// never run through the routine/kind filters or pollute the tracked-workout list. Same detail route.
    var watchSessions: [WorkoutSession] = []

    @State private var query = ""
    /// The routine name the chip row is filtering to; nil = all routines.
    @State private var routineFilter: String?
    /// Tracking-type facet (workout-with-timer PR 6): the selected `SetKind`s; empty = no filter.
    /// A session is kept when any of its exercises tracks one of these kinds.
    @State private var kindFilter: Set<SetKind> = []

    /// A month bucket of sessions. `Identifiable` (by month) so the `ForEach` keeps stable view
    /// identity across re-renders — without it, pushing onto the shared nav path churns this
    /// subtree's identity and the row Button's tap/navigation doesn't "stick".
    private struct MonthGroup: Identifiable { let id: String; let sessions: [WorkoutSession] }

    /// The filter that actually applies — a chip whose routine left history (last such session
    /// deleted) filters nothing instead of sticking the list on empty.
    private var effectiveFilter: String? {
        HistorySearch.effectiveRoutine(filter: routineFilter, names: routineNames)
    }
    private var filtered: [WorkoutSession] {
        HistorySearch.apply(history, query: query, routine: effectiveFilter, kinds: kindFilter)
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
            // Apple Watch imports — their own section, above tracked history and outside its filters.
            // Only when the user isn't actively filtering/searching the tracked list (those facets don't
            // apply to watch workouts, which carry no routine/kinds).
            if !watchSessions.isEmpty, query.isEmpty, effectiveFilter == nil, kindFilter.isEmpty {
                Section {
                    ForEach(watchSessions) { session in
                        NavigationLink(value: SessionRoute(id: session.id)) {
                            WatchHistoryRow(session: session, hasVideo: videoSessionIDs.contains(session.id))
                        }
                        .accessibilityIdentifier("watchHistoryRow")
                    }
                } header: {
                    Label("From Apple Watch", systemImage: "applewatch")
                        .foregroundStyle(SnappetColor.perfFresh)
                }
            }
            ForEach(grouped) { group in
                Section(group.id) {
                    ForEach(group.sessions) { session in
                        // NOTE: kept as a value-based NavigationLink (unlike the rest of the suite,
                        // which uses router Buttons). A Button here provably never fired its action
                        // on tap — a narrow SwiftUI/List quirk specific to this view — so we keep the
                        // known-good NavigationLink. Trade-off: this one row isn't XCUITest-tappable.
                        NavigationLink(value: SessionRoute(id: session.id)) {
                            HistoryRow(session: session, unit: unit,
                                       hasVideo: videoSessionIDs.contains(session.id))
                        }
                        .accessibilityIdentifier("historyRow")
                        .swipeActions {
                            Button(role: .destructive) { deleteSession(session) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            // Straight into the Video Studio for rows that have clips (#74).
                            if videoSessionIDs.contains(session.id) {
                                Button { openStudio(session) } label: {
                                    Label("Studio", systemImage: "film.stack")
                                }
                                .tint(SnappetColor.workout)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search by routine")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // Also shown while a filter is active with one routine left, so it can be toggled off.
                if routineNames.count > 1 || effectiveFilter != nil { routineChips }
                // Tracking-type facet (workout-with-timer PR 6): always offered once any session exists,
                // so a kind can always be toggled on/off (it sits alongside the routine chips).
                if !history.isEmpty { kindChips }
            }
        }
        .overlay {
            if history.isEmpty && watchSessions.isEmpty {
                ContentUnavailableView {
                    Label("No workouts yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Finish a workout and it will appear here with your stats.")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty ? (effectiveFilter ?? "—") : query)
            }
        }
    }

    /// One chip per distinct routine name (most recent first); tap to filter, tap again to clear.
    /// Shown when history spans more than one routine, or while a filter is active.
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

    /// Tracking-type facet (workout-with-timer PR 6): one toggle chip per `SetKind` — keep sessions
    /// whose exercises track ANY selected kind (empty = all). Mirrors the routine-chip styling; each
    /// chip is a LEAF (id `history.kindChip.<rawValue>`) so iOS 26 doesn't collapse the a11y subtree.
    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SetKind.allCases, id: \.self) { kind in
                    let on = kindFilter.contains(kind)
                    Button {
                        if on { kindFilter.remove(kind) } else { kindFilter.insert(kind) }
                    } label: {
                        Label(kind.display, systemImage: kind.symbol)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(on ? SnappetColor.workout.opacity(0.2)
                                           : Color(.secondarySystemFill), in: Capsule())
                            .foregroundStyle(on ? SnappetColor.workout : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .snappetAnimation(SnappetMotion.quick, value: on)
                    .accessibilityIdentifier("history.kindChip.\(kind.rawValue)")
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
    /// Routine-name chip filter (exact) first, then the tracking-type facet (any selected `SetKind`),
    /// then the search query (case-insensitive substring). `kinds` empty ⇒ the facet is inert.
    static func apply(_ sessions: [WorkoutSession], query: String, routine: String?,
                      kinds: Set<SetKind> = []) -> [WorkoutSession] {
        var result = sessions
        if let routine { result = result.filter { $0.routineName == routine } }
        result = filterByTrackingTypes(result, kinds: kinds)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return result }
        return result.filter { $0.routineName.localizedCaseInsensitiveContains(q) }
    }

    /// Tracking-type facet (workout-with-timer PR 6): keep a session when ANY of its exercises tracks
    /// one of `kinds` (the union of the selected chips). An empty selection is a pass-through (no
    /// filter), so the facet only ever narrows. A session's tracking types = the set of `ex.kind`.
    static func filterByTrackingTypes(_ sessions: [WorkoutSession], kinds: Set<SetKind>) -> [WorkoutSession] {
        guard !kinds.isEmpty else { return sessions }
        return sessions.filter { session in
            session.exercises.contains { kinds.contains($0.kind) }
        }
    }

    /// Distinct routine names, most recently trained first (the order the chips render in).
    static func routineNames(_ sessions: [WorkoutSession]) -> [String] {
        var seen = Set<String>()
        return sessions.sorted { $0.startedAt > $1.startedAt }
            .compactMap { seen.insert($0.routineName).inserted ? $0.routineName : nil }
    }

    /// The filter that actually applies: a selection whose routine is no longer in history (e.g.
    /// its last session was deleted) is inert, so the list can never get stuck on empty.
    static func effectiveRoutine(filter: String?, names: [String]) -> String? {
        filter.flatMap { names.contains($0) ? $0 : nil }
    }
}

private struct HistoryRow: View {
    let session: WorkoutSession
    let unit: WeightUnit
    /// Session has tagged video → show the Studio badge (#74), so media-bearing sessions are
    /// findable from the list instead of only after opening each detail.
    var hasVideo: Bool = false

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
                if hasVideo {
                    Label("Studio", systemImage: "film.stack")
                        .foregroundStyle(SnappetColor.workout)
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// A row for an Apple Watch import (watch-workouts-clips P3): the activity name + its HealthKit stats
/// (duration · distance · energy) and a clip count, marked with the ⌚ source glyph. No sets/volume —
/// these workouts carry none.
private struct WatchHistoryRow: View {
    let session: WorkoutSession
    var hasVideo: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "applewatch")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SnappetColor.perfFresh)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.routineName).font(.headline).lineLimit(1)
                Text(session.startedAt, format: .dateTime.weekday().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(max(1, Int(session.duration / 60)))m", systemImage: "clock")
                    if let m = session.hkDistanceMeters, m > 0 {
                        Label(Self.distance(m), systemImage: "figure.walk")
                    }
                    if let kcal = session.hkEnergyKcal, kcal > 0 {
                        Label("\(Int(kcal.rounded())) kcal", systemImage: "flame")
                    }
                    if hasVideo { Label("Clips", systemImage: "film.stack").foregroundStyle(SnappetColor.perfFresh) }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Metres → a compact "5.1 km" / "820 m" label.
    private static func distance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters.rounded())) m"
    }
}
