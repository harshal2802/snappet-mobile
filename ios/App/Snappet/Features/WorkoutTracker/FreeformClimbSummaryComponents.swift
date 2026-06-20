import SwiftUI
import Charts
import HighlightEngine

/// Shared, reusable climbing-recap subviews (Quick Session redesign Phase 7) — the **grade pyramid**,
/// the **HR effort** block (avg/max/redline + the stacked `ZoneBar`), and the **timeline** list. Both the
/// live `LiveClimbStatsSheet` (Phase 3) and the type-adaptive `FreeformDoneSummaryView` (Phase 7) render
/// these, so the completion summary REUSES the exact pyramid/zone-bar the live sheet already shows
/// instead of duplicating them (the prompt's "prefer extracting shared subviews" rule). Every figure is
/// read from a precomputed `KilterSessionStats` / `WorkoutHRStats`; these views do no stats math.

/// A small shared section title (label + icon, secondary) used by every climbing-recap card.
struct ClimbSummarySectionTitle: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// The full grade pyramid, easiest→hardest (`pyramid` is already in that order). A Swift Charts
/// `BarMark` per grade with the send count annotated — the same chart the Phase-3 live sheet used,
/// lifted here verbatim so both surfaces share one definition. Carries the `freeform.statsPyramid` id
/// the Phase-3 UITest matches. Renders nothing for an empty pyramid (the caller gates, but defensive).
///
/// **P3 additive segmentation.** The default (`.solid`) is byte-for-byte the chart the two existing
/// callers (`SessionRecap`, `LiveClimbStatsSheet`) already render — one accent bar per grade. The new
/// `.segmented` style draws an **honest sends bar** per grade: two stacked segments — Flash (`flashes`)
/// and redpoint Send (`sends − flashes`) — whose total length equals `sends`, so the bar matches the
/// trailing `sends` annotation exactly. Projects/attempts are *not* part of the bar (a send pyramid is
/// send volume; they surface via the attempts-to-send tile + the ascent log). Styled by
/// `KilterAscentStyle` so colour is never the sole encoding — position + a status legend + the perf ramp
/// carry it for colourblind safety; optionally draws a dashed **current-max** marker, and — when
/// `onSelectGrade` is supplied — makes each bar tappable to filter the ascent log. All new parameters are
/// defaulted, so the two existing callers compile and render unchanged.
struct ClimbGradePyramid: View {
    let pyramid: [KilterSessionStats.GradeCount]

    /// How the bars render. `.solid` (default) = the original single-accent bar. `.segmented` = the P3
    /// flash/send/project stacks with a status legend.
    enum Style { case solid, segmented }
    var style: Style = .solid

    /// The grade label to mark with a dashed "current max" line (P3). `nil` = no marker.
    var currentMaxLabel: String? = nil

    /// Tap-a-grade callback (P3) — when set, each bar becomes a tappable region that filters the
    /// ascent log to that grade. `nil` = the bars are inert (the existing callers' behaviour).
    var onSelectGrade: ((String) -> Void)? = nil

    /// The per-segment plot rows the `.segmented` chart draws — one stacked entry per (grade, status).
    private struct Segment: Identifiable {
        let grade: String
        let status: KilterAscentStatus
        let count: Int
        var id: String { "\(grade)#\(status.rawValue)" }
    }

    /// Flatten the pyramid into stacked Flash → redpoint Send rows. The bar represents **sends only**, so
    /// its two segments sum to `sends` (Flash = `flashes`, Send = `sends − flashes`) and the bar length
    /// matches the trailing `sends` annotation exactly. Projects/attempts are deliberately excluded — a
    /// send pyramid is send volume; they surface via the attempts-to-send tile + the ascent log.
    private var segments: [Segment] {
        pyramid.flatMap { g -> [Segment] in
            let worked = max(0, g.sends - g.flashes)   // sent (not flash) portion of the send total
            return [
                Segment(grade: g.gradeLabel, status: .flash, count: g.flashes),
                Segment(grade: g.gradeLabel, status: .sent, count: worked),
            ].filter { $0.count > 0 }
        }
    }

    var body: some View {
        if pyramid.isEmpty {
            EmptyView()
        } else if style == .solid {
            solidCard
        } else {
            segmentedCard
        }
    }

    // MARK: - Solid (the original — unchanged for SessionRecap / LiveClimbStatsSheet)

    private var solidCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClimbSummarySectionTitle("Grade pyramid", systemImage: "chart.bar.fill")
            Chart(pyramid) { g in
                BarMark(x: .value("Sends", g.sends), y: .value("Grade", g.gradeLabel))
                    .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                    .annotation(position: .trailing) {
                        Text("\(g.sends)").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            // Easiest at the bottom, hardest at the top — a pyramid that grows up by difficulty.
            .chartYScale(domain: pyramid.map(\.gradeLabel))
            .frame(height: CGFloat(pyramid.count) * 30 + 20)
            .accessibilityIdentifier("freeform.statsPyramid")
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    // MARK: - Segmented (P3 dashboard)

    private var segmentedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ClimbSummarySectionTitle("Grade pyramid", systemImage: "chart.bar.fill")
                Spacer()
                if onSelectGrade != nil {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Chart {
                ForEach(segments) { seg in
                    BarMark(x: .value("Sends", seg.count), y: .value("Grade", seg.grade))
                        .foregroundStyle(by: .value("Outcome", KilterAscentStyle.label(seg.status)))
                }
                // Total annotation per grade (a zero-width mark carrying the trailing count label).
                ForEach(pyramid) { g in
                    BarMark(x: .value("Sends", 0), y: .value("Grade", g.gradeLabel))
                        .annotation(position: .trailing) {
                            Text("\(g.sends)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                if let currentMaxLabel, pyramid.contains(where: { $0.gradeLabel == currentMaxLabel }) {
                    RuleMark(y: .value("Max", currentMaxLabel))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(SnappetColor.perfHard)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("\(currentMaxLabel) max")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(SnappetColor.perfHard.opacity(0.18), in: Capsule())
                                .foregroundStyle(SnappetColor.perfHard)
                        }
                }
            }
            .chartForegroundStyleScale([
                KilterAscentStyle.label(.flash): KilterAscentStyle.color(.flash),
                KilterAscentStyle.label(.sent):  KilterAscentStyle.color(.sent),
            ])
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYScale(domain: pyramid.map(\.gradeLabel))
            .frame(height: CGFloat(pyramid.count) * 34 + 20)
            // Tap-a-grade → filter. Resolve the tapped grade from the *real* category (Y) axis via the
            // ChartProxy, so a tap maps to the bar actually under the finger (the old equal-height VStack
            // of buttons guessed by frame fraction and hit the wrong grade / dead zones). A spatial tap
            // over the plot area drives sighted use; per-grade accessibility elements — positioned on
            // their true bar row via the proxy — give VoiceOver an accessible, correctly-located action.
            .chartOverlay { proxy in
                if let onSelectGrade, let plotAnchor = proxy.plotFrame {
                    GeometryReader { geo in
                        let plot = geo[plotAnchor]
                        ZStack(alignment: .topLeading) {
                            // Sighted: a single hit layer; resolve the grade from the tap's Y position.
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            selectGrade(at: value.location, proxy: proxy, plot: plot,
                                                        onSelectGrade: onSelectGrade)
                                        }
                                )
                            // VoiceOver / UI-test targets: one element per grade, parked on its row so
                            // focus (and an XCUITest tap at the element's centre) lands on the right bar.
                            // `position(forY:)` is plot-relative, so offset by the plot's origin.
                            ForEach(pyramid) { g in
                                if let y = proxy.position(forY: g.gradeLabel) {
                                    Color.clear
                                        .frame(width: max(1, plot.width), height: 34)
                                        .position(x: plot.midX, y: plot.minY + y)
                                        .accessibilityElement()
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityIdentifier("kilter.stats.pyramidBar.\(g.gradeLabel)")
                                        .accessibilityLabel("\(g.gradeLabel): \(g.sends) sends. Tap to filter.")
                                        .accessibilityAction { onSelectGrade(g.gradeLabel) }
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("kilter.stats.pyramid")

            statusLegend
            if onSelectGrade != nil {
                Text("Tap a grade to filter your sends")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    /// Resolve the grade under a tap and filter to it. The tap must land inside the plot's bounds; the
    /// grade comes from the **category (Y) axis** via the proxy (`value(atY:)` takes a plot-relative Y),
    /// and must match a real pyramid grade. A tap outside the plot or on no resolvable grade does nothing.
    private func selectGrade(at location: CGPoint, proxy: ChartProxy, plot: CGRect,
                             onSelectGrade: (String) -> Void) {
        guard plot.contains(location) else { return }
        let localY = location.y - plot.minY
        guard let grade: String = proxy.value(atY: localY),
              pyramid.contains(where: { $0.gradeLabel == grade }) else { return }
        onSelectGrade(grade)
    }

    /// Glyph + word per bar segment (never colour-only) — Flash · Send. The bar is send volume only, so
    /// the legend names exactly the two segments it draws (projects/attempts live elsewhere).
    private var statusLegend: some View {
        HStack(spacing: 12) {
            ForEach([KilterAscentStatus.flash, .sent], id: \.self) { st in
                let d = KilterAscentStyle.decoration(st)
                HStack(spacing: 4) {
                    Image(systemName: d.glyph).font(.caption2).foregroundStyle(d.color)
                    Text(d.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Avg / max / redline + a single stacked zone bar (the shared `ZoneBar`). The caller gates on the
/// session carrying HR; this just renders the precomputed `WorkoutHRStats`. Lifted from the Phase-3
/// sheet so both surfaces show the identical Effort block.
struct ClimbEffortSection: View {
    let hr: WorkoutHRStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClimbSummarySectionTitle("Heart rate", systemImage: "heart.fill")
            HStack(spacing: 0) {
                hrStat("\(Int(hr.avgBpm.rounded()))", "Avg")
                hrStat("\(Int(hr.maxBpm.rounded()))", "Max")
                hrStat(ZoneBar.minutesLabel(hr.redlineSeconds), "Redline")
            }
            if hr.totalSeconds > 0 {
                ZoneBar(stats: hr)
            }
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private func hrStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The session's per-climb **timeline** — one row per logged climb (newest first), each reading
/// type-aware status + grade + attempts + time-on-climb. Shows the top `collapsedLimit` rows with an
/// expand affordance when there are more (Phase 7's "timeline, top N, expandable"). Read from
/// `KilterSessionStats.timeline` — no math here.
struct ClimbTimelineList: View {
    let timeline: [KilterSessionStats.TimelineItem]
    /// How many rows to show before the "Show all N" toggle appears.
    var collapsedLimit: Int = 5

    @State private var expanded = false

    /// Newest climb first — a recap reads most-recent-on-top, the opposite of the chronological store.
    private var rows: [KilterSessionStats.TimelineItem] {
        timeline.sorted { $0.index > $1.index }
    }

    private var visible: [KilterSessionStats.TimelineItem] {
        expanded ? rows : Array(rows.prefix(collapsedLimit))
    }

    var body: some View {
        if timeline.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ClimbSummarySectionTitle("Timeline", systemImage: "list.bullet")
                ForEach(visible) { item in row(item) }
                if rows.count > collapsedLimit {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        Text(expanded ? "Show less" : "Show all \(rows.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SnappetColor.workout)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("freeform.summaryTimelineExpand")
                }
            }
            .padding()
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        }
    }

    private func row(_ item: KilterSessionStats.TimelineItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol(item.status))
                .font(.caption)
                .foregroundStyle(statusTint(item.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.climbName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !item.gradeLabel.isEmpty { Text(item.gradeLabel) }
                    Text("· \(item.attempts) \(item.attempts == 1 ? "try" : "tries")")
                    if let t = item.timeOnClimb, t > 0 {
                        Text("· \(SetMeasure.formatDuration(t))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(item.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusTint(item.status))
        }
        .accessibilityIdentifier("freeform.summaryTimelineRow")
    }

    private func statusSymbol(_ status: KilterAscentStatus) -> String {
        switch status {
        case .flash:   return "bolt.fill"
        case .sent:    return "checkmark.seal.fill"
        case .project: return "hourglass"
        case .attempt: return "circle"
        }
    }

    private func statusTint(_ status: KilterAscentStatus) -> Color {
        switch status {
        case .flash:   return SnappetColor.kilter
        case .sent:    return SnappetColor.habits
        case .project: return SnappetColor.workout
        case .attempt: return SnappetColor.textSecondary
        }
    }
}
