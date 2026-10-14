import SwiftUI
import SwiftData
import Charts

/// Routing payload for one activity's dashboard (activity progress P2, prompt 179). `ProgressRoute` (the
/// library / dashboard entry) now lands here too.
struct ActivityRoute: Hashable {
    let key: ActivityKey
    let title: String
}

/// One activity's dashboard: KPI tiles · the hero metric over time (points with clips carry a 📷, and
/// selecting one offers to play that session's clips) · records with their clips · frequency · a clips
/// filmstrip. The numbers are the pure `ActivityDashboard`; the clips are `ActivityMediaIndex`.
struct ActivityDashboardView: View {
    let key: ActivityKey
    let title: String
    let history: [WorkoutSession]
    let unit: WeightUnit

    @Environment(\.modelContext) private var context
    @State private var dashboard: ActivityDashboard?
    @State private var groups: [ActivitySessionGroup] = []
    @State private var loaded = false
    @State private var selected: UUID?
    @State private var viewing: ViewerRequest?
    @State private var showingAllClips = false

    private struct ViewerRequest: Identifiable {
        let id = UUID()
        let clips: [ActivityClip]
        let start: Int
    }

    private var accent: Color { dashboard?.discipline.accent ?? SnappetColor.workout }
    private var allClips: [ActivityClip] { groups.flatMap(\.clips) }

    var body: some View {
        ScrollView {
            if let d = dashboard {
                VStack(alignment: .leading, spacing: 14) {
                    kpiRow(d)
                    chartCard(d)
                    if !allClips.isEmpty { clipsCard }
                    recordsCard(d)
                    frequencyCard(d)
                }
                .padding(16)
            }
        }
        .background(SnappetColor.paper)
        .overlay {
            if loaded && dashboard == nil {
                ContentUnavailableView("No history yet", systemImage: "chart.xyaxis.line",
                                       description: Text("Log \(title) in a workout to track progress."))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity.dashboard")
        .task {
            guard !loaded else { return }
            let media = ActivityMediaStore.snapshot(context: context)
            dashboard = ActivityDashboard.make(key: key, history: history, media: media, unit: unit)
            groups = ActivityMediaIndex.groups(for: key, history: history, media: media, unit: unit,
                                               distanceUnit: unit == .lb ? .mi : .km)
            loaded = true
        }
        .fullScreenCover(item: $viewing) { req in
            ActivityClipViewer(clips: req.clips, startIndex: req.start,
                               sessions: Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        .sheet(isPresented: $showingAllClips) {
            ActivityClipsSheet(target: ActivityClipsTarget(key: key, title: title), history: history, unit: unit)
        }
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
                                Text(clip.sessionDate, format: .dateTime.day().month(.abbreviated))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("See all clips") { showingAllClips = true }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("activity.dashboard.allClips")
        }
        .accessibilityIdentifier("activity.dashboard.clips")
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
