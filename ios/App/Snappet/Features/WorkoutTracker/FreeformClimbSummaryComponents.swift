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
struct ClimbGradePyramid: View {
    let pyramid: [KilterSessionStats.GradeCount]

    var body: some View {
        if pyramid.isEmpty {
            EmptyView()
        } else {
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
