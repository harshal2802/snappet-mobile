import SwiftUI
import SwiftData

/// Your Kilter history (Kilter Improvement P4): a grouped, scoped, filterable session timeline with
/// roll-up group headers, two consistency surfaces (a GitHub-style heatmap **and** a tappable month
/// calendar, both navigating), adaptive session cards (one badge max), faceted filter chips + search
/// with stale-filter recovery, and the full ascent log — with a link to the all-time analytics
/// dashboard. Pushed onto the App Library's shared NavigationStack by `KilterRootView`.
///
/// All grouping/scoping/filtering/adaptive-fact math lives in the pure, tested `KilterHistoryModel`
/// (+ `KilterConsistency` for the surfaces); this view is a renderer and does no math. P3's stats link
/// is kept; the active/recovered session is always visible + endable here (the recovery surface).
struct KilterHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SuiteRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Query(sort: \KilterLogEntry.date, order: .reverse) private var entries: [KilterLogEntry]
    @Query(sort: \KilterSession.startedAt, order: .reverse) private var allSessions: [KilterSession]

    @State private var scope: KilterHistoryModel.Scope = .month
    @State private var filters = KilterHistoryModel.Filters()
    /// The ascent being corrected from a swipe-to-edit (additive to the long-standing swipe-to-delete).
    @State private var editingAscent: KilterLogEntry?

    private let catalog = KilterCatalog.shared

    var body: some View {
        Group {
            if entries.isEmpty && sessions.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "figure.climbing",
                    description: Text("Climbs you log appear here."))
            } else {
                List {
                    statsLinkSection
                    scopeSection
                    if !sessions.isEmpty { consistencySection }
                    sessionsSection
                    ascentsSection
                }
                .searchable(text: $filters.search,
                            placement: .navigationBarDrawer(displayMode: .automatic),
                            prompt: "Search sessions or climbs")
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !entries.isEmpty || !sessions.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear all", role: .destructive) { clearAll() }
                        .accessibilityIdentifier("kilter.history.clear")
                }
            }
        }
        .sheet(item: $editingAscent) { ascent in
            KilterAscentEditSheet(entry: ascent)
        }
    }

    // MARK: - Sections

    /// A single doorway row into the all-time analytics dashboard (`KilterStatsView`). The numbers come
    /// from the tested `KilterAllTimeStats` (kept from P3 — do not re-derive figures here).
    private var statsLinkSection: some View {
        Section {
            Button { router.push(KilterStatsRoute()) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis").font(.title3)
                        .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("See your stats").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("Climbing level, grade pyramid & trends").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kilter.history.statsLink")
        }
    }

    /// The scope switcher (Week / Month / All) + the faceted filter chip rails, with stale-filter
    /// recovery: when a filter narrows everything away, a "Clear filters" row appears.
    @ViewBuilder private var scopeSection: some View {
        Section {
            Picker("Scope", selection: $scope) {
                ForEach(KilterHistoryModel.Scope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("kilter.history.scope")

            ForEach(KilterHistoryModel.Facet.allCases, id: \.self) { facet in
                if let values = model.facetValues[facet], !values.isEmpty {
                    facetChips(facet, values)
                }
            }

            // Scope-aware recovery (FG): when the current scope is empty under active filters, point at the
            // control that actually helps — widen scope if the matches are in another period, else clear.
            switch model.staleRecovery {
            case .widenScope:
                Button {
                    withAnimation(.snappy) { scope = .all }
                } label: {
                    Label("No sessions in this \(scope.label.lowercased()) — see all",
                          systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("kilter.history.widenScope")
            case .clearFilters:
                Button {
                    withAnimation(.snappy) { filters = KilterHistoryModel.Filters() }
                } label: {
                    Label("No sessions match — clear filters", systemImage: "xmark.circle")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("kilter.history.clearFilters")
            case .none:
                EmptyView()
            }
        }
    }

    /// One horizontal chip rail for a facet — each value toggles on tap, re-tap clears (single select).
    private func facetChips(_ facet: KilterHistoryModel.Facet, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(facet.label.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(facetLabelValues(facet, values), id: \.token) { entry in
                        let on = filters.selections[facet] == entry.token
                        Button {
                            withAnimation(.snappy) { filters.toggle(facet, entry.token) }
                        } label: {
                            Text(entry.label)
                                .font(.subheadline).lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(on ? SnappetColor.moduleAccent("kilter").opacity(0.2)
                                               : Color(.secondarySystemFill), in: Capsule())
                                .foregroundStyle(on ? SnappetColor.moduleAccent("kilter") : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.history.facetChip")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
        .listRowSeparator(.hidden)
    }

    /// Grade chips render through the user's grade-format preference; everything else is its raw token.
    private func facetLabelValues(_ facet: KilterHistoryModel.Facet,
                                  _ values: [String]) -> [(token: String, label: String)] {
        values.map { token in
            switch facet {
            case .grade: return (token, kilterGrade(token))
            case .status: return (token, KilterAscentStatus(rawValue: token)?.label ?? token)
            default: return (token, token)
            }
        }
    }

    /// Both consistency surfaces (user decision): a GitHub-style heatmap AND a tappable month calendar,
    /// each doubling as navigation into a day's session.
    @ViewBuilder private var consistencySection: some View {
        Section {
            KilterHeatmapView(days: KilterConsistency.heatmap(sessions: sessionItems, logs: climbLogs,
                                                              now: .now),
                              onSelectDay: openDay)
            KilterMonthCalendarView(days: KilterConsistency.monthDays(sessions: sessionItems,
                                                                      logs: climbLogs, month: .now),
                                    month: .now, onSelectDay: openDay)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// The grouped session timeline: a sticky roll-up header per period + adaptive cards under it.
    @ViewBuilder private var sessionsSection: some View {
        ForEach(model.groups) { group in
            Section {
                ForEach(group.rows) { row in
                    NavigationLink(value: KilterSessionRoute(id: row.session.id)) {
                        KilterSessionCard(card: row.card)
                    }
                    .accessibilityIdentifier("kilter.sessionRow")
                    .swipeActions(edge: .trailing) {
                        if row.session.isActive {
                            Button("End") { app.kilterSessions.end(sessionID: row.session.id, in: modelContext) }
                                .tint(.red)
                                .accessibilityIdentifier("kilter.session.endFromHistory")
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.headline).font(.headline).textCase(nil)
                    Text(group.summary).font(.caption).foregroundStyle(.secondary).textCase(nil)
                }
                .accessibilityIdentifier("kilter.history.groupHeader")
            }
        }
    }

    /// The full ascent log (unchanged leaf rows), now with swipe-to-EDIT alongside swipe-to-delete.
    private var ascentsSection: some View {
        Section("Ascents") {
            ForEach(entries) { entry in
                KilterAscentRow(entry: entry)
                    .accessibilityIdentifier("kilter.historyRow")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(entry) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { editingAscent = entry } label: { Label("Edit", systemImage: "pencil") }
                            .tint(.blue)
                            .accessibilityIdentifier("kilter.ascent.swipeEdit")
                    }
            }
        }
    }

    // MARK: - Derived data

    /// Sessions with logged entries, plus any **open** session — so a live/recovered session is always
    /// visible and endable here (the recovery surface of last resort), even before its first log.
    private var sessions: [KilterSession] {
        let used = Set(entries.compactMap(\.sessionId))
        return allSessions.filter { used.contains($0.id) || $0.isActive }
    }

    private var sessionItems: [KilterHistoryModel.SessionItem] {
        sessions.map(KilterHistoryModel.SessionItem.from)
    }
    private var climbLogs: [KilterClimbLog] { entries.map(KilterClimbLog.from) }

    /// `layoutId → name` from the catalog, for the Board facet + provenance (cheap; built once per render).
    private var layoutNames: [Int: String] {
        Dictionary(catalog.layouts().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// The pure grouped display model — rebuilt from the value-mirror inputs + UI state.
    private var model: KilterHistoryModel.DisplayModel {
        let names = layoutNames
        return KilterHistoryModel.build(sessions: sessionItems, logs: climbLogs,
                                        scope: scope, filters: filters, now: .now,
                                        layoutName: { names[$0] })
    }

    // MARK: - Navigation

    /// A tapped heatmap/calendar day → open its (first) session's detail route.
    private func openDay(_ day: KilterConsistency.Day) {
        guard let id = day.sessionIDs.first else { return }
        router.push(KilterSessionRoute(id: id))
    }

    /// Re-render a stored combined grade label per the user's format preference.
    private func kilterGrade(_ label: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "kilter.gradeFormat") ?? KilterGradeFormat.both.rawValue
        return kilterDisplayGrade(label, KilterGradeFormat(rawValue: raw) ?? .both)
    }

    // MARK: - Mutations

    private func delete(_ entry: KilterLogEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func clearAll() {
        // Never delete the in-flight session out from under the live bar — clear everything else.
        let activeID = allSessions.first { $0.isActive }?.id
        for entry in entries where entry.sessionId != activeID { modelContext.delete(entry) }
        for session in allSessions where !session.isActive { modelContext.delete(session) }
        try? modelContext.save()
    }
}

/// An adaptive session card (Kilter Improvement P4): the default Sends · Hardest · Duration facts with
/// at most ONE notable badge (PR / flash-rate / projects), a provenance glyph + label, and a live pulse
/// while the session is open. All selection happens in the pure `KilterHistoryModel.card`; this is a
/// renderer. The card pushes the UNCHANGED `KilterSessionRoute`.
private struct KilterSessionCard: View {
    let card: KilterHistoryModel.CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(displayTitle(card.title)).font(.headline).lineLimit(1)
                if card.isLive {
                    Label("Live", systemImage: "record.circle")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityIdentifier("kilter.card.live")
                }
                Spacer()
                if let badge = card.badge { badgeView(badge) }
            }
            HStack(spacing: 18) {
                ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
                    factView(fact)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Image(systemName: card.provenance.value == "BLE"
                      ? "antenna.radiowaves.left.and.right" : "hand.tap")
                    .font(.caption2)
                Text(card.provenance.label).font(.caption2)
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("kilter.card.provenance")
        }
        .padding(.vertical, 4)
    }

    private func displayTitle(_ title: String) -> String { title }

    private func factView(_ fact: KilterHistoryModel.CardFact) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(gradeAware(fact)).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(fact.label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func badgeView(_ badge: KilterHistoryModel.CardFact) -> some View {
        let (icon, tint) = badgeStyle(badge.kind)
        return Label("\(gradeAware(badge)) \(badge.label)", systemImage: icon)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityIdentifier("kilter.card.badge")
    }

    private func badgeStyle(_ kind: KilterHistoryModel.CardFact.Kind) -> (String, Color) {
        switch kind {
        case .prBadge: return ("trophy.fill", .orange)
        case .flashRate: return ("bolt.fill", .yellow)
        case .projects: return ("target", .blue)
        default: return ("sparkles", .secondary)
        }
    }

    /// Hardest / PR facts carry a grade label → render through the user's grade-format preference.
    private func gradeAware(_ fact: KilterHistoryModel.CardFact) -> String {
        switch fact.kind {
        case .hardest, .prBadge:
            let raw = UserDefaults.standard.string(forKey: "kilter.gradeFormat") ?? KilterGradeFormat.both.rawValue
            return kilterDisplayGrade(fact.value, KilterGradeFormat(rawValue: raw) ?? .both)
        default:
            return fact.value
        }
    }
}

/// One ascent row: status pill + climb name on top, grade · angle · date below.
private struct KilterAscentRow: View {
    let entry: KilterLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.status.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(statusColor.opacity(0.22), in: Capsule())
                    .foregroundStyle(statusColor)
                Text(entry.climbName).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
            }
            HStack {
                Text("\(entry.gradeLabel) · \(entry.angle)°").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .flash, .sent: return .green
        case .project: return .orange
        case .attempt: return .secondary
        }
    }
}

/// Correct a single logged ascent (swipe-to-edit): its status, attempts, and angle. Grade/name come
/// from the catalog at log time and aren't user-editable here — this is the fat-finger fix for the
/// fields a climber actually mis-taps. Writes straight back to the `@Model` (additive, no new fields).
private struct KilterAscentEditSheet: View {
    @Bindable var entry: KilterLogEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var status: KilterAscentStatus
    @State private var attempts: Int
    @State private var angle: Int

    init(entry: KilterLogEntry) {
        self.entry = entry
        _status = State(initialValue: entry.status)
        _attempts = State(initialValue: max(1, entry.attempts))
        _angle = State(initialValue: entry.angle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Climb") {
                    LabeledContent("Name", value: entry.climbName)
                    LabeledContent("Grade", value: entry.gradeLabel)
                }
                Section("Correct") {
                    Picker("Status", selection: $status) {
                        ForEach(KilterAscentStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("kilter.ascentEdit.status")
                    Stepper("Attempts: \(attempts)", value: $attempts, in: 1...99)
                        .accessibilityIdentifier("kilter.ascentEdit.attempts")
                    Stepper("Angle: \(angle)°", value: $angle, in: 0...70, step: 5)
                        .accessibilityIdentifier("kilter.ascentEdit.angle")
                }
            }
            .navigationTitle("Edit ascent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold)
                        .accessibilityIdentifier("kilter.ascentEdit.save")
                }
            }
        }
    }

    private func save() {
        entry.statusRaw = status.rawValue
        entry.attempts = attempts
        entry.angle = angle
        try? modelContext.save()
        dismiss()
    }
}
