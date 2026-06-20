import SwiftUI
import Charts
import HighlightEngine

/// Tier-2 **trend detail** screen for the P3 analytics dashboard — one full screen per `TrendKind`,
/// reached by tapping a doorway tile on `KilterStatsView`. Like the dashboard it does **no** math: it
/// reads the pre-built `KilterAllTimeStats` and the pure `KilterStatsTrend` helpers (range bucketing,
/// vs-previous delta + ghost). The volume screen clones the workout dashboard's grow-on-appear `BarMark`
/// and adds 30d/3m/1y/all range chips with a faint vs-previous "ghost" series behind each bar.
struct KilterTrendDetailView: View {
    let kind: KilterStatsView.TrendKind
    let stats: KilterAllTimeStats
    let now: Date
    let hasHRData: Bool
    /// The persisted board sessions — only the HR trend reads these (for cross-session HR series).
    let sessions: [KilterSession]

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var range: KilterStatsTrend.Range = .months3
    @State private var drawn = false

    private var accent: Color { SnappetColor.kilter }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch kind {
                case .volume:      volumeScreen
                case .progression: progressionScreen
                case .velocity:    velocityScreen
                case .angle:       angleScreen
                case .consistency: consistencyScreen
                case .heart:       heartScreen
                }
            }
            .padding()
            .padding(.bottom, 24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { drawn = true }
        .onDisappear { drawn = false }
    }

    private var title: String {
        switch kind {
        case .volume:      return "Sends per week"
        case .progression: return "Max grade progression"
        case .velocity:    return "Attempts to send"
        case .angle:       return "Sends by angle"
        case .consistency: return "Consistency"
        case .heart:       return "Heart rate"
        }
    }

    // MARK: - Volume (range chips + vs-previous ghost)

    private var volumeScreen: some View {
        let bars = KilterStatsTrend.ghostedBars(stats.sendsPerWeek, range: range, now: now)
        let delta = KilterStatsTrend.delta(stats.sendsPerWeek, range: range, now: now)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sends / week").font(.title3.weight(.bold))
                Spacer()
                if let delta { deltaChip(delta) }
            }
            rangeChips
            if bars.isEmpty {
                emptyTrend("No sends in this range yet.")
            } else {
                Chart {
                    ForEach(bars) { bar in
                        if let ghost = bar.previous {
                            // Faint "previous period" ghost behind the solid current bar.
                            BarMark(x: .value("Week", bar.start, unit: .weekOfYear),
                                    y: .value("Prev", drawn || reduceMotion ? ghost : 0))
                                .foregroundStyle(SnappetColor.textSecondary.opacity(0.22))
                        }
                        BarMark(x: .value("Week", bar.start, unit: .weekOfYear),
                                y: .value("Sends", drawn || reduceMotion ? bar.current : 0))
                            .foregroundStyle(accent)
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(height: 200)
                .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: drawn)
                .accessibilityIdentifier("kilter.trend.volumeChart")
                ghostLegend
            }
        }
    }

    private var rangeChips: some View {
        HStack(spacing: 8) {
            ForEach(KilterStatsTrend.Range.allCases) { r in
                Button { withAnimation(.snappy) { range = r } } label: {
                    Text(r.label)
                        .font(.subheadline.weight(range == r ? .bold : .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(range == r ? AnyShapeStyle(SnappetColor.surface)
                                              : AnyShapeStyle(Color.clear),
                                    in: RoundedRectangle(cornerRadius: SnappetRadius.sm))
                        .foregroundStyle(range == r ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kilter.trend.range.\(r.rawValue)")
            }
        }
        .padding(4)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private func deltaChip(_ d: KilterStatsTrend.Delta) -> some View {
        let color = d.isUp ? SnappetColor.perfFresh : SnappetColor.perfHard
        return Text(d.caption(for: range))
            .font(.caption.weight(.bold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Capsule())
            .accessibilityIdentifier("kilter.trend.delta")
    }

    private var ghostLegend: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(SnappetColor.textSecondary.opacity(0.22))
                .frame(width: 14, height: 10)
            Text("Ghost = previous period · solid = this period")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Max-grade progression (step-line)

    private var progressionScreen: some View {
        let points = stats.maxGradeProgression
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Max grade progression").font(.title3.weight(.bold))
                Spacer()
                // Full-span chip: the oldest progression point → the latest. Read the endpoints directly
                // (not a date-windowed `levelDelta`) so the chip always spans the whole displayed series.
                if let first = points.first, let last = points.last,
                   first.periodLabel != last.periodLabel,
                   Int(last.difficulty.rounded()) != Int(first.difficulty.rounded()) {
                    Text("\(first.gradeLabel) → \(last.gradeLabel)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(SnappetColor.perfFresh)
                        .background(SnappetColor.perfFresh.opacity(0.16), in: Capsule())
                }
            }
            if points.count < 2 {
                emptyTrend("Log sends across a few months to see your progression.")
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Month", p.periodLabel), y: .value("Grade", p.difficulty))
                        .foregroundStyle(accent)
                        .interpolationMethod(.stepEnd)
                    PointMark(x: .value("Month", p.periodLabel), y: .value("Grade", p.difficulty))
                        .foregroundStyle(accent)
                        .annotation(position: .top) {
                            Text(p.gradeLabel).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .chartYAxis(.hidden)
                .frame(height: 220)
                .accessibilityIdentifier("kilter.trend.progressionChart")
            }
        }
    }

    // MARK: - Attempts-to-send velocity

    private var velocityScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Attempts to send").font(.title3.weight(.bold))
            if let v = stats.attemptsToSend {
                DisciplineHero(value: String(format: "%.1f", v),
                               caption: "Avg tries per send",
                               sublabel: "Lower means cleaner sends — flashes count as one.",
                               systemImage: "arrow.uturn.up", accent: accent)
                    .snappetCard()
                HStack(spacing: 10) {
                    factTile("\(Int((stats.flashRate * 100).rounded()))%", "FLASHED")
                    factTile("\(stats.totalAttempts)", "TOTAL TRIES")
                    factTile("\(stats.totalSends)", "SENDS")
                }
            } else {
                emptyTrend("Send a climb to start tracking your attempts-to-send.")
            }
        }
    }

    // MARK: - Sends by angle

    private var angleScreen: some View {
        let angles = stats.angleDistribution
        return VStack(alignment: .leading, spacing: 16) {
            Text("Sends by angle").font(.title3.weight(.bold))
            if angles.isEmpty {
                emptyTrend("Log a send to see which angles you climb most.")
            } else {
                Chart(angles) { a in
                    BarMark(x: .value("Sends", drawn || reduceMotion ? a.sends : 0),
                            y: .value("Angle", "\(a.angle)°"))
                        .foregroundStyle(SnappetColor.perfFresh)
                        .annotation(position: .trailing) {
                            Text("\(a.sends)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: angles.map { "\($0.angle)°" })
                .frame(height: CGFloat(angles.count) * 34 + 20)
                .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: drawn)
                .accessibilityIdentifier("kilter.trend.angleChart")
            }
        }
    }

    // MARK: - Consistency (kindly strip)

    private var consistencyScreen: some View {
        let weeks = stats.sendsPerWeek
        let active = weeks.filter { $0.sends > 0 }.count
        return VStack(alignment: .leading, spacing: 16) {
            Text("Consistency").font(.title3.weight(.bold))
            DisciplineHero(value: "\(active)/\(weeks.count)",
                           caption: "Weeks you climbed",
                           sublabel: active >= max(1, weeks.count - 1)
                               ? "Lovely rhythm — keep it gentle." : "Every week you show up counts.",
                           systemImage: "checkmark.seal.fill", accent: accent)
                .snappetCard()
            // A calm dot strip — filled (perf-fresh) when that week had a send, faint when rested.
            HStack(spacing: 8) {
                ForEach(weeks) { w in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(w.sends > 0 ? SnappetColor.perfFresh : SnappetColor.surface)
                            .frame(width: 14, height: 14)
                        Text("\(w.sends)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            .accessibilityIdentifier("kilter.trend.consistencyStrip")
            Text("Rest weeks are part of the plan — this is a streak you can be kind to.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Heart-rate trend (optional — only when band data exists)

    private var heartScreen: some View {
        // Pool every captured HR series into one cross-session zone profile + an avg-by-session trend.
        let hrSessions = sessions.filter { !$0.hrSeries.isEmpty }.sorted { $0.startedAt < $1.startedAt }
        let maxHR = app.userProfile.profile.resolvedMaxHR ?? HeartRateZone.defaultMaxHR
        let pooled = hrSessions.flatMap { $0.hrSeries }
        let pooledStats = WorkoutHRStats.make(from: pooled, maxHR: maxHR)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Heart rate").font(.title3.weight(.bold))
            if let pooledStats, pooledStats.totalSeconds > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    ClimbSummarySectionTitle("Time in zone (all sessions)", systemImage: "heart.fill")
                    ZoneBar(stats: pooledStats)
                }
                .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))

                // Per-session average bpm trend — one bar per HR session, chronological.
                VStack(alignment: .leading, spacing: 10) {
                    ClimbSummarySectionTitle("Avg heart rate per session", systemImage: "waveform.path.ecg")
                    Chart(Array(hrSessions.enumerated()), id: \.offset) { i, s in
                        let avg = WorkoutHRStats.make(from: s.hrSeries, maxHR: maxHR)?.avgBpm ?? 0
                        BarMark(x: .value("Session", s.startedAt, unit: .day),
                                y: .value("Avg bpm", drawn || reduceMotion ? avg : 0))
                            .foregroundStyle(SnappetColor.performance(for: avg / maxHR))
                    }
                    .frame(height: 180)
                    .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: drawn)
                    .accessibilityIdentifier("kilter.trend.hrChart")
                }
                .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            } else {
                emptyTrend("Connect a heart-rate band on the board to build your HR trend.")
            }
        }
    }

    // MARK: - Shared bits

    private func factTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(SnappetColor.ink)
            Text(label).font(.caption2.weight(.bold)).tracking(0.4).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private func emptyTrend(_ message: String) -> some View {
        Text(message).font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }
}
