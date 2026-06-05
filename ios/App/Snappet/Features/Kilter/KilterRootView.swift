import SwiftUI
import SwiftData

/// Route values pushed onto the App Library's shared `SuiteRouter` path.
struct KilterClimbRoute: Hashable { let uuid: String }
struct KilterHistoryRoute: Hashable {}
struct KilterSettingsRoute: Hashable {}
/// A finished (or active) board session's rich summary — HR zones, grade pyramid, per-climb
/// timeline, media + highlight reel.
struct KilterSessionRoute: Hashable { let id: UUID }

/// Kilter Board catalog: browse climbs from the bundled, read-only catalog, filtered by layout,
/// angle, and grade (plus a Saved filter), and open a climb for the board render + logging.
///
/// Pushed into the suite's NavigationStack by the App Library — owns no NavigationStack of its own;
/// deeper screens (detail, history) push onto the shared `SuiteRouter` path.
struct KilterRootView: View {
    @Environment(SuiteRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [KilterFavorite]
    @Query private var allEntries: [KilterLogEntry]

    private let catalog = KilterCatalog.shared
    /// Shared across the module's screens (detail illuminates / sessions group history).
    @State private var board = KilterBoardController()
    @State private var sessions = KilterSessionManager()

    @AppStorage("kilter.angle") private var angle: Int = 40
    @AppStorage("kilter.layout") private var layoutId: Int = 1
    @AppStorage("kilter.minGrade") private var minGrade: Int = 10
    @AppStorage("kilter.maxGrade") private var maxGrade: Int = 33
    @State private var savedOnly = false
    @State private var items: [KilterListItem] = []
    @State private var showingScanner = false

    // Search + advanced filters.
    @State private var search = ""
    @State private var sort: KilterSort = .popular
    @State private var benchmarksOnly = false
    @State private var minAscents = 0
    @State private var minQuality = 0.0
    @State private var showingFilters = false

    // Discovery + display preference.
    @State private var cotd: KilterListItem?
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    private var gradeFormat: KilterGradeFormat { KilterGradeFormat(rawValue: gradeFormatRaw) ?? .both }
    /// Discovery (climb-of-the-day) shows only on the plain browse view, not while searching/saved.
    private var showDiscovery: Bool { search.trimmingCharacters(in: .whitespaces).isEmpty && !savedOnly }

    /// The current browse criteria assembled into one value (drives the catalog query + `.task` id).
    private var filter: KilterFilter {
        KilterFilter(layoutId: layoutId, angle: angle,
                     minDifficulty: Double(minGrade), maxDifficulty: Double(maxGrade),
                     search: search, sort: sort, benchmarksOnly: benchmarksOnly,
                     minAscents: minAscents, minQuality: minQuality)
    }

    /// The climbs currently on screen, in display order — handed to the detail view so the user can
    /// swipe left/right between them. Climb-of-the-day leads when shown; deduped (it often recurs in
    /// the list).
    private var browseUUIDs: [String] {
        var ids: [String] = []
        if showDiscovery, let cotd { ids.append(cotd.uuid) }
        ids.append(contentsOf: items.map(\.uuid))
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private var layouts: [KilterLayout] { catalog.layouts() }
    private var availableAngles: [Int] { catalog.angles() }
    private var gradeScale: [(difficulty: Int, label: String)] { catalog.gradeScale() }
    private var favoriteUUIDs: Set<String> { Set(favorites.map(\.climbUUID)) }

    var body: some View {
        Group {
            if catalog.isAvailable {
                content
            } else {
                ContentUnavailableView("Catalog unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("The bundled Kilter catalog couldn't be opened."))
            }
        }
        .navigationTitle("Kilter Board")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search climbs or setters")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingFilters = true } label: {
                    Label("Filters", systemImage: filter.activeExtras > 0
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("kilter.filtersButton")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { router.push(KilterHistoryRoute()) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("kilter.history")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if sessions.isActive {
                        Button(role: .destructive) { sessions.end(in: modelContext) } label: {
                            Label("End session", systemImage: "stop.circle")
                        }
                    } else {
                        Button { sessions.start(angle: angle, source: "manual", in: modelContext) } label: {
                            Label("Start session", systemImage: "play.circle")
                        }
                    }
                    Button { surpriseMe() } label: { Label("Surprise me", systemImage: "dice") }
                        .accessibilityIdentifier("kilter.surprise")
                    Button { showingScanner = true } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("kilter.scan")
                    Divider()
                    Button { router.push(KilterSettingsRoute()) } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("kilter.more")
            }
        }
        .sheet(isPresented: $showingFilters) {
            KilterFiltersSheet(sort: $sort, benchmarksOnly: $benchmarksOnly,
                               minAscents: $minAscents, minQuality: $minQuality)
        }
        .sheet(isPresented: $showingScanner) {
            KilterScannerView { link in
                // Open at the shared angle the sharer used, when it's one this board offers.
                if let a = link.angle, availableAngles.contains(a) { angle = a }
                router.push(KilterClimbRoute(uuid: link.uuid))
            }
        }
        .navigationDestination(for: KilterClimbRoute.self) { route in
            KilterClimbDetailView(uuid: route.uuid, siblings: browseUUIDs, board: board, sessions: sessions)
        }
        .navigationDestination(for: KilterHistoryRoute.self) { _ in
            KilterHistoryView()
        }
        .navigationDestination(for: KilterSettingsRoute.self) { _ in
            KilterSettingsView(catalog: catalog)
        }
        .navigationDestination(for: KilterSessionRoute.self) { route in
            KilterSessionDetailView(sessionID: route.id, board: board, sessions: sessions)
        }
        .task(id: filterKey) { refresh() }
        // Wire the session manager to the app's live-metrics / Live-Activity / media services so a
        // session (started here or auto-opened on board connect) drives HR + the Live Activity.
        .onAppear {
            sessions.bind(liveWorkout: app.liveWorkout,
                          liveActivity: app.kilterLiveActivity,
                          media: app.sessionMedia)
        }
        // Keep the Live Activity's HR / climb count current while any Kilter screen is up (the root
        // view stays in the nav stack), throttled inside the controller.
        .onChange(of: app.liveWorkout.latestHR) { pushLiveActivity() }
        .onChange(of: sessions.activeClimbName) { pushLiveActivity() }
        .onChange(of: currentClimbCount) { pushLiveActivity() }
    }

    /// Climbs logged so far in the active session (the count shown in the banner + Live Activity).
    private var currentClimbCount: Int {
        guard let id = sessions.currentId else { return 0 }
        return allEntries.filter { $0.sessionId == id }.count
    }

    private func pushLiveActivity() {
        guard sessions.isActive else { return }
        sessions.pushLiveActivity(hrBpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
                                  climbCount: currentClimbCount)
    }

    /// Push a random climb from the current filters (Discovery "Surprise me").
    private func surpriseMe() {
        if let pick = catalog.randomClimb(filter) { router.push(KilterClimbRoute(uuid: pick.uuid)) }
    }

    private var content: some View {
        VStack(spacing: 0) {
            filterBar
            if sessions.isActive { sessionBar }
            List {
                if showDiscovery, let cotd {
                    Section("Climb of the day") {
                        Button { router.push(KilterClimbRoute(uuid: cotd.uuid)) } label: {
                            KilterClimbRow(item: cotd, isFavorite: favoriteUUIDs.contains(cotd.uuid),
                                           gradeFormat: gradeFormat, featured: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.cotd")
                    }
                }
                Section {
                    ForEach(items) { item in
                        Button { router.push(KilterClimbRoute(uuid: item.uuid)) } label: {
                            KilterClimbRow(item: item, isFavorite: favoriteUUIDs.contains(item.uuid),
                                           gradeFormat: gradeFormat)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kilter.climbRow")
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if items.isEmpty && !(showDiscovery && cotd != nil) {
                    let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
                    ContentUnavailableView(
                        searching ? "No matches" : (savedOnly ? "No saved climbs" : "No climbs match"),
                        systemImage: searching ? "magnifyingglass" : (savedOnly ? "star" : "line.3.horizontal.decrease.circle"),
                        description: Text(searching ? "No climbs match “\(search)” with the current filters."
                                          : (savedOnly ? "Star climbs to find them here."
                                                       : "Try a wider grade range, another angle, or fewer filters.")))
                }
            }
        }
    }

    /// Active-session banner: a live timer, climb count, live HR (when a source is connected), and
    /// the current climb, with End. Tapping it opens the live summary. Logs made while it's up are
    /// grouped under the session in History.
    @ViewBuilder private var sessionBar: some View {
        if let s = sessions.current {
            let count = allEntries.filter { $0.sessionId == s.id }.count
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle").foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .repeating)
                        .font(.subheadline)
                    Text("Session").font(.subheadline.weight(.semibold))
                    Text(s.startedAt, style: .timer).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Text("· \(count) climb\(count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if app.liveWorkout.state != .unavailable {
                        KilterHRPill(bpm: app.liveWorkout.latestHR, compact: true)
                    }
                    Button("End") { withAnimation(.snappy) { sessions.end(in: modelContext) } }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("kilter.session.end")
                }
                Button { router.push(KilterSessionRoute(id: s.id)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.climbing").font(.caption)
                        Text(sessions.activeClimbName).font(.caption.weight(.medium)).lineLimit(1)
                        if !sessions.activeClimbGrade.isEmpty {
                            Text(sessions.activeClimbGrade).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kilter.session.open")
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(Color.green.opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var filterBar: some View {
        // The Layout/Angle/Grade menus scroll horizontally; the Saved toggle is pinned at the trailing
        // edge so it's always reachable (it used to overflow off-screen on narrower devices).
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Menu {
                        Picker("Layout", selection: $layoutId) {
                            ForEach(layouts) { Text($0.name).tag($0.id) }
                        }
                    } label: { chip("Layout", layouts.first { $0.id == layoutId }?.name ?? "—") }
                    .accessibilityIdentifier("kilter.layout")

                    Menu {
                        Picker("Angle", selection: $angle) {
                            ForEach(availableAngles, id: \.self) { Text("\($0)°").tag($0) }
                        }
                    } label: { chip("Angle", "\(angle)°") }
                    .accessibilityIdentifier("kilter.angle")

                    // Lower/upper grade are two independent chips. Selecting a min above the current
                    // max (or a max below the min) drags the other end along so the range stays valid.
                    Menu {
                        Picker("Min grade", selection: $minGrade) {
                            ForEach(gradeScale, id: \.difficulty) { Text($0.label).tag($0.difficulty) }
                        }
                    } label: { chip("Min", catalog.gradeLabel(Double(minGrade))) }
                    .accessibilityIdentifier("kilter.minGrade")
                    .onChange(of: minGrade) { _, newMin in if newMin > maxGrade { maxGrade = newMin } }

                    Menu {
                        Picker("Max grade", selection: $maxGrade) {
                            ForEach(gradeScale, id: \.difficulty) { Text($0.label).tag($0.difficulty) }
                        }
                    } label: { chip("Max", catalog.gradeLabel(Double(maxGrade))) }
                    .accessibilityIdentifier("kilter.maxGrade")
                    .onChange(of: maxGrade) { _, newMax in if newMax < minGrade { minGrade = newMax } }
                }
                .padding(.leading)
                .padding(.vertical, 8)
            }

            Button { savedOnly.toggle() } label: {
                chip("", "Saved", filled: savedOnly, systemImage: savedOnly ? "star.fill" : "star")
            }
            .accessibilityIdentifier("kilter.savedToggle")
            .padding(.trailing)
        }
    }

    private func chip(_ title: String, _ value: String, filled: Bool = false, systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            if !title.isEmpty { Text(title).foregroundStyle(.secondary) }
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground)),
                    in: Capsule())
        .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    /// Identity for `.task(id:)` — recompute the list whenever any criterion (or the favorites set) changes.
    private var filterKey: String {
        "\(layoutId)|\(angle)|\(minGrade)|\(maxGrade)|\(savedOnly)|\(favoriteUUIDs.count)"
        + "|\(search)|\(sort.rawValue)|\(benchmarksOnly)|\(minAscents)|\(minQuality)"
    }

    private func refresh() {
        guard catalog.isAvailable else { items = []; cotd = nil; return }
        cotd = showDiscovery ? catalog.climbOfTheDay(layoutId: layoutId, angle: angle) : nil
        if savedOnly {
            // Saved list isn't grade/angle-restricted, but still honor the search box (name/setter).
            let saved = favorites.sorted { $0.addedAt > $1.addedAt }.map(\.climbUUID)
            let all = catalog.climbsByUUID(saved)
            let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            items = term.isEmpty ? all
                : all.filter { $0.name.lowercased().contains(term) || $0.setter.lowercased().contains(term) }
        } else {
            items = catalog.list(filter)
        }
    }
}

/// One catalog row: name + setter, grade badge, quality stars, ascent count.
private struct KilterClimbRow: View {
    let item: KilterListItem
    let isFavorite: Bool

    var gradeFormat: KilterGradeFormat = .both
    /// Featured (climb-of-the-day) rows get a small ribbon accent.
    var featured: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if featured {
                Image(systemName: "sparkles").foregroundStyle(SnappetColor.moduleAccent("kilter"))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.headline).lineLimit(1)
                    if isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                Text("by \(item.setter)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(kilterDisplayGrade(item.gradeLabel, gradeFormat))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
                HStack(spacing: 6) {
                    KilterStars(quality: item.quality)
                    Label("\(item.ascents)", systemImage: "person.2.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 0–3 filled stars from a quality average.
struct KilterStars: View {
    let quality: Double
    var body: some View {
        let filled = Int(quality.rounded())
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: i < filled ? "star.fill" : "star")
                    .font(.caption2).foregroundStyle(.yellow)
            }
        }
        .accessibilityLabel("Quality \(filled) of 3")
    }
}

/// Bottom sheet of advanced browse criteria: sort order, a classics/benchmarks toggle, and minimum
/// ascents/quality. The quick layout/angle/grade/saved chips stay inline; this holds the rest so the
/// filter row doesn't get crowded.
struct KilterFiltersSheet: View {
    @Binding var sort: KilterSort
    @Binding var benchmarksOnly: Bool
    @Binding var minAscents: Int
    @Binding var minQuality: Double
    @Environment(\.dismiss) private var dismiss

    private let ascentChoices = [0, 10, 50, 100, 500, 1000]

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort by") {
                    Picker("Sort", selection: $sort) {
                        ForEach(KilterSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    .accessibilityIdentifier("kilter.filter.sort")
                }
                Section("Refine") {
                    Toggle(isOn: $benchmarksOnly) {
                        Label("Classics only", systemImage: "rosette")
                    }
                    .accessibilityIdentifier("kilter.filter.benchmarks")
                    Picker("Min ascents", selection: $minAscents) {
                        ForEach(ascentChoices, id: \.self) { Text($0 == 0 ? "Any" : "\($0)+").tag($0) }
                    }
                    Picker("Min quality", selection: $minQuality) {
                        Text("Any").tag(0.0)
                        Text("★ 1+").tag(1.0)
                        Text("★ 2+").tag(2.0)
                        Text("★ 3").tag(3.0)
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        sort = .popular; benchmarksOnly = false; minAscents = 0; minQuality = 0
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("kilter.filter.done")
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
