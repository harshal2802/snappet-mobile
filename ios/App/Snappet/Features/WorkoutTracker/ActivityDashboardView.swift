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
    let key: ActivityKey
    let title: String
    let history: [WorkoutSession]
    let unit: WeightUnit
    /// The catalog move behind this activity (a strength `exerciseId`), for the About tab's how-to.
    var catalogExercise: Exercise? = nil

    enum Tab: String { case progress, clips, about }

    @Environment(\.modelContext) private var context
    @Environment(SuiteRouter.self) private var router
    @Query(sort: \Routine.updatedAt, order: .reverse) private var routines: [Routine]
    @State private var tab: Tab = .progress
    @State private var toast: String?
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
                    ActivityAboutView(key: key, title: title, history: history, unit: unit)
                }
            }
        }
        .background(SnappetColor.paper)
        .safeAreaInset(edge: .bottom) { if tab != .clips && ActivityLauncher.canLaunch(key) { actionBar } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
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
            if dashboard == nil { tab = .about }
            loaded = true
        }
        .fullScreenCover(item: $viewing) { req in
            ActivityClipViewer(clips: req.clips, startIndex: req.start,
                               sessions: Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
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

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let toast {
                Text(toast).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("activity.toast")
            }
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
                                                           catalogExerciseId: catalogExercise?.id) else { return }
        // Hand it to the Gym Tracker home and pop back to it: a view under a pushed page doesn't run its change
        // handlers, and the player is a cover the home presents. Pop everything above the module root (path[0]).
        router.pendingQuickLog = entity
        if router.path.count > 1 { router.path.removeLast(router.path.count - 1) }
    }

    private func addToRoutine(_ routine: Routine) {
        guard let block = ActivityLauncher.routineBlock(for: key, history: history,
                                                        identity: ActivityIdentity(sessions: history),
                                                        defaultUnit: unit,
                                                        catalogExerciseId: catalogExercise?.id) else { return }
        routine.exercises.append(block)
        routine.updatedAt = .now
        try? context.save()
        let message = "Added to \(routine.name)"
        withAnimation { toast = message }
        AccessibilityNotification.Announcement(message).post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            withAnimation { toast = nil }
        }
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
