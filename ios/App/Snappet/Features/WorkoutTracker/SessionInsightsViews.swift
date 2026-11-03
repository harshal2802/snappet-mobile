import SwiftUI
import SwiftData
import Charts

/// The redesigned top of a session's detail (prompt 146, wireframe frames 1–5): where this session sits
/// in its series, what changed since last time, what it earned, and the routine's trend. Reads only the
/// pure `SessionInsights`. (Later, the progression/XP system plugs into this header.)
struct SessionInsightsHeader: View {
    let session: WorkoutSession
    /// Every session (for records across all history); the series is derived from it.
    let history: [WorkoutSession]
    let schedule: RoutineSchedule?
    let resolver: ExerciseResolver
    let unit: WeightUnit

    private var prior: [WorkoutSession] { SessionInsights.comparable(for: session, in: history) }
    private var kind: SessionInsights.Kind { SessionInsights.Kind.of(session) }

    var body: some View {
        let prior = prior
        let count = prior.count + 1
        VStack(alignment: .leading, spacing: 12) {
            Text("\(session.startedAt.formatted(.dateTime.weekday().month().day())) · \(max(1, Int(session.duration / 60))) min · \(SessionInsights.ordinal(count)) \(session.routineName)")
                .font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("insights.subtitle")
            chips(prior: prior)
            heroGrid(prior: prior)
            let badges = SessionInsights.badges(session, prior: prior, allHistory: history,
                                                resolve: { resolver.name(for: $0.exerciseId, override: $0.displayName) },
                                                unit: unit)
            if !badges.isEmpty { badgeStrip(badges) }
            if let progress = SessionInsights.progress(session, prior: prior, unit: unit) { ProgressCard(progress: progress) }
            if count > 1 { milestoneCard(count: count) }
        }
    }

    // MARK: Chips

    @ViewBuilder private func chips(prior: [WorkoutSession]) -> some View {
        let streak = SessionInsights.weekStreak(session, prior: prior)
        let onPlan = SessionInsights.onPlan(session, schedule: schedule)
        if streak >= 2 || onPlan != nil || SessionInsights.avgHR(session) != nil {
            HStack(spacing: 6) {
                if streak >= 2 { chip("🔥 \(streak)-week streak") }
                // "On plan" keeps its meaning colour (prompt 220); the rest are plain outlined chips.
                if let onPlan { chip(onPlan ? "✓ On plan" : "Extra session", tint: onPlan ? SnappetColor.perfFresh : nil) }
                if let hr = SessionInsights.avgHR(session) { chip("♥ \(Int(hr.rounded())) avg") }
            }
            .accessibilityIdentifier("insights.chips")
        }
    }

    private func chip(_ text: String, tint: Color? = nil) -> some View {
        Text(text).font(.system(size: 11.5)).snappetPill(selected: false, tint: tint)
    }

    // MARK: Headline with change since last time

    /// One card, light numbers in columns split by hairlines (prompt 220); deltas keep their meaning colours.
    private func heroGrid(prior: [WorkoutSession]) -> some View {
        let now = SessionInsights.headline(session, unit: unit)
        let last = prior.first.map { SessionInsights.headline($0, unit: unit) }
        return HStack(spacing: 0) {
            ForEach(Array(now.enumerated()), id: \.offset) { i, stat in
                let change = SessionInsights.change(stat, last: last.flatMap { i < $0.count ? $0[i] : nil }, kind: kind)
                HStack(spacing: 0) {
                    if i > 0 { SnappetColor.hairline.frame(width: 1).padding(.trailing, 12) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.display).font(.system(size: 22, weight: .light).monospacedDigit())
                            .foregroundStyle(SnappetColor.ink).lineLimit(1).minimumScaleFactor(0.6)
                        Text(stat.label).font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
                        if let change {
                            Text(change.text).font(.system(size: 10.5))
                                .foregroundStyle(SessionInsightsStyle.color(change.direction))
                                .lineLimit(1).minimumScaleFactor(0.7)
                        } else if prior.isEmpty {
                            Text("first one").font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("insights.stat.\(i)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .snappetPanel()
    }

    // MARK: Badges

    private func badgeStrip(_ badges: [SessionInsights.Badge]) -> some View {
        BadgeStrip(badges: badges, unit: unit)
    }

    private func milestoneCard(count: Int) -> some View {
        let m = SessionInsights.nextMilestone(count: count)
        let span = Double(max(1, m.target - m.previous))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Next milestone").snappetLabel()
                Spacer()
                Text("\(count) / \(m.target)").font(SnappetType.label.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
            }
            Text("\(m.target) × \(session.routineName)").font(.system(size: 13)).foregroundStyle(SnappetColor.ink)
            SessionInsightsStyle.thinBar(fraction: Double(count - m.previous) / span).padding(.top, 6)
        }
        .snappetPanel()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.milestone")
    }
}

/// The session detail's shared colour + bar rules (prompt 220): gains green, losses amber, the rest grey; progress
/// in the user's accent.
enum SessionInsightsStyle {
    static func color(_ direction: SessionInsights.Change.Direction) -> Color {
        switch direction {
        case .better: SnappetColor.perfFresh
        case .worse: SnappetColor.perfModerate
        case .same: SnappetColor.textSecondary
        }
    }

    /// The tint for a per-set change chip ("+2.5 kg", "−1 rep", "="); `nil` = neutral.
    static func chipTint(_ change: String) -> Color? {
        change.hasPrefix("+") ? SnappetColor.perfFresh : change.hasPrefix("−") ? SnappetColor.perfModerate : nil
    }

    /// A 4-pt accent bar on a hairline track.
    static func thinBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SnappetColor.hairline)
                Capsule().fill(SnappetColor.brand).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
    }
}

/// One earned badge — a real record, first, streak or count.
struct BadgeCard: View {
    let badge: SessionInsights.Badge
    let unit: WeightUnit

    private var content: (icon: String, title: String, detail: String) {
        func w(_ kg: Double) -> String { "\(SetMeasure.formatWeight((WorkoutMath.kgToUnit(kg, unit) * 100).rounded() / 100)) \(unit.display)" }
        switch badge {
        case .firstOfSeries(let name): return ("sparkles", "First \(name)", "the start of the series")
        case .weightPR(let ex, let kg, let reps, let prev):
            return ("trophy.fill", "\(ex) PR", "\(w(kg)) × \(reps)" + (prev.map { " (was \(w($0)))" } ?? ""))
        case .repPR(let ex, let reps): return ("trophy.fill", "\(ex) rep PR", "\(reps) reps")
        case .bestVolume(let name): return ("chart.line.uptrend.xyaxis", "Best volume", "for \(name)")
        case .heaviestLoad(let kg): return ("scalemass.fill", "Heaviest yet", "\(SessionInsights.signedLoad(kg)) kg added")
        case .peakForcePR(let kg): return ("bolt.fill", "Peak force PR", "\(SetMeasure.formatWeight((kg * 10).rounded() / 10)) kg")
        case .firstSend(let grade): return ("party.popper.fill", "First \(grade) send", "a new grade")
        case .mostSends(let n): return ("chart.line.uptrend.xyaxis", "Most sends", "\(n) in a session")
        case .fastestPace(let pace): return ("bolt.fill", "Fastest pace", pace)
        case .longestDistance(let d): return ("figure.run", "Longest run", d)
        case .sessionCount(let n, let name): return ("flag.checkered", "\(n) × \(name)", "milestone reached")
        case .weekStreak(let weeks): return ("flame.fill", "\(weeks)-week streak", "keep it going")
        }
    }

    /// Neutral card, the icon in the accent (prompt 220) — the brown / blue / orange fills read as noise.
    var body: some View {
        let c = content
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: c.icon).font(.system(size: 15)).foregroundStyle(SnappetColor.brand)
            Text(c.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(SnappetColor.ink)
                .lineLimit(2, reservesSpace: true)
            Text(c.detail).font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .padding(10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SnappetColor.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("badge")
    }
}

/// The routine's trend with today highlighted and best ever dashed (wireframe frame 1).
struct ProgressCard: View {
    let progress: SessionInsights.Progress

    var body: some View {
        let pts = progress.points
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Progress · \(progress.title.lowercased())").snappetLabel()
                Spacer()
                Text("last \(pts.count)").snappetLabel()
            }
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Session", i), y: .value(progress.title, v))
                        .foregroundStyle(SnappetColor.brand).lineStyle(StrokeStyle(lineWidth: 2))
                }
                RuleMark(y: .value("Best", progress.best))
                    .foregroundStyle(SnappetColor.perfFresh.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                if let last = pts.last {
                    PointMark(x: .value("Session", pts.count - 1), y: .value(progress.title, last))
                        .foregroundStyle(SnappetColor.brand).symbolSize(50)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(SnappetColor.hairline)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(progress.display(v)) } }
                        .foregroundStyle(SnappetColor.textTertiary)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: progress.lowerIsBetter))
            .frame(height: 90)
            Text(summary).font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
        }
        .snappetPanel()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.progress")
    }

    private var summary: String {
        guard let first = progress.points.first, let last = progress.points.last else { return "" }
        let isBest = last == progress.best
        let from = progress.display(first), to = progress.display(last)
        return "\(from) → \(to)" + (isBest ? " · today is your best" : " · best \(progress.display(progress.best))")
    }
}

/// Strength: each exercise compares itself with last time (wireframe frame 2).
struct ExerciseCompareCard: View {
    let row: SessionInsights.ExerciseCompare

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).font(.system(size: 14, weight: .medium)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                Spacer()
                if let c = row.change {
                    Text(c.text).font(.system(size: 11.5)).foregroundStyle(SessionInsightsStyle.color(c.direction))
                }
            }
            Text(row.summary).font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
            if row.trend.count >= 2 {
                Chart(Array(row.trend.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Session", i), y: .value("Top", v))
                        .foregroundStyle(SnappetColor.brand).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 30)
            }
            if row.setChanges.contains(where: { $0 != "=" && $0 != "new" }) {
                HStack(spacing: 6) {
                    ForEach(Array(row.setChanges.enumerated()), id: \.offset) { i, c in
                        let tint = SessionInsightsStyle.chipTint(c)
                        Text("S\(i + 1) \(c)").font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(tint ?? SnappetColor.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(tint.map { $0.opacity(0.45) } ?? SnappetColor.hairline))
                    }
                }
            }
            if let nudge = row.nudge {
                Label(nudge, systemImage: "arrow.up.forward.circle").font(.system(size: 12)).foregroundStyle(SnappetColor.brand)
            }
        }
        .snappetPanel()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.exercise")
    }
}

/// Hangboard: force per hang, set × rep, with fatigue (wireframe frame 3).
struct ForceGridCard: View {
    let grid: SessionInsights.ForceGrid
    let lastFatigue: Double?

    var body: some View {
        let all = grid.cells.flatMap { $0 }.compactMap { $0 }
        let lo = all.min() ?? 0, hi = all.max() ?? 1
        VStack(alignment: .leading, spacing: 8) {
            Text("Force per hang · peak kg").snappetLabel()
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                GridRow {
                    Text("")
                    ForEach(0..<(grid.cells.first?.count ?? 0), id: \.self) { r in
                        Text("Rep \(r + 1)").font(.caption2).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
                ForEach(Array(grid.cells.enumerated()), id: \.offset) { s, row in
                    GridRow {
                        Text("Set \(s + 1)").font(.caption2).foregroundStyle(SnappetColor.textSecondary)
                        ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                            Text(v.map { SetMeasure.formatWeight(($0 * 10).rounded() / 10) } ?? "–")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(SnappetColor.brand.opacity(v.map { 0.2 + 0.6 * (hi > lo ? ($0 - lo) / (hi - lo) : 1) } ?? 0.05),
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            if let f = grid.fatigue {
                Text("Fatigue: \(Int((f * 100).rounded()))% from first to last set"
                     + (lastFatigue.map { " (last time \(Int(($0 * 100).rounded()))%)" } ?? ""))
                    .font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .snappetPanel()
        .accessibilityIdentifier("insights.forceGrid")
    }
}

/// Climbing: today's sends by grade against the last 30 days (wireframe frame 4).
struct PyramidCompareCard: View {
    let rows: [SessionInsights.PyramidRow]

    var body: some View {
        let top = Double(max(1, rows.map { max($0.today, $0.last30) }.max() ?? 1))
        VStack(alignment: .leading, spacing: 6) {
            Text("Grade pyramid · today vs last 30 days").snappetLabel()
            ForEach(rows, id: \.grade) { r in
                HStack(spacing: 8) {
                    Text(r.grade).font(.caption.weight(.medium).monospacedDigit()).frame(width: 34, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(SnappetColor.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                .frame(width: geo.size.width * Double(r.last30) / top)
                            RoundedRectangle(cornerRadius: 4).fill(SnappetColor.brand)
                                .frame(width: geo.size.width * Double(r.today) / top)
                        }
                    }
                    .frame(height: 12)
                    Text("\(r.today)" + (r.last30 > 0 ? " · 30d \(r.last30)" : "")).font(.caption2.monospacedDigit())
                        .foregroundStyle(SnappetColor.textSecondary).frame(width: 64, alignment: .trailing)
                }
            }
        }
        .snappetPanel()
        .accessibilityIdentifier("insights.pyramid")
    }
}

/// "This session earned" — a horizontal strip of badges (session detail + the finish screen).
struct BadgeStrip: View {
    let badges: [SessionInsights.Badge]
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This session earned").snappetLabel()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(badges) { b in BadgeCard(badge: b, unit: unit) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.badges")
    }
}

/// The finish screen's badge strip (prompt 146): what this just-finished session earned against
/// history. Queries completed sessions itself so the player needn't thread history through.
struct SessionEarnedStrip: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit
    @Query(filter: #Predicate<WorkoutSession> { $0.completedAt != nil }) private var completed: [WorkoutSession]

    var body: some View {
        let history = completed.filter { $0.id != session.id && !$0.isImportedFromHealth }
        let badges = SessionInsights.badges(session, prior: SessionInsights.comparable(for: session, in: history),
                                            allHistory: history,
                                            resolve: { resolver.name(for: $0.exerciseId, override: $0.displayName) },
                                            unit: unit)
        if !badges.isEmpty { BadgeStrip(badges: badges, unit: unit) }
    }
}
