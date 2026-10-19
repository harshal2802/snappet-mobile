import SwiftUI
import SwiftData
import Charts

/// Routing payload for one activity's dashboard (activity progress P2, prompt 179). `ProgressRoute` (the
/// library / dashboard entry) now lands here too.
struct ActivityRoute: Hashable {
    let key: ActivityKey
    let title: String
}

/// **The Activity page** (activity progress P2 → Library redesign L2, prompt 184): one page per activity with
/// **Progress** (KPI tiles · the hero metric over time — filmed points carry a 📷 and play their clip · effort ·
/// records · frequency · a clips strip), **Clips** (every clip, PR filter, Compare, Progress reel) and **About**
/// (a catalog move's how-to, or your latest instance's details). **Log it now** / **Add to routine** sit at the
/// bottom. A catalog move you've never logged opens on About.
struct ActivityDashboardView: View {
    /// The activity — state, because a rename or merge (prompt 185) can move it to a new identity.
    @State private var key: ActivityKey
    @State private var title: String
    let history: [WorkoutSession]
    let unit: WeightUnit
    /// The catalog move behind this activity (a strength `exerciseId`), for the About tab's how-to.
    var catalogExercise: Exercise? = nil

    init(key: ActivityKey, title: String, history: [WorkoutSession], unit: WeightUnit, catalogExercise: Exercise? = nil) {
        _key = State(initialValue: key)
        _title = State(initialValue: title)
        self.history = history
        self.unit = unit
        self.catalogExercise = catalogExercise
    }

    enum Tab: String { case progress, clips, about }

    @Environment(\.modelContext) private var context
    @Environment(SuiteRouter.self) private var router
    @Query(sort: \Routine.updatedAt, order: .reverse) private var routines: [Routine]
    @State private var tab: Tab = .progress
    @State private var toast: String?
    /// A rename / merge that can still be undone from the toast (prompt 185).
    @State private var undo: UndoStep?
    @State private var renaming = false
    @State private var newName = ""
    /// The merge sheet's payload — `sheet(item:)`, because an isPresented sheet reading separate state shows stale
    /// (empty) content when the body never reads that state.
    @State private var mergeRequest: MergeRequest?
    /// Bumped after a rename / merge rewrote history, so the page reloads.
    @State private var revision = 0
    @State private var tabChosen = false
    @Query private var entries: [LibraryEntry]

    private struct MergeRequest: Identifiable {
        let id = UUID()
        let target: LibraryCatalog.Row
        let candidates: [LibraryCatalog.Row]
    }

    private struct UndoStep {
        let changes: [LibraryMaintenance.Change]
        let key: ActivityKey
        let title: String
    }
    @State private var dashboard: ActivityDashboard?
    @State private var groups: [ActivitySessionGroup] = []
    /// HR-per-set trend and (for a climbing overview) the named climbs inside it — prompt 181.
    @State private var effort: ActivityInsights.Effort?
    @State private var climbs: [LibraryCatalog.Row] = []
    @State private var loaded = false
    @State private var selected: UUID?
    @State private var viewing: ViewerRequest?
    @State private var comparing = false
    @State private var reelScope: ClipsReelScope?

    private struct ViewerRequest: Identifiable {
        let id = UUID()
        let clips: [ActivityClip]
        let start: Int
    }

    private var accent: Color { dashboard?.discipline.accent ?? SnappetColor.workout }
    private var allClips: [ActivityClip] { groups.flatMap(\.clips) }
    private var badges: [UUID: ActivityProgressReel.Badge] { dashboard.map(ActivityProgressReel.badges) ?? [:] }
    private var videos: [ActivityClip] { ActivityProgressReel.pick(allClips, rule: .all, badges: badges) }

    private var tabs: [Tab] {
        var t: [Tab] = []
        if dashboard != nil { t.append(.progress) }
        if !allClips.isEmpty { t.append(.clips) }
        t.append(.about)
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            if loaded && tabs.count > 1 {
                Picker("Section", selection: $tab) {
                    ForEach(tabs, id: \.self) { t in Text(label(t)).tag(t) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("activity.tabs")
            }
            switch tab {
            case .progress: progressTab
            case .clips:
                ActivityClipsContent(target: ActivityClipsTarget(key: key, title: title), history: history, unit: unit)
            case .about:
                if let ex = catalogExercise {
                    ExerciseDetailView(exercise: ex, history: history, unit: unit)
                } else {
                    ActivityAboutView(key: key, title: title, history: history, unit: unit, template: template)
                }
            }
        }
        .background(SnappetColor.paper)
        .safeAreaInset(edge: .bottom) { bottomArea }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if key.disciplineScope == nil { ToolbarItem(placement: .primaryAction) { manageMenu } } }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName).accessibilityIdentifier("activity.rename.field")
            Button("Rename") { rename(to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames it in every session it was logged in.")
        }
        .sheet(item: $mergeRequest) { req in
            LibraryMergeSheet(target: req.target, candidates: req.candidates) { merge($0) }
        }
        .task(id: "\(key.exerciseId)|\(key.nameKey)|\(revision)") {
            let media = ActivityMediaStore.snapshot(context: context)
            dashboard = ActivityDashboard.make(key: key, history: history, media: media, unit: unit)
            groups = ActivityMediaIndex.groups(for: key, history: history, media: media, unit: unit,
                                               distanceUnit: unit == .lb ? .mi : .km)
            effort = ActivityInsights.effort(key: key, history: history, unit: unit)
            if key.disciplineScope == .climb {
                let all = LibraryCatalog.yours(history: history, identity: ActivityIdentity(sessions: history),
                                               unit: unit, title: LibraryCatalog.fallbackTitle)
                climbs = LibraryCatalog.sorted(all.filter { $0.discipline == .climb }, by: .recent)
            }
            // Never logged → the how-to is the useful page.
            if !tabChosen { tabChosen = true; if dashboard == nil { tab = .about } }
            if !tabs.contains(tab) { tab = tabs.first ?? .about }
            loaded = true
        }
        .fullScreenCover(item: $viewing) { req in
            ActivityClipViewer(clips: req.clips, startIndex: req.start,
                               sessions: ClipHRSource.map(history))
        }
        .sheet(isPresented: $comparing) { ActivityComparePicker(clips: videos) }
        .navigationDestination(item: $reelScope) { scope in WeeklyReelHostView(scope: scope) }
    }

    private func label(_ t: Tab) -> String {
        switch t {
        case .progress: return "Progress"
        case .clips: return "Clips · \(allClips.count)"
        case .about: return "About"
        }
    }

    // MARK: - Log it now / Add to routine (prompt 184)

    /// The toast (with Undo for a rename / merge) above the action bar.
    @ViewBuilder private var bottomArea: some View {
        VStack(spacing: 8) {
            if let toast {
                HStack(spacing: 12) {
                    Text(toast).font(.subheadline.weight(.semibold)).accessibilityIdentifier("activity.toast")
                    if undo != nil {
                        Button("Undo") { undoLast() }
                            .font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.workout)
                            .accessibilityIdentifier("activity.undo")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if tab != .clips && ActivityLauncher.canLaunch(key) { actionBar }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
        HStack(spacing: 10) {
            Button { logNow() } label: {
                Label("Log it now", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
            .accessibilityIdentifier("activity.logNow")
            Menu {
                if routines.isEmpty {
                    Text("No routines yet")
                } else {
                    ForEach(routines) { r in
                        Button(r.name) { addToRoutine(r) }
                    }
                }
            } label: {
                Label("Add to routine", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("activity.addToRoutine")
        }
        }
        .controlSize(.large)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private func logNow() {
        guard let entity = ActivityLauncher.sessionExercise(for: key, history: history,
                                                           identity: ActivityIdentity(sessions: history),
                                                           catalogExerciseId: catalogExercise?.id,
                                                           template: template) else { return }
        // Hand it to the Gym Tracker home and pop back to it: a view under a pushed page doesn't run its change
        // handlers, and the player is a cover the home presents. Pop everything above the module root (path[0]).
        router.pendingQuickLog = entity
        if router.path.count > 1 { router.path.removeLast(router.path.count - 1) }
    }

    private func addToRoutine(_ routine: Routine) {
        guard let block = ActivityLauncher.routineBlock(for: key, history: history,
                                                        identity: ActivityIdentity(sessions: history),
                                                        defaultUnit: unit,
                                                        catalogExerciseId: catalogExercise?.id,
                                                        template: template) else { return }
        routine.exercises.append(block)
        routine.updatedAt = .now
        try? context.save()
        show("Added to \(routine.name)")
    }

    /// A transient toast (announced to VoiceOver); an undoable one stays a little longer.
    private func show(_ message: String, undo step: UndoStep? = nil) {
        withAnimation { toast = message; undo = step }
        AccessibilityNotification.Announcement(message).post()
        let shown = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(step == nil ? 3 : 6))
            if toast == shown { withAnimation { toast = nil; undo = nil } }
        }
    }

    // MARK: - Pin · Rename · Merge · Hide (prompt 185)

    private var entry: LibraryEntry? { entries.first { $0.key == key } }
    /// A created activity's template (prompt 186) — what Log it now / Add to routine / About use until it's logged.
    private var template: LibraryTemplate? { entry?.template }

    private var manageMenu: some View {
        Menu {
            Button { setFlag(pin: !(entry?.isPinned ?? false)) } label: {
                Label(entry?.isPinned == true ? "Unpin" : "Pin to top", systemImage: entry?.isPinned == true ? "pin.slash" : "pin")
            }
            if LibraryMaintenance.canRename(key) {
                Button { newName = title; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                    .accessibilityIdentifier("activity.rename")
            }
            if LibraryMaintenance.canMerge(key) {
                Button { openMerge() } label: { Label("Merge with…", systemImage: "arrow.triangle.merge") }
                    .accessibilityIdentifier("activity.merge")
            }
            Button { setFlag(hide: !(entry?.isHidden ?? false)) } label: {
                Label(entry?.isHidden == true ? "Show in Library" : "Hide from Library",
                      systemImage: entry?.isHidden == true ? "eye" : "eye.slash")
            }
            // A created activity you never logged can simply go (prompt 186) — nothing in history to keep.
            if template != nil && dashboard == nil {
                Button(role: .destructive) { deleteCreated() } label: { Label("Delete", systemImage: "trash") }
                    .accessibilityIdentifier("activity.deleteCreated")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("activity.manage")
        .accessibilityLabel("More")
    }

    private func deleteCreated() {
        if let e = entry { context.delete(e); try? context.save() }
        if router.path.count > 1 { router.path.removeLast() }
    }

    private func setFlag(pin: Bool? = nil, hide: Bool? = nil) {
        guard let e = LibraryEntry.entry(for: key, in: context, create: true) else { return }
        if let pin { e.isPinned = pin }
        if let hide { e.isHidden = hide }
        e.updatedAt = .now
        let message = pin.map { $0 ? "Pinned to the top" : "Unpinned" } ?? (hide == true ? "Hidden from Library" : "Shown in Library")
        if !e.isPinned && !e.isHidden && e.templateData == nil { context.delete(e) }
        try? context.save()
        show(message)
    }

    private func rename(to name: String) {
        let changes = LibraryMaintenance.rename(key, to: name, sessions: history, identity: ActivityIdentity(sessions: history))
        guard !changes.isEmpty else { return }
        let step = UndoStep(changes: changes, key: key, title: title)
        apply(changes, newTitle: name.trimmingCharacters(in: .whitespacesAndNewlines))
        show("Renamed", undo: step)
    }

    private func openMerge() {
        let rows = LibraryCatalog.yours(history: history, identity: ActivityIdentity(sessions: history), unit: unit,
                                        title: LibraryCatalog.fallbackTitle)
        guard let target = rows.first(where: { $0.key == key }) else { return }
        mergeRequest = MergeRequest(target: target, candidates: rows.filter {
            $0.key != key && $0.discipline == target.discipline && LibraryMaintenance.canMerge($0.key)
        })
    }

    private func merge(_ sources: [ActivityKey]) {
        let changes = LibraryMaintenance.merge(sources, into: key, sessions: history,
                                               identity: ActivityIdentity(sessions: history))
        guard !changes.isEmpty else { return }
        let step = UndoStep(changes: changes, key: key, title: title)
        apply(changes, newTitle: title)
        show("Merged \(Set(changes.map(\.sessionID)).count) \(Set(changes.map(\.sessionID)).count == 1 ? "session" : "sessions")", undo: step)
    }

    /// Write the changes, then follow the activity to its (possibly new) identity — moving its pin / hide with it.
    private func apply(_ changes: [LibraryMaintenance.Change], newTitle: String) {
        let anchor = anchorEntity(changes)
        LibraryMaintenance.apply(changes, to: history)
        try? context.save()
        follow(anchor: anchor, title: newTitle)
    }

    private func undoLast() {
        guard let step = undo else { return }
        let anchor = anchorEntity(step.changes)
        LibraryMaintenance.apply(step.changes, to: history, undo: true)
        try? context.save()
        withAnimation { toast = nil; undo = nil }
        follow(anchor: anchor, title: step.title, fallback: step.key)
    }

    /// An entity of THIS activity to re-find it by after history changed (the latest one).
    private func anchorEntity(_ changes: [LibraryMaintenance.Change]) -> UUID? {
        let ids = ActivityIdentity(sessions: history)
        for s in history.sorted(by: { $0.startedAt > $1.startedAt }) {
            if let ex = s.exercises.first(where: { ids.key(for: $0, loggedAt: s.startedAt) == key }) { return ex.id }
        }
        return changes.last?.exerciseID
    }

    private func follow(anchor: UUID?, title newTitle: String, fallback: ActivityKey? = nil) {
        let ids = ActivityIdentity(sessions: history)
        var newKey = fallback ?? key
        if let anchor {
            for s in history {
                if let ex = s.exercises.first(where: { $0.id == anchor }), let k = ids.key(for: ex, loggedAt: s.startedAt) {
                    newKey = k
                }
            }
        }
        if newKey != key, let e = entry {
            e.activityKeyRaw = LibraryEntry.raw(newKey)      // the pin / hide follows the activity
            try? context.save()
        }
        key = newKey
        title = newTitle
        revision += 1
    }

    // MARK: - Progress

    private var progressTab: some View {
        ScrollView {
            if let d = dashboard {
                VStack(alignment: .leading, spacing: 14) {
                    kpiRow(d)
                    chartCard(d)
                    if let effort { effortCard(effort) }
                    if !allClips.isEmpty { clipsCard }
                    if !climbs.isEmpty { climbsCard }
                    recordsCard(d)
                    if d.discipline == .climb, key.disciplineScope == nil {
                        NavigationLink(value: ActivityRoute(key: .discipline(.climb), title: "Climbing")) {
                            Label("All climbing", systemImage: "figure.climbing").font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("activity.dashboard.allClimbing")
                    }
                    frequencyCard(d)
                }
                .padding(16)
            }
        }
        .accessibilityIdentifier("activity.dashboard")
    }

    // MARK: - Cards

    private func kpiRow(_ d: ActivityDashboard) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(d.kpis.enumerated()), id: \.offset) { _, k in
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Text(k.value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(k.detail ?? " ").font(.caption2.weight(.semibold))
                        .foregroundStyle(k.improving ? SnappetColor.perfFresh : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .accessibilityIdentifier("activity.dashboard.kpis")
    }

    private func card<Content: View>(_ title: String, trailing: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.bold))
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(12)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func chartCard(_ d: ActivityDashboard) -> some View {
        let selectedPoint = d.points.first { $0.sessionID == selected }
        return card(d.metric.title, trailing: d.points.contains(where: \.hasMedia) ? "📷 = has clips" : nil) {
            if d.points.count >= 2 {
                Chart {
                    ForEach(d.points) { p in
                        LineMark(x: .value("Date", p.date), y: .value(d.metric.title, p.value))
                            .foregroundStyle(accent)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", p.date), y: .value(d.metric.title, p.value))
                            .foregroundStyle(p.hasMedia ? SnappetColor.brand : accent)
                            .symbolSize(p.hasMedia ? 110 : 30)
                            .annotation(position: .top, spacing: 2) {
                                if p.hasMedia { Image(systemName: "video.fill").font(.system(size: 8)).foregroundStyle(SnappetColor.brand) }
                            }
                    }
                    if let s = selectedPoint {
                        RuleMark(x: .value("Date", s.date)).foregroundStyle(.secondary.opacity(0.4))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false, reversed: !d.metric.higherIsBetter))
                .chartYAxis(d.metric == .hardestSend ? .hidden : .automatic)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in select(at: location, proxy: proxy, geo: geo, points: d.points) }
                    }
                }
                .frame(height: 180)
                .accessibilityIdentifier("activity.dashboard.chart")
            } else if let only = d.points.first {
                Text(only.label).font(.title2.bold()).monospacedDigit()
                Text("One session so far — the trend appears after the next.").font(.caption).foregroundStyle(.secondary)
            }
            if let s = selectedPoint { selectionRow(s) }
        }
    }

    private func selectionRow(_ p: ActivityDashboard.Point) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.label).font(.subheadline.weight(.bold)).monospacedDigit()
                Text(p.date, format: .dateTime.day().month(.abbreviated).year()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p.hasMedia {
                Button { play(session: p.sessionID) } label: {
                    Label("Play clip", systemImage: "play.fill").font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.brand)
                .accessibilityIdentifier("activity.dashboard.playSelected")
            }
        }
        .padding(.top, 4)
    }

    private var clipsCard: some View {
        card("Clips", trailing: "\(allClips.count)") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(allClips.prefix(12).enumerated()), id: \.element.id) { i, clip in
                        Button { viewing = ViewerRequest(clips: allClips, start: i) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                ClipThumbnail(localIdentifier: clip.media.localIdentifier, kind: clip.media.kindRaw,
                                              size: CGSize(width: 64, height: 84), exactFrame: false)
                                // A climb's attempt reads better by outcome ("V5 · Sent") than by date.
                                Group {
                                    if dashboard?.discipline == .climb, let s = clip.setSummary { Text(s) }
                                    else { Text(clip.sessionDate, format: .dateTime.day().month(.abbreviated)) }
                                }
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 64, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 16) {
                Button("See all clips") { withAnimation { tab = .clips } }
                    .accessibilityIdentifier("activity.dashboard.allClips")
                Spacer()
                if videos.count >= 2 {
                    Button("Compare") { comparing = true }
                        .accessibilityIdentifier("activity.dashboard.compare")
                    Menu("Progress reel") {
                        ForEach(ActivityProgressReel.Rule.allCases) { rule in
                            Button(rule.label) {
                                let picks = ActivityProgressReel.pick(allClips, rule: rule, badges: badges)
                                if !picks.isEmpty { reelScope = ActivityProgressReel.scope(for: picks, title: title) }
                            }
                        }
                    }
                    .accessibilityIdentifier("activity.dashboard.reel")
                }
            }
            .font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .contain)   // keeps the buttons' own identifiers
        .accessibilityIdentifier("activity.dashboard.clips")
    }

    private func effortCard(_ e: ActivityInsights.Effort) -> some View {
        let delta = e.change
        let trailing = delta == 0 ? "steady" : "\(delta > 0 ? "+" : "−")\(abs(delta)) bpm\(e.fitter ? " · fitter" : "")"
        return card(e.title, trailing: trailing) {
            Chart(e.points) { p in
                LineMark(x: .value("Date", p.date), y: .value("bpm", p.bpm))
                    .foregroundStyle(SnappetColor.perfHard).interpolationMethod(.monotone)
                PointMark(x: .value("Date", p.date), y: .value("bpm", p.bpm))
                    .foregroundStyle(SnappetColor.perfHard).symbolSize(20)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 90)
            Text(e.referenceKg != nil
                 ? "The same weight costing fewer beats means you're fitter."
                 : "Average peak heart rate across your sets each session.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.dashboard.effort")
    }

    /// The named climbs inside a climbing overview — each opens its own dashboard (prompt 181).
    private var climbsCard: some View {
        card("Climbs", trailing: "\(climbs.count)") {
            ForEach(climbs.prefix(15)) { c in
                NavigationLink(value: ActivityRoute(key: c.key, title: c.title)) {
                    LibraryYoursRow(row: c, unit: unit)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activity.dashboard.climb")
            }
        }
    }

    private func recordsCard(_ d: ActivityDashboard) -> some View {
        card("Records") {
            ForEach(d.records) { r in
                let clip = groups.first { $0.sessionID == r.sessionID }?.clips.first
                if let clip {
                    Button { play(session: r.sessionID) } label: { recordRow(r, clip: clip) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("activity.dashboard.record")
                } else {
                    recordRow(r, clip: nil)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("activity.dashboard.record")
                }
            }
        }
    }

    private func recordRow(_ r: ActivityDashboard.Record, clip: ActivityClip?) -> some View {
        HStack(spacing: 10) {
            if let clip {
                ClipThumbnail(localIdentifier: clip.media.localIdentifier, kind: clip.media.kindRaw,
                              size: CGSize(width: 34, height: 34), exactFrame: false)
            } else {
                Image(systemName: "trophy.fill").foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.caption).foregroundStyle(.secondary)
                Text(r.value).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            Spacer()
            Text(r.date, format: .dateTime.day().month(.abbreviated)).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func frequencyCard(_ d: ActivityDashboard) -> some View {
        let peak = max(1, d.weeks.max() ?? 1)
        return card("Frequency", trailing: "\(ActivityDashboard.weekCount) wk") {
            HStack(spacing: 3) {
                ForEach(Array(d.weeks.enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(c == 0 ? SnappetColor.surfaceMuted : accent.opacity(0.35 + 0.65 * Double(c) / Double(peak)))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .accessibilityIdentifier("activity.dashboard.frequency")
    }

    // MARK: - Actions

    private func select(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, points: [ActivityDashboard.Point]) {
        guard let plot = proxy.plotFrame else { return }
        let x = location.x - geo[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        selected = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.sessionID
    }

    /// Play every clip of the activity, starting at the first clip of `session`.
    private func play(session: UUID) {
        guard let start = allClips.firstIndex(where: { $0.sessionID == session }) else { return }
        viewing = ViewerRequest(clips: allClips, start: start)
    }
}
