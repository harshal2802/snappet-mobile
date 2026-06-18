import SwiftUI
import Charts
import HighlightEngine

/// The expanded **live climbing stats** sheet (Quick Session redesign Phase 3), presented from the
/// freeform player's stat ribbon (`freeform.statsRibbon`). A read-only recap of the session's climbing
/// so far: three hero tiles (Sends · Hardest · Sends/hr), the full grade pyramid (easiest→hardest),
/// projects/attempts, median time-on-climb, time-on-wall vs rest (when ≥1 climb was timed), and — only
/// when the session carries heart rate — an Effort block (avg/max/redline + a single stacked zone bar).
///
/// Every figure comes from the already-pure `FreeformClimbStats.stats` (the same `KilterSessionStats`
/// the Kilter board flow computes) plus `WorkoutHRStats` for the HR roll-up, so this view does no stats
/// math of its own. It REUSES the shared `ZoneBar`; the Kilter summary's pyramid is private to its file,
/// so the pyramid here is a small Swift Charts `BarMark` (per the Phase 3 spec). Presented `.medium`
/// /`.large`; nothing here mutates the session.
struct LiveClimbStatsSheet: View {
    let session: WorkoutSession
    /// The zone ceiling for the Effort block — the session's own snapshot, else the live profile, else
    /// the fixed default. Mirrors `KilterSessionDetailView.zoneMaxHR`.
    let maxHR: Double

    @Environment(\.dismiss) private var dismiss

    /// Climbing stats as of now (live "end"). Computed once per presentation — cheap and pure, and the
    /// sheet is read-only so the snapshot doesn't drift while it's open.
    private var stats: KilterSessionStats {
        FreeformClimbStats.stats(for: session, now: .now,
                                 hrSeries: session.hrSeries.map {
                                     HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs)
                                 })
    }

    /// Whole-session HR roll-up (avg/max/redline + per-zone dwell) — `nil` for an HR-less session, which
    /// hides the Effort block entirely.
    private var hrStats: WorkoutHRStats? {
        guard !session.hrSeries.isEmpty else { return nil }
        return WorkoutHRStats.make(from: session.hrSeries, maxHR: maxHR)
    }

    var body: some View {
        let s = stats
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    heroTiles(s)
                    if !s.pyramid.isEmpty { pyramidSection(s) }
                    countsSection(s)
                    if let hrStats { effortSection(hrStats) }
                }
                .padding(.vertical)
            }
            .navigationTitle("Session stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("freeform.statsDone")
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("freeform.statsExpand")
    }

    // MARK: - Hero tiles

    private func heroTiles(_ s: KilterSessionStats) -> some View {
        HStack(spacing: 12) {
            heroTile(value: "\(s.sends)", label: "Sends", systemImage: "checkmark.seal.fill",
                     tint: SnappetColor.habits)
            heroTile(value: s.hardestSendGrade ?? "—", label: "Hardest", systemImage: "bolt.fill",
                     tint: SnappetColor.kilter)
            heroTile(value: sendsPerHourLabel(s.sendsPerHour), label: "Sends/hr",
                     systemImage: "speedometer", tint: SnappetColor.workout)
        }
        .padding(.horizontal)
    }

    private func heroTile(value: String, label: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title3).foregroundStyle(tint)
            Text(value).font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private func sendsPerHourLabel(_ value: Double) -> String {
        value > 0 ? String(format: "%.1f", value) : "—"
    }

    // MARK: - Grade pyramid

    /// The full grade pyramid, easiest→hardest (`stats.pyramid` is already in that order). A small Swift
    /// Charts `BarMark` per grade — the Kilter summary's pyramid is private to its file, so this is the
    /// Phase 3-sanctioned local copy rather than a shared extraction.
    private func pyramidSection(_ s: KilterSessionStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Grade pyramid", systemImage: "chart.bar.fill")
            Chart(s.pyramid) { g in
                BarMark(x: .value("Sends", g.sends), y: .value("Grade", g.gradeLabel))
                    .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                    .annotation(position: .trailing) {
                        Text("\(g.sends)").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            // Easiest at the bottom, hardest at the top — a pyramid that grows up by difficulty.
            .chartYScale(domain: s.pyramid.map(\.gradeLabel))
            .frame(height: CGFloat(s.pyramid.count) * 30 + 20)
            .accessibilityIdentifier("freeform.statsPyramid")
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .padding(.horizontal)
    }

    // MARK: - Counts & timing

    /// Projects / total attempts, median time-on-climb, and (when ≥1 climb was timed) time-on-wall vs
    /// rest — the secondary climbing figures beneath the hero/pyramid.
    private func countsSection(_ s: KilterSessionStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Effort", systemImage: "figure.climbing")
            statRow("Projects", "\(s.projects)")
            statRow("Total attempts", "\(s.totalAttempts)")
            if let median = s.medianTimeOnClimb {
                statRow("Median time on climb", SetMeasure.formatDuration(median))
            }
            if let (wall, rest) = wallVsRest(s) {
                statRow("Time on wall", SetMeasure.formatDuration(wall))
                statRow("Rest", SetMeasure.formatDuration(rest))
            }
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .padding(.horizontal)
    }

    /// Time-on-wall (Σ per-climb time) vs rest (session length − wall), or `nil` when no climb recorded a
    /// duration (so we never show a "0 on wall / all rest" split for an untimed logbook).
    private func wallVsRest(_ s: KilterSessionStats) -> (wall: TimeInterval, rest: TimeInterval)? {
        let wall = s.timeline.compactMap(\.timeOnClimb).reduce(0, +)
        guard wall > 0 else { return nil }
        let rest = max(0, s.totalDuration - wall)
        return (wall, rest)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: - HR effort

    /// Avg / max / redline + a single stacked zone bar (the shared `ZoneBar`) — shown only when the
    /// session carries heart rate (the caller already gated on `!session.hrSeries.isEmpty`, but this
    /// branch is defensive). Read-only; reuses the same `WorkoutHRStats` figures the detail summary shows.
    private func effortSection(_ hr: WorkoutHRStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Heart rate", systemImage: "heart.fill")
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
        .padding(.horizontal)
    }

    private func hrStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared section title

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
