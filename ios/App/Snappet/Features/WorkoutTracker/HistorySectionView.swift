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
    /// Completed workouts IMPORTED from Apple Health (watch-workouts-clips P3), newest first — the
    /// Watch's own recordings and anything another app wrote into Health (Google Health, Strava…).
    /// Passed separately because the tracked-only `history` feeds analytics/Studio elsewhere; THIS
    /// screen merges the two (prompt 130) so History means all of your history.
    var watchSessions: [WorkoutSession] = []

    @State private var query = ""
    /// The routine name the chip row is filtering to; nil = all routines.
    @State private var routineFilter: String?
    /// Tracking-type facet (workout-with-timer PR 6): the selected `SetKind`s; empty = no filter.
    /// A session is kept when any of its exercises tracks one of these kinds.
    @State private var kindFilter: Set<SetKind> = []
    /// Source facet (prompt 130): empty = show tracked AND imported, the default.
    @State private var sourceFilter: Set<HistorySource> = []
    /// The filter sheet (prompt 131). Facets used to live in three permanently-stacked chip rows —
    /// ~280 pt of chrome that left only two sessions above the fold and grew with every new routine
    /// name. They now live in a sheet behind a labelled button; the screen's default state is your
    /// history, not a control panel.
    @State private var showingFilters = false

    /// Every facet is `@State`, never `@AppStorage`: a filter that survived out of sight would
    /// recreate the bug this screen just shed (History quietly hiding half of itself). Switching
    /// segments rebuilds this view — `sectionContent.id(section)` — so filters clear themselves;
    /// pushing into a session detail and coming back deliberately keeps them.
    private var activeFilterCount: Int {
        sourceFilter.count + kindFilter.count + (effectiveFilter == nil ? 0 : 1)
    }
    private var isFiltering: Bool { activeFilterCount > 0 }

    /// One removable chip per active facet value.
    private struct FilterToken: Identifiable {
        let id: String
        let label: String
        let clear: () -> Void
    }

    private var activeTokens: [FilterToken] {
        var out: [FilterToken] = []
        for source in HistorySource.allCases where sourceFilter.contains(source) {
            out.append(FilterToken(id: "source.\(source.rawValue)", label: source.title) {
                sourceFilter.remove(source)
            })
        }
        if let routine = effectiveFilter {
            out.append(FilterToken(id: "routine.\(routine)", label: routine) { routineFilter = nil })
        }
        for kind in SetKind.allCases where kindFilter.contains(kind) {
            out.append(FilterToken(id: "kind.\(kind.rawValue)", label: kind.display) {
                kindFilter.remove(kind)
            })
        }
        return out
    }

    /// Always shown (the user's call): "237 sessions" idle, "12 of 237 sessions" while filtering —
    /// so a filter can never quietly shrink History without saying so.
    private var countLine: String {
        let shown = filtered.count, total = allSessions.count
        let noun = total == 1 ? "session" : "sessions"
        return isFiltering ? "\(shown) of \(total) \(noun)" : "\(total) \(noun)"
    }

    /// Why the filtered list came back empty. The imported-plus-tracking-type case is genuinely
    /// unsatisfiable rather than merely narrow, so it gets its own sentence.
    private var emptyFilterExplanation: String {
        if sourceFilter == [.imported], !kindFilter.isEmpty {
            return "Imported workouts carry no sets, so they never match a tracking type."
        }
        if !query.isEmpty { return "Nothing matches “\(query)” with these filters." }
        return "No sessions match every filter you've picked."
    }

    private func clearAllFilters() {
        sourceFilter = []
        routineFilter = nil
        kindFilter = []
    }

    /// Everything, newest first — the list this screen actually shows. Imports used to live in a
    /// separate section that vanished the moment ANY filter or search was active, so filtering
    /// silently hid half the user's history; now one chronological list carries both and the
    /// Source chips are how you narrow instead.
    private var allSessions: [WorkoutSession] {
        (history + watchSessions).sorted { $0.startedAt > $1.startedAt }
    }

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
        HistorySearch.apply(allSessions, query: query, routine: effectiveFilter,
                            kinds: kindFilter, sources: sourceFilter)
    }
    /// Chips cover every name in the merged list — an imported "Climbing" is as filterable as a
    /// tracked "Pre climb warmup".
    private var routineNames: [String] { HistorySearch.routineNames(allSessions) }

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
                            // One list, two row shapes: an import carries no sets/exercises, so it
                            // renders its source + measured totals instead of set counts.
                            if session.isImportedFromHealth {
                                WatchHistoryRow(session: session,
                                                hasVideo: videoSessionIDs.contains(session.id))
                            } else {
                                HistoryRow(session: session, unit: unit,
                                           hasVideo: videoSessionIDs.contains(session.id))
                            }
                        }
                        .accessibilityIdentifier(session.isImportedFromHealth
                                                 ? "watchHistoryRow" : "historyRow")
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
            if !allSessions.isEmpty { filterBar }
        }
        .sheet(isPresented: $showingFilters) {
            HistoryFilterSheet(sources: $sourceFilter, routine: $routineFilter, kinds: $kindFilter,
                               routineNames: routineNames,
                               offersSource: !history.isEmpty && !watchSessions.isEmpty,
                               matchCount: filtered.count,
                               onClearAll: clearAllFilters)
                // Medium detent so the list re-filters LIVE behind the sheet as chips are tapped —
                // no apply → dismiss → check → reopen loop.
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .overlay {
            if allSessions.isEmpty {
                ContentUnavailableView {
                    Label("No workouts yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Finish a workout and it will appear here with your stats.")
                }
            } else if filtered.isEmpty, isFiltering {
                // Never a bare blank list: say WHY nothing matched and offer the way out. The
                // contradictory combination is called out by name, because "Imported + Reps &
                // weight" can never match — imports carry no sets at all.
                ContentUnavailableView {
                    Label("No sessions match", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(emptyFilterExplanation)
                } actions: {
                    Button("Clear filters", action: clearAllFilters)
                        .buttonStyle(.borderedProminent)
                        .tint(SnappetColor.workout)
                        .accessibilityIdentifier("history.emptyClearFilters")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    /// The one always-present row (prompt 131): a LABELLED "Filters" button — an unlabelled icon is
    /// the affordance the Kilter tester never found — and the honest count beside it. When filters
    /// are active a second line of removable tokens appears, so state is never invisible.
    private var filterBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { showingFilters = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isFiltering
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                        Text("Filters").fontWeight(.semibold)
                        if activeFilterCount > 0 {
                            Text("\(activeFilterCount)")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(SnappetColor.workout, in: Capsule())
                                .foregroundStyle(.black)
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(isFiltering ? SnappetColor.workout.opacity(0.2)
                                            : Color(.secondarySystemFill), in: Capsule())
                    .foregroundStyle(isFiltering ? SnappetColor.workout : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history.filtersButton")

                Spacer(minLength: 6)

                Text(countLine)
                    .font(.caption)
                    .foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("history.countLine")
            }
            .padding(.horizontal)
            .padding(.vertical, 7)

            if !activeTokens.isEmpty { tokenRow }
        }
        .background(.bar)
    }

    /// Removable tokens for what's currently narrowing the list, plus Clear all.
    private var tokenRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeTokens) { token in
                    Button(action: token.clear) {
                        HStack(spacing: 5) {
                            Text(token.label).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(SnappetColor.workout.opacity(0.18), in: Capsule())
                        .foregroundStyle(SnappetColor.workout)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history.token")
                }
                Button("Clear all", action: clearAllFilters)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("history.clearAll")
            }
            .padding(.horizontal)
            .padding(.bottom, 7)
        }
    }

}

/// The History filter sheet (prompt 131) — every facet in one place, behind the labelled "Filters"
/// button, so the screen's resting state is history rather than three rows of chips.
///
/// **Live-applying by design**: the chips write straight through to the caller's `@State`, and the
/// sheet is presented at a medium detent with background interaction enabled, so the list re-filters
/// behind it as you tap. There is no Apply button to forget; the primary action just states the
/// outcome ("Show 12 sessions") and dismisses.
struct HistoryFilterSheet: View {
    @Binding var sources: Set<HistorySource>
    @Binding var routine: String?
    @Binding var kinds: Set<SetKind>
    let routineNames: [String]
    /// Hidden when the user has only one kind of session — a facet that can't narrow anything is noise.
    let offersSource: Bool
    let matchCount: Int
    let onClearAll: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isFiltering: Bool { !sources.isEmpty || routine != nil || !kinds.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if offersSource {
                        section("Source") {
                            ForEach(HistorySource.allCases) { source in
                                chip(source.title, symbol: source.symbol,
                                     on: sources.contains(source),
                                     id: "history.filter.source.\(source.rawValue)") {
                                    if sources.contains(source) { sources.remove(source) }
                                    else { sources.insert(source) }
                                }
                            }
                        }
                    }
                    if !routineNames.isEmpty {
                        section("Routine") {
                            ForEach(routineNames, id: \.self) { name in
                                chip(name, symbol: nil, on: routine == name,
                                     id: "history.filter.routine") {
                                    routine = (routine == name) ? nil : name
                                }
                            }
                        }
                    }
                    section("Tracking type") {
                        ForEach(SetKind.allCases, id: \.self) { kind in
                            chip(kind.display, symbol: kind.symbol, on: kinds.contains(kind),
                                 id: "history.filter.kind.\(kind.rawValue)") {
                                if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    // States the outcome rather than a bare "Done": you know what you're getting
                    // before you commit, and the number moves as you tap.
                    Text(isFiltering
                         ? "Show \(matchCount) session\(matchCount == 1 ? "" : "s")"
                         : "Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.workout)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .accessibilityIdentifier("history.filter.apply")
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear all", action: onClearAll)
                        .disabled(!isFiltering)
                        .accessibilityIdentifier("history.filter.clearAll")
                }
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder chips: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .kerning(0.8)
                .foregroundStyle(SnappetColor.textSecondary)
            FlexibleHStack(spacing: 8) { chips() }
        }
    }

    private func chip(_ label: String, symbol: String?, on: Bool, id: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption) }
                Text(label).lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(on ? SnappetColor.workout.opacity(0.2) : Color(.secondarySystemFill),
                        in: Capsule())
            .foregroundStyle(on ? SnappetColor.workout : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Where a history row came from — the Source facet (prompt 130). History shows EVERYTHING by
/// default; this is how the user narrows to one origin.
enum HistorySource: String, CaseIterable, Identifiable, Hashable {
    /// A session tracked in the app (routines, Quick Sessions) — has exercises and sets.
    case tracked
    /// A session imported from Apple Health, whoever wrote it (the Watch, Google Health, …).
    case imported

    var id: String { rawValue }
    var title: String { self == .tracked ? "Tracked" : "Imported" }
    var symbol: String { self == .tracked ? "dumbbell" : "heart.text.square" }

    static func of(_ session: WorkoutSession) -> HistorySource {
        session.isImportedFromHealth ? .imported : .tracked
    }
}

/// PURE history search/filter (issue #73) — unit-tested in `SnappetTests` without a simulator.
enum HistorySearch {
    /// Source facet first, then the routine-name chip (exact), then the tracking-type facet (any
    /// selected `SetKind`), then the search query (case-insensitive substring). Every facet is
    /// inert when empty/nil, so the default is "show everything" (prompt 130).
    static func apply(_ sessions: [WorkoutSession], query: String, routine: String?,
                      kinds: Set<SetKind> = [], sources: Set<HistorySource> = []) -> [WorkoutSession] {
        var result = sessions
        if !sources.isEmpty { result = result.filter { sources.contains(HistorySource.of($0)) } }
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
            // The glyph follows the real writer: ⌚ only for a genuine Watch recording, a neutral
            // health mark for anything another app wrote into Apple Health (prompt 129).
            Image(systemName: session.isFromAppleWatch ? "applewatch" : "heart.text.square")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SnappetColor.perfFresh)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.routineName).font(.headline).lineLimit(1)
                // Name the origin ("Google Health · Fri, Aug 21 at 6:30 PM") rather than letting a
                // ⌚-badged section imply a device that never recorded this.
                Text("\(session.importSourceLabel) · "
                     + session.startedAt.formatted(.dateTime.weekday().month().day().hour().minute()))
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
