import SwiftUI
import SwiftData
import HighlightEngine

// MARK: - Recap Feed — card detail (F2)
//
// Pushed from a feed card: the full card on top, then the deeper stats re-derived from the source
// session (climb-by-climb timeline + HR zone chart), the reactions strip, and "Open in module"
// (deep-links to the real KilterSessionDetail / WorkoutSessionDetail via the router).

struct CardDetailView: View {
    let card: FeedCard

    @Environment(\.modelContext) private var context
    @Environment(SuiteRouter.self) private var router

    @Query private var kilterSessions: [KilterSession]
    @Query private var kilterLogs: [KilterLogEntry]
    @Query private var workoutSessions: [WorkoutSession]
    @Query private var allMedia: [SessionMedia]
    @State private var showingShare = false
    @State private var showingMedia = false

    private var target: FeedDeepLink.Target { FeedDeepLink.target(for: card) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FeedCardView(card: card)

                if !card.contentId.isEmpty {
                    FeedReactionStrip(contentId: card.contentId)
                        .padding(.horizontal, 2)
                }

                switch target {
                case .kilterSession(let id): kilterDetail(id: id)
                case .workoutSession(let id): workoutDetail(id: id)
                case .none: EmptyView()
                }

                mediaButton
                openInModuleButton
            }
            .padding(SnappetSpacing.lg)
        }
        .background(SnappetColor.paper)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("feed.detail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingShare = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityIdentifier("feed.share")
            }
        }
        .sheet(isPresented: $showingShare) { ShareComposerView(card: card) }
    }

    // MARK: Kilter

    @ViewBuilder private func kilterDetail(id: UUID) -> some View {
        if let s = kilterSessions.first(where: { $0.id == id }) {
            let logs = kilterLogs.filter { $0.sessionId == id }.map(KilterClimbLog.from)
            let samples = s.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
            let stats = KilterSessionStats.make(from: logs, start: s.startedAt, end: s.endedAt ?? .now,
                                                hrSeries: samples, maxHR: s.maxHR, restHR: s.restHR)
            if !stats.timeline.isEmpty { timelineSection(stats.timeline) }
            if let hr = WorkoutHRStats.make(from: s.hrSeries, maxHR: s.maxHR ?? HeartRateZone.defaultMaxHR),
               hr.totalSeconds > 0 {
                zoneChartSection(hr)
            }
        }
    }

    private func timelineSection(_ items: [KilterSessionStats.TimelineItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Climb-by-climb")
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Text("\(item.index + 1)").font(.caption.weight(.bold)).foregroundStyle(SnappetColor.textSecondary).frame(width: 18)
                    Text(item.gradeLabel).font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.ink)
                    ascentChip(item.status)
                    Spacer()
                    if let bpm = item.peakBpm {
                        Text("\(Int(bpm)) bpm").font(.caption.weight(.semibold))
                            .foregroundStyle(SnappetColor.performance(forZone: HeartRateZone.forBpm(bpm)))
                    }
                }
                .padding(.vertical, 6)
                Divider().overlay(SnappetColor.hairline)
            }
        }
        .snappetCard()
    }

    private func zoneChartSection(_ hr: WorkoutHRStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("HR zones · \(Int(hr.edwardsTRIMP)) TRIMP")
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(hr.orderedZoneSeconds, id: \.zone) { entry in
                        Rectangle().fill(SnappetColor.performance(forZone: entry.zone))
                            .frame(width: max(0, geo.size.width * (entry.seconds / max(1, hr.totalSeconds))))
                    }
                }
            }
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            ForEach(hr.orderedZoneSeconds.filter { $0.seconds > 0 }, id: \.zone) { entry in
                HStack(spacing: 8) {
                    Circle().fill(SnappetColor.performance(forZone: entry.zone)).frame(width: 8, height: 8)
                    Text(entry.zone.pillLabel).font(.caption).foregroundStyle(SnappetColor.ink)
                    Spacer()
                    Text(minSec(entry.seconds)).font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.textSecondary)
                }
            }
        }
        .snappetCard()
    }

    // MARK: Workout

    @ViewBuilder private func workoutDetail(id: UUID) -> some View {
        if let w = workoutSessions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Session")
                Text("\(w.completedExerciseCount) exercises · \(w.completedSetCount) sets")
                    .font(.subheadline).foregroundStyle(SnappetColor.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .snappetCard()
            if let hr = WorkoutHRStats.make(from: w.hrSeries, maxHR: w.maxHR ?? HeartRateZone.defaultMaxHR),
               hr.totalSeconds > 0 {
                zoneChartSection(hr)
            }
        }
    }

    // MARK: Chrome

    @ViewBuilder private var mediaButton: some View {
        let sid: UUID? = {
            switch target {
            case .kilterSession(let id), .workoutSession(let id): return id
            case .none: return nil
            }
        }()
        if let sid {
            let media = allMedia.filter { $0.sessionID == sid }
            if !media.isEmpty {
                Button { showingMedia = true } label: {
                    Label("Media (\(media.count))", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(SnappetColor.ink)
                        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed.mediaButton")
                .sheet(isPresented: $showingMedia) {
                    MediaBrowserView(media: media.map(MediaInput.from),
                                     hrSeries: hrSeries(for: sid), maxHR: maxHR(for: sid),
                                     nameFor: nameResolver(for: sid))
                }
            }
        }
    }

    private func hrSeries(for sid: UUID) -> [HRPoint] {
        kilterSessions.first { $0.id == sid }?.hrSeries ?? workoutSessions.first { $0.id == sid }?.hrSeries ?? []
    }
    private func maxHR(for sid: UUID) -> Double {
        (kilterSessions.first { $0.id == sid }?.maxHR ?? workoutSessions.first { $0.id == sid }?.maxHR) ?? HeartRateZone.defaultMaxHR
    }
    private func nameResolver(for sid: UUID) -> (String) -> String {
        var map: [String: String] = ["general": "General"]
        for log in kilterLogs where log.sessionId == sid { map[log.climbUUID] = log.climbName }
        if let w = workoutSessions.first(where: { $0.id == sid }) {
            for ex in w.exercises { map[ex.id.uuidString] = ex.displayName ?? ex.exerciseId }
        }
        return { key in map[key] ?? "Clip" }
    }

    private var openInModuleButton: some View {
        Button {
            switch target {
            case .kilterSession(let id):
                router.open(module: "kilter"); router.push(KilterSessionRoute(id: id))
            case .workoutSession(let id):
                router.open(module: "workout-log"); router.push(SessionRoute(id: id))
            case .none: break
            }
        } label: {
            Label("Open in module", systemImage: "arrow.up.forward.app")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(SnappetColor.brand)
                .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md, style: .continuous)
                    .strokeBorder(SnappetColor.brand, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("feed.openInModule")
        .opacity(target == .none ? 0 : 1)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption.weight(.bold)).tracking(0.5).foregroundStyle(SnappetColor.textSecondary)
    }

    private func ascentChip(_ status: KilterAscentStatus) -> some View {
        let tint: Color = status == .flash ? SnappetColor.kilter
            : status == .sent ? SnappetColor.performance(forZone: .aerobic)
            : status == .project ? SnappetColor.performance(forZone: .threshold)
            : SnappetColor.textSecondary
        return Text(status.label).font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(tint).background(tint.opacity(0.16), in: Capsule())
    }

    private func minSec(_ s: Double) -> String {
        let t = Int(s.rounded()); return t >= 60 ? "\(t / 60)m \(t % 60)s" : "\(t)s"
    }
}
