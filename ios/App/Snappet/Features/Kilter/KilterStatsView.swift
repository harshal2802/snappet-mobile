import SwiftUI
import SwiftData
import Charts
import HighlightEngine

/// Route value for the P3 analytics dashboard, pushed onto the App Library's shared `SuiteRouter` path
/// (registered in `KilterRootView`). Reachable from the Kilter root's More menu and from a "See your
/// stats" link at the top of History.
struct KilterStatsRoute: Hashable {}

/// Route value for a tier-2 trend detail screen — each dashboard tile drills into one of these.
struct KilterTrendRoute: Hashable { let kind: KilterStatsView.TrendKind }

/// The Kilter **climbing analytics dashboard** (Kilter Improvement P3) — a tiered Pulse Pro screen built
/// entirely on the pure, tested `KilterAllTimeStats` aggregate (no view math). Tier 1: the Climbing
/// Level hero + a perf-ramp delta, then a SENT / FLASH RATE / THIS WEEK stat ribbon. Tier 2: the
/// signature **segmented** grade pyramid (flash/send/project, dashed current-max marker, tap-a-grade →
/// filter the ascent log), send/flash rings, and doorway tiles into full trend screens (sends-per-week
/// with range chips + a vs-previous ghost, max-grade progression step-line, attempts-to-send velocity,
/// sends-by-angle, a kindly consistency strip, and an HR/zone trend when band data exists).
///
/// **Kilter-board data only.** Builds the aggregate from `@Query` `KilterLogEntry` (→ `KilterClimbLog`)
/// + `@Query` `KilterSession` (→ `KilterSessionSummary`). On-device; no new `@Model`.
struct KilterStatsView: View {
    @Environment(SuiteRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Query(sort: \KilterLogEntry.date, order: .reverse) private var entries: [KilterLogEntry]
    @Query(sort: \KilterSession.startedAt, order: .reverse) private var allSessions: [KilterSession]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The grade the user tapped in the pyramid — filters the in-page ascent log. `nil` = all sends.
    @State private var gradeFilter: String?

    /// Memoized all-time aggregate (F6). `KilterAllTimeStats.make` walks the full `@Query` log, so
    /// recomputing it on every `body` (e.g. each grade-filter tap) janks large logs. Compute it once and
    /// recompute only when the underlying logs/sessions actually change — keyed on a cheap `StatsSignature`
    /// (counts + the newest row's date/id) via `onChange(initial: true)`.
    @State private var cachedStats: KilterAllTimeStats = .empty

    /// A cheap identity for the aggregate's inputs — enough to detect adds/removes/edits/reorders without
    /// re-walking the whole log every render. The `@Query` is date-reverse sorted, so the first row is the
    /// newest; its date + id catches a new log or an edit to the latest, and the counts catch add/remove.
    private struct StatsSignature: Equatable {
        var entryCount: Int
        var sessionCount: Int
        var newestEntryDate: Date?
        var newestEntryID: PersistentIdentifier?
        var hrSessionCount: Int
    }

    private var statsSignature: StatsSignature {
        StatsSignature(entryCount: entries.count,
                       sessionCount: allSessions.count,
                       newestEntryDate: entries.first?.date,
                       newestEntryID: entries.first?.persistentModelID,
                       hrSessionCount: allSessions.reduce(0) { $0 + ($1.hrSeries.isEmpty ? 0 : 1) })
    }

    /// The tier-2 trend screens a tile can open.
    enum TrendKind: Hashable {
        case volume, progression, velocity, angle, consistency, heart
    }

    private let now = Date.now

    /// The single source of truth for every figure on the screen — the memoized P0 aggregate (recomputed
    /// only when `statsSignature` changes; see `cachedStats`).
    private var stats: KilterAllTimeStats { cachedStats }

    /// Rebuild the aggregate from the current `@Query` results. Called once on appear and whenever the
    /// cheap signature changes — never on an unrelated `body` pass (a grade-filter tap, a navigation).
    private func recomputeStats() {
        cachedStats = KilterAllTimeStats.make(logs: entries.map(KilterClimbLog.from),
                                              sessions: allSessions.map(KilterSessionSummary.from),
                                              now: now)
    }

    /// Whether any board session captured a heart-rate series — gates the optional HR trend tile.
    private var hasHRData: Bool { allSessions.contains { !$0.hrSeries.isEmpty } }

    private var accent: Color { SnappetColor.kilter }

    var body: some View {
        let s = stats
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No stats yet", systemImage: "chart.bar.xaxis",
                    description: Text("Log climbs on the board and your analytics build here."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heroTier(s)
                        statRibbon(s)
                        if !s.pyramid.isEmpty { pyramidCard(s) }
                        if !s.pyramid.isEmpty { ringsRow(s) }
                        trendTiles(s)
                        if gradeFilter != nil { ascentLogSection }
                    }
                    .padding()
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let recap = KilterStatsTrend.monthRecap(s, now: now) {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: "\(recap.title): \(recap.line)") {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("kilter.stats.share")
                }
            }
        }
        // Memoize the aggregate (F6): build once on appear, then only when the cheap signature changes —
        // not on every grade-filter tap / unrelated body pass.
        .onChange(of: statsSignature, initial: true) { _, _ in recomputeStats() }
        // `KilterTrendRoute` is registered on the shared stack by `KilterRootView` (where the session
        // @Query lives), so a tile push routes there with the same aggregate this screen shows.
    }

    // MARK: - Tier 1: hero + delta

    @ViewBuilder private func heroTier(_ s: KilterAllTimeStats) -> some View {
        let levelDelta = KilterStatsTrend.levelDelta(s.maxGradeProgression, monthsBack: 3, now: now)
        // The hero numeral fills the card width (`DisciplineHero` is `maxWidth: .infinity`), which used to
        // crush the perf-ramp delta chip when both shared one HStack. Give the chip its own trailing row
        // so it's always fully visible (F5) — leading `Spacer()` parks it in the hero's trailing slot.
        VStack(alignment: .leading, spacing: 10) {
            DisciplineHero(value: s.climbingLevelLabel ?? "—",
                           caption: "Climbing level",
                           sublabel: s.maxGradeLabel.map { "All-time best \($0)" },
                           systemImage: "figure.climbing",
                           accent: accent)
            if let levelDelta, levelDelta.steps != 0 {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    levelDeltaChip(levelDelta).fixedSize()
                }
            }
        }
        .snappetCard()
        .accessibilityIdentifier("kilter.stats.hero")
    }

    /// "▲ +1 vs 90d" — perf-ramp coloured (effort axis), never amber-wayfinding.
    private func levelDeltaChip(_ d: (steps: Int, fromLabel: String, toLabel: String)) -> some View {
        let up = d.steps > 0
        let color = up ? SnappetColor.perfFresh : SnappetColor.perfHard
        return HStack(spacing: 4) {
            Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.caption2)
            Text("\(up ? "+" : "")\(d.steps) vs 90d").font(.caption.weight(.bold))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.16), in: Capsule())
        .accessibilityLabel("Climbing level \(up ? "up" : "down") \(abs(d.steps)) grades versus 90 days ago")
    }

    // MARK: - Tier 1: stat ribbon (SENT / FLASH RATE / THIS WEEK)

    private func statRibbon(_ s: KilterAllTimeStats) -> some View {
        HStack(spacing: 10) {
            statTile("\(s.totalSends)", "Sent")
            statTile("\(Int((s.flashRate * 100).rounded()))%", "Flash rate")
            statTile("\(s.sendsPerWeek.last?.sends ?? 0)", "This week")
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                .foregroundStyle(SnappetColor.ink)
            Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(0.4)
                .foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    // MARK: - Tier 2: segmented pyramid (tap → filter)

    private func pyramidCard(_ s: KilterAllTimeStats) -> some View {
        ClimbGradePyramid(pyramid: s.pyramid,
                          style: .segmented,
                          currentMaxLabel: s.maxGradeLabel,
                          onSelectGrade: { label in
                              withAnimation(.snappy) {
                                  gradeFilter = (gradeFilter == label) ? nil : label
                              }
                          })
    }

    // MARK: - Tier 2: send / flash rings

    private func ringsRow(_ s: KilterAllTimeStats) -> some View {
        HStack(spacing: 14) {
            ratioRing(fraction: s.sendRate, label: "Send rate", color: SnappetColor.perfFresh)
            ratioRing(fraction: s.flashRate, label: "Flash rate", color: KilterAscentStyle.color(.flash))
        }
    }

    private func ratioRing(fraction: Double, label: String, color: Color) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(SnappetColor.surfaceMuted, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0, min(1, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(SnappetColor.ink)
            }
            .frame(width: 92, height: 92)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int((fraction * 100).rounded())) percent")
    }

    // MARK: - Tier 2: trend doorway tiles

    @ViewBuilder private func trendTiles(_ s: KilterAllTimeStats) -> some View {
        VStack(spacing: 12) {
            trendTile(.volume, title: "Sends / week", systemImage: "calendar",
                      headline: "\(s.totalSends)", caption: "total sends",
                      spark: s.sendsPerWeek.map { Double($0.sends) })
            if s.maxGradeProgression.count >= 2 {
                trendTile(.progression, title: "Max grade progression", systemImage: "mountain.2.fill",
                          headline: s.maxGradeLabel ?? "—", caption: "all-time best",
                          spark: s.maxGradeProgression.map(\.difficulty))
            }
            if let v = s.attemptsToSend {
                trendTile(.velocity, title: "Attempts to send", systemImage: "arrow.uturn.up",
                          headline: String(format: "%.1f", v), caption: "avg tries / send",
                          spark: [])
            }
            if !s.angleDistribution.isEmpty {
                trendTile(.angle, title: "Sends by angle", systemImage: "angle",
                          headline: topAngleLabel(s), caption: "top angle",
                          spark: s.angleDistribution.map { Double($0.sends) })
            }
            trendTile(.consistency, title: "Consistency", systemImage: "checkmark.seal",
                      headline: "\(activeWeeks(s))", caption: "active weeks",
                      spark: s.sendsPerWeek.map { $0.sends > 0 ? 1 : 0 })
            if hasHRData {
                trendTile(.heart, title: "Heart rate", systemImage: "heart.fill",
                          headline: "\(sessionsWithHR())", caption: "HR sessions", spark: [])
            }
        }
    }

    private func trendTile(_ kind: TrendKind, title: String, systemImage: String,
                           headline: String, caption: String, spark: [Double]) -> some View {
        Button { router.push(KilterTrendRoute(kind: kind)) } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title3).foregroundStyle(accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(headline).font(.headline.weight(.bold)).monospacedDigit()
                            .foregroundStyle(SnappetColor.ink)
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if spark.count >= 2 { Sparkline(values: spark, color: accent).frame(width: 64, height: 30) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.stats.tile.\(tileID(kind))")
    }

    private func tileID(_ kind: TrendKind) -> String {
        switch kind {
        case .volume:      return "volume"
        case .progression: return "progression"
        case .velocity:    return "velocity"
        case .angle:       return "angle"
        case .consistency: return "consistency"
        case .heart:       return "heart"
        }
    }

    // MARK: - In-page filtered ascent log (tap-a-grade target)

    /// Cap on the rows rendered in the in-page filtered ascent log — a heavily-climbed grade can have
    /// hundreds of sends; we show the most recent `filteredAscentCap` and surface the rest as a count.
    private static let filteredAscentCap = 100

    private var ascentLogSection: some View {
        // Newest-first (the `@Query` is already date-reverse), capped so a popular grade doesn't render
        // hundreds of rows eagerly (F7). `entries` is reverse-sorted, so the cap keeps the most recent.
        let filtered = entries.filter { $0.status.isSend && $0.gradeLabel == gradeFilter }
        let visible = Array(filtered.prefix(Self.filteredAscentCap))
        let overflow = filtered.count - visible.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sends · \(gradeFilter ?? "")").font(.headline)
                Spacer()
                Button("Clear") { withAnimation(.snappy) { gradeFilter = nil } }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("kilter.stats.clearGradeFilter")
            }
            if filtered.isEmpty {
                Text("No sends at this grade yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                // Lazy so only the on-screen rows materialize (the cap bounds the worst case regardless).
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { entry in
                        HStack(spacing: 10) {
                            let d = KilterAscentStyle.decoration(entry.status)
                            Image(systemName: d.glyph).font(.caption).foregroundStyle(d.color).frame(width: 18)
                            Text(entry.climbName).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text("\(entry.angle)°").font(.caption).foregroundStyle(.secondary)
                            Text(entry.date, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("kilter.stats.filteredAscent")
                    }
                }
                if overflow > 0 {
                    Text("+\(overflow) more send\(overflow == 1 ? "" : "s") at this grade")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityIdentifier("kilter.stats.ascentLogOverflow")
                }
            }
        }
        .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityIdentifier("kilter.stats.ascentLog")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Small derivations from the aggregate (formatting only — no math)

    private func topAngleLabel(_ s: KilterAllTimeStats) -> String {
        guard let top = s.angleDistribution.max(by: { $0.sends < $1.sends }) else { return "—" }
        return "\(top.angle)°"
    }

    private func activeWeeks(_ s: KilterAllTimeStats) -> Int {
        s.sendsPerWeek.filter { $0.sends > 0 }.count
    }

    private func sessionsWithHR() -> Int { allSessions.filter { !$0.hrSeries.isEmpty }.count }
}

/// A tiny inline trend sparkline (a `LineMark`) for a doorway tile — values are pre-aggregated; this
/// only plots them. Flat / single-value series render nothing (the tile gates on `count >= 2`).
struct Sparkline: View {
    let values: [Double]
    var color: Color = SnappetColor.kilter

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            LineMark(x: .value("i", i), y: .value("v", v))
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}
